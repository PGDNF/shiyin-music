package shiyin.famlife.top

import android.media.session.MediaSession
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Modifier

object VivoLyricsBridge {
    private const val TAG = "VivoLyrics"
    private val audioServiceClass by lazy {
        Class.forName("com.ryanheise.audioservice.AudioService")
    }
    private val instanceField by lazy {
        audioServiceClass.getDeclaredField("instance").apply {
            isAccessible = true
        }
    }
    private val sessionField by lazy {
        audioServiceClass.getDeclaredField("mediaSession").apply {
            isAccessible = true
        }
    }

    // 元数据一致性闸门：原子岛 CooperateController 按 meidia_id == 当前 MEDIA_ID
    // 精确匹配歌词（k2.a 非 bbkmusic 包仅走 equals 分支）。audio_service 元数据通道
    // 与 vivo extras 通道异步，冷启动 lrc_change 可能先于元数据落地导致不一致被丢弃。
    // 不一致时短重试等元数据落地，上限外的兜底由 Dart 周期重发覆盖。
    private const val MAX_METADATA_RETRIES = 30
    private const val METADATA_RETRY_DELAY_MS = 100L
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingMediaId: String? = null
    private var pendingLrc: String? = null
    private var retryCount = 0
    private val retryRunnable = Runnable {
        val m = pendingMediaId
        val l = pendingLrc
        if (m != null && l != null) publish(m, l)
    }

    fun register(messenger: BinaryMessenger): MethodChannel {
        return MethodChannel(messenger, "shiyin_music/vivo_lyrics").apply {
            setMethodCallHandler { call, result ->
                if (call.method != "publish") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val mediaId = call.argument<String>("mediaId").orEmpty()
                val fullLrc = call.argument<String>("fullLrc").orEmpty()
                if (mediaId.isEmpty() || fullLrc.isEmpty()) {
                    Log.w(TAG, "publish skipped: mediaId empty=${mediaId.isEmpty()} lrc empty=${fullLrc.isEmpty()}")
                    result.success(false)
                    return@setMethodCallHandler
                }
                runCatching { publish(mediaId, fullLrc) }
                    .onSuccess { result.success(it) }
                    .onFailure {
                        Log.e(TAG, "publish failed", it)
                        result.success(false)
                    }
            }
        }
    }

    private fun publish(mediaId: String, fullLrc: String): Boolean {
        val service = instanceField.get(null)
        if (service == null) {
            Log.w(TAG, "publish: AudioService.instance=null (service not created?)")
            return false
        }
        val session = sessionField.get(service)
        if (session == null) {
            Log.w(TAG, "publish: mediaSession=null")
            return false
        }
        Log.d(TAG, "publish: session=${session.javaClass.name} mediaId=$mediaId lrcLen=${fullLrc.length}")

        logMetadataDiagnostic(session)

        // 仅在会话当前 MEDIA_ID 与目标 mediaId 一致时发布 lrc_change，否则原子岛
        // 精确匹配失败丢弃。不一致说明元数据尚未落地（异步竞态），短重试等待。
        val currentMediaId = readMetadataMediaId(session)
        if (currentMediaId != mediaId) {
            if (mediaId != pendingMediaId) retryCount = 0
            pendingMediaId = mediaId
            pendingLrc = fullLrc
            if (retryCount < MAX_METADATA_RETRIES) {
                retryCount++
                mainHandler.removeCallbacks(retryRunnable)
                mainHandler.postDelayed(retryRunnable, METADATA_RETRY_DELAY_MS)
            }
            Log.d(TAG, "publish deferred: metadata mediaId=$currentMediaId != lrc mediaId=$mediaId retry=$retryCount")
            return false
        }
        retryCount = 0
        pendingMediaId = null
        pendingLrc = null
        mainHandler.removeCallbacks(retryRunnable)

        val extras = Bundle().apply {
            putString(
                "vivomusicmix.meida.extra.key.action",
                "vivomusicmix.extra.lrc_change",
            )
            putString("vivomusicmix.extra.key.lyric", fullLrc)
            putString("vivomusicmix.extra.key.meidia_id", mediaId)
        }

        // compat setExtras：内部调 framework setExtras 并同步 compat 缓存
        var compatOk = false
        try {
            session.javaClass.getMethod("setExtras", Bundle::class.java)
                .invoke(session, extras)
            compatOk = true
        } catch (e: Exception) {
            Log.w(TAG, "publish: compat setExtras failed", e)
        }

        // framework setExtras：字段扫描定位 framework MediaSession，
        // 不依赖被 R8 混淆的 compat 方法名（getMediaSession 可能已改名）。
        var frameworkOk = false
        val frameworkSession = findFrameworkSession(session)
        if (frameworkSession != null) {
            try {
                frameworkSession.setExtras(extras)
                frameworkOk = true
            } catch (e: Exception) {
                Log.w(TAG, "publish: framework setExtras failed", e)
            }
        } else {
            Log.w(TAG, "publish: framework MediaSession not found")
        }

        Log.d(TAG, "publish result: compat=$compatOk framework=$frameworkOk")
        return compatOk || frameworkOk
    }

    // framework 类（android.media.session.MediaSession）永远不会被 R8 混淆，
    // 沿 compat 对象字段递归查找即可：MediaSessionCompat → mImpl → mSessionFwk。
    private fun findFrameworkSession(obj: Any, depth: Int = 0): MediaSession? {
        if (obj is MediaSession) return obj
        if (depth >= 5) return null
        var clazz: Class<*>? = obj.javaClass
        while (clazz != null && clazz != Any::class.java) {
            for (field in clazz.declaredFields) {
                if (Modifier.isStatic(field.modifiers)) continue
                val value = try {
                    field.isAccessible = true
                    field.get(obj)
                } catch (e: Exception) {
                    continue
                } ?: continue
                if (value is MediaSession) return value
                val name = value.javaClass.name
                if (name.startsWith("android.support.v4.media") ||
                    name.startsWith("androidx.media")
                ) {
                    findFrameworkSession(value, depth + 1)?.let { return it }
                }
            }
            clazz = clazz.superclass
        }
        return null
    }

    private fun readMetadataMediaId(session: Any): String? {
        return try {
            val controller = session.javaClass
                .getMethod("getController").invoke(session) ?: return null
            val metadata = controller.javaClass
                .getMethod("getMetadata").invoke(controller) ?: return null
            metadata.javaClass
                .getMethod("getString", String::class.java)
                .invoke(metadata, "android.media.metadata.MEDIA_ID") as? String
        } catch (e: Exception) {
            null
        }
    }

    private fun logMetadataDiagnostic(session: Any) {
        try {
            val controller = session.javaClass
                .getMethod("getController").invoke(session) ?: return
            val metadata = controller.javaClass
                .getMethod("getMetadata").invoke(controller) ?: return
            val supportEvent = metadata.javaClass
                .getMethod("getLong", String::class.java)
                .invoke(metadata, "vivomusicmix.media.metadata.support_event")
            Log.d(TAG, "metadata: support_event=$supportEvent mediaId=${readMetadataMediaId(session)}")
        } catch (e: Exception) {
            Log.w(TAG, "metadata diagnostic failed", e)
        }
    }
}