# 时音（shiyin-music-vivo）vivo 歌词方案 + 整包构建 · 复现指南

> 目标读者：另一个 AI / 开发者，要求**最快、完全复现、不踩坑**。
> 本文所有结论均以**真实代码 / 真实 APK 反编译 / 真机日志**为准，不是推测。
> 仓库：`https://github.com/ttchr/shiyin-music-vivo`，分支：`lyrics`。
> 参考实现（车机协议）：`https://github.com/7tattoo/vivo-car-atomic-lyrics`。

---

## 0. 权威来源与红线（先读，避免走弯路）

1. **AI 写的文档只是线索，不是权威。** 仓库里/临时目录里任何 `VIVO_车联_原子岛歌词修复完整技术文档.md` 之类由其它 AI 生成的文档，只能当参考。判定对错必须回到：真实源码、反编译的 vivo 平台 APK、真机 logcat。
2. **只改 `shiyin-music-vivo` 本仓库。** 严禁修改 vivo 平台 APK（智能车载 / 车载 launcher / 原子随身听）。它们是消费方，是"协议对手"，不是我们的代码。
3. **GitHub Secrets 的值永不打印、永不提交。** 只引用 secret 名字；凭据在 shell 变量里使用，不回显 token。
4. **未经用户明确指示不 push、不 build。** 本文描述的改动默认"攒着批量构建"。
5. **URL 卫生：** 需要 URL 的工具，URL 必须与当前任务目标一致，禁止替换成 routify 等临时代理；已有真实链接且任务确需时除外。每次调用重新核对目标与来源。

---

## 1. 不可违背的产品约束

| 约束 | 值 / 做法 |
|---|---|
| 目标分支 | `lyrics` |
| 平台 | **仅 Android**，删除 windows/ios/macos/linux/web 目录与入口 |
| ABI | **仅 arm64-v8a**（`--target-platform android-arm64`） |
| 渲染 | **Impeller**（Manifest meta-data 开启，无 Skia） |
| applicationId | `com.apple.android.music`（namespace 仍是 `shiyin.famlife.top`） |
| minSdk | **26**（SuperLyricApi 3.4 要求，低于会在 Manifest 合并失败） |
| 签名 | 从 GitHub Secrets 自动配置，`RELEASE_KEY_ALIAS` 完整读自 Secrets |
| 删除的工作流 | `Flutter Analyze & Test`、`Publish Release`；删除 `test/` 目录 |
| 保留的工作流 | **仅** `.github/workflows/build-android.yml`（APK 构建不得产生 Publish Release 记录） |
| 本地封面 | 保留 MediaStore `content://` 封面 |
| 改动风格 | 优先新增独立文件，尽量少改既有文件；改动攒批后再构建（每次构建约 20–25 分钟） |

---

## 2. 核心心智模型：显示面 → 通道映射

vivo 有**四个**歌词显示面，各自读**不同**的通道。搞混通道是"歌词不显示"的头号原因。下表由反编译 `原子随身听_17.0.9.1.apk` 与真机验证确认：

| 显示面 | 消费方 | 读取通道 | 关键 key / 载体 | 反编译 helper |
|---|---|---|---|---|
| **车机 JoviInCar** | 智能车载 | MediaSession **metadata** | `ucar.media.metadata.LYRICS_WHOLE`（整首 LRC） | — |
| **大卡片** MusicPlayPanel | 原子随身听 | session **setExtras** 事件 | vivomusicmix `lrc_change`（整首 LRC） | `n7.s`（`X()`，bit8 闸门） |
| **MINI** IslandMusicWidget（原子岛） | 原子随身听 | session **setExtras** 事件 | 同一条 `lrc_change` 推送 | `n7.f`（`n()`，bit8 闸门，10s 超时） |
| **锁屏岛 / 状态栏** | ColorOS/OriginOS | MediaSession **metadata** | LyricInfo：`lyric/currentLyric/lyricInfo` JSON | — |

要点：
- **大卡片与 MINI 共用同一条 `lrc_change` extras 推送**，但各自有独立的消费闸门（见 §4）。
- **车机与锁屏岛走 metadata**，不是 extras；两条路径都要写。
- MINI 只在**打开期间**消费 `lrc_change`；绑定后**不读已存 extras**，只等下一笔事件 → 必须重发（见 §3.1 / §4）。

---

## 3. 歌词方案实现（逐文件，含精确 key）

### 3.1 Dart：`lib/services/vivo_lyrics_service.dart`

职责：产出 metadata extras（车机 + support_event）+ 通过 MethodChannel 触发原生 `lrc_change` 推送（大卡片 / MINI），并管理重发节奏。

**metadata extras（车机 JoviInCar + 原子岛能力位）：**
```dart
static Map<String, dynamic> metadataExtras({
  required Song song,
  String? fullLyricLrc,
}) {
  final hasLrc = fullLyricLrc != null && fullLyricLrc.isNotEmpty;
  return <String, dynamic>{
    'hash': song.hash,
    'songId': song.id,
    'vivomusicmix.media.metadata.support_event': 4095, // bit8=歌词 bit16=进度
    'ucar.media.metadata.UCAR_TITLE': song.title,
    'ucar.media.metadata.UCAR_ARTIST': song.artist,
    if (hasLrc) ...{
      'ucar.media.metadata.LYRICS_WHOLE': fullLyricLrc, // 整首标准 LRC
      'ucar.media.metadata.LYRICS_STATUS': 0,
    },
  };
}
```

**重发节奏（本次"成功修改"的核心，已优化）：**
```dart
// 切歌立即发一笔；早期 +2/+4/+8 跨过原子岛冷启动布局窗口；
// 之后只在 +30/+60/+90s 各稀疏补发一笔覆盖"mini 中途打开"，90s 后停发。
// 不再用后台 6s 周期重发（过多）。间距 ≥2s，避开切歌 1s 内写入风暴。
static const _retryDelays = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(seconds: 90),
];
```
- 每首歌总推送次数 ≈ **7**（立即 1 + 定时 6），而非旧方案的 ~35–40。
- `sync()` 用 `'$mediaId\n$fullLyricLrc'` 签名去重：同一首歌同一份 LRC 不重复排定时器；换歌/换词才重排。
- `sync()` 先 `_cancelRetries()` 再为每个 delay 建 `Timer`，最后立即 `unawaited(_publish())`。
- `_publish()` 调 `MethodChannel('shiyin_music/vivo_lyrics')` 的 `publish`，参数 `{mediaId, fullLrc}`；`MissingPluginException` → `reset()`（原生桥未注册时静默停）。
- `reset()` 取消所有定时器并清空 `_mediaId/_fullLrc/_lastSentSignature`。

> 历史：早期是 `Timer.periodic(6s)` 持续重发 + `_resendInterval/_resendTimer`。本次已**删除**周期定时器与这两个成员，改为上面 6 个一次性 `Timer`。复现时不要再引入 `Timer.periodic`。

### 3.2 Dart：`lib/services/music_audio_handler.dart`

职责：把歌词写进推给系统媒体会话的 `MediaItem`（锁屏岛 / 状态栏 / 三方歌词插件），并驱动 `VivoLyricsService.sync()`。

- 实例：`_vivoLyrics = VivoLyricsService()`（约 line 139）。
- `updateLyricMetadata(...)`（约 line 729）：`song = _currentSong`，同时用于 `_pushCurrentMediaItem()` 与 `_vivoLyrics.sync(song: song, fullLyricLrc: ...)`。`lyricText == null` 表示清空（暂停/切歌/无词），整组歌词字段一并移除。
- **mediaId 规则（全链路一致，务必统一）：**
  ```dart
  id: song.hash.isEmpty ? song.id : song.hash
  ```
  `buildLyricMediaItem`（约 747）、`_mediaItemFor`（约 983）、`VivoLyricsService.sync`、`VivoLibraryBridge.mediaIdFor` 全部用这条规则。**这是原子岛精确匹配的前提**（见 §4）。
- `buildLyricMediaExtras`（约 805）：合并 `VivoLyricsService.metadataExtras(...)` + 以下 **Dart 3.8 null-aware 元素**（值为 null 时整键省略，不写空串）：
  ```dart
  'lyric': ?line,
  'currentLyric': ?line,
  'music.media.extras.LYRIC': ?line,            // 原子岛 mini 单行通道（与锁屏岛不同 key）
  'music.media.extras.LYRIC_IS_ALLOWED': ?lyricAllowed, // 有整首 LRC 时=1
  'translationLyric': ?translation,
  'romanLyric': ?romanization,
  'full_lrc': ?fullLrc,
  'org.akanework.lyricinfo.FULL_LYRICS': ?fullLrc,   // 协议别名
  'org.akanework.lyricinfo.CURRENT_LYRIC': ?line,    // 协议别名
  'lyricInfo': ?lyricInfoJson,
  ```
- `buildLyricInfoJson`（约 862）：LyricInfo 协议 JSON（锁屏岛/状态栏）。`songName/artist/album/songId/lyric` 必有，`translation/roma` 非空才带；`lyric` 优先整首 LRC，无 LRC 退回当前行。**与上游差异（有意）：** 只要还有整首 LRC 就保留 JSON（仅省略当前行字段），纯音乐间奏不闪断。
- `buildLyricMediaTitle`：手环/AVRCP 标题同步开启且当前行非空 → title=歌词行，否则歌名（只覆盖 title，artist/album 不变）。

### 3.3 Kotlin：`android/app/src/main/kotlin/shiyin/famlife/top/VivoLyricsBridge.kt`

职责：反射拿到 audio_service 的 MediaSession，把整首 LRC 以 vivomusicmix `lrc_change` 事件 `setExtras` 出去（大卡片 + MINI）。`object`，`TAG="VivoLyrics"`。

**反射入口（R8 会混淆，必须 keep，见 §3.6）：**
```kotlin
Class.forName("com.ryanheise.audioservice.AudioService")
  .getDeclaredField("instance")   // static，服务单例
  .getDeclaredField("mediaSession") // 实例字段，MediaSessionCompat
```

**`lrc_change` Bundle —— 三个 key 全是 vivo 的拼写错误，必须原样照抄（改成"正确"拼写就失效）：**
```kotlin
val extras = Bundle().apply {
    putString("vivomusicmix.meida.extra.key.action", "vivomusicmix.extra.lrc_change")
    putString("vivomusicmix.extra.key.lyric", fullLrc)     // 整首标准 LRC
    putString("vivomusicmix.extra.key.meidia_id", mediaId) // = song.hash（见 §3.2）
}
```
> 注意 `meida`（不是 media）、`meidia_id`（不是 media_id）—— 这是 vivo 源码里的真实 typo，反编译确认，**不可纠正**。

**元数据一致性闸门（本次修复首歌/冷启动不显示的关键）：**
```kotlin
val currentMediaId = readMetadataMediaId(session) // getController().getMetadata()
                                                  //   .getString("android.media.metadata.MEDIA_ID")
if (currentMediaId != mediaId) {
    // 元数据还没落地（异步竞态）→ 短重试等待，别发（发了会被精确匹配丢弃）
    if (mediaId != pendingMediaId) retryCount = 0
    pendingMediaId = mediaId; pendingLrc = fullLrc
    if (retryCount < MAX_METADATA_RETRIES) { // 30 次
        retryCount++
        mainHandler.postDelayed(retryRunnable, METADATA_RETRY_DELAY_MS) // 100ms
    }
    return false
}
```
- 原因：原子岛 `CooperateController` 按 `meidia_id == 当前 MEDIA_ID` **精确匹配**（`k2.a`，非 bbkmusic 包只走 `equals` 分支）。audio_service 的 metadata 通道与 vivo extras 通道**异步**，冷启动 `lrc_change` 可能先于 metadata 落地 → 不一致被丢。闸门等到一致再发；上限外的兜底由 Dart 重发覆盖。

**双通道 setExtras（compat + framework）：**
```kotlin
// 1) compat：反射 MediaSessionCompat.setExtras(Bundle)（内部会调 framework 并同步缓存）
session.javaClass.getMethod("setExtras", Bundle::class.java).invoke(session, extras)
// 2) framework：字段扫描定位 android.media.session.MediaSession，直接 setExtras
findFrameworkSession(session)?.setExtras(extras)
return compatOk || frameworkOk
```
- `findFrameworkSession`：framework 类 `android.media.session.MediaSession` **永不被 R8 混淆**。沿 compat 对象字段递归扫描（深度 ≤5），跟随类名以 `android.support.v4.media` / `androidx.media` 开头的字段：`MediaSessionCompat → mImpl → mSessionFwk`。**不依赖被混淆的 compat 方法名**（`getMediaSession` 可能已改名）。

### 3.4 Kotlin：`MainActivity.kt` 注册桥

`configureFlutterEngine` 内（约 line 615）：
```kotlin
vivoLyricsChannel = VivoLyricsBridge.register(flutterEngine.dartExecutor.binaryMessenger)
```
`onDestroy`（约 1473）：`vivoLyricsChannel?.setMethodCallHandler(null); vivoLyricsChannel = null`。
`MainActivity extends AudioServiceActivity`（audio_service 提供）。

### 3.5 Manifest：`android/app/src/main/AndroidManifest.xml`（消费方如何绑定）

```xml
<service
    android:name="com.ryanheise.audioservice.AudioService"
    android:foregroundServiceType="mediaPlayback"
    android:exported="true">
    <intent-filter>
        <action android:name="android.media.browse.MediaBrowserService" />
        <action android:name="com.vivo.musicwidgetmix.support.service" /> <!-- 原子随身听据此绑定 -->
    </intent-filter>
</service>
```
- `com.vivo.musicwidgetmix.support.service` 这条 action 是原子随身听发现/绑定本服务的关键，**不能删**。
- Impeller：`<meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="true" />`。
- 自定义 `Application`：`android:name=".MusicApplication"`（先建通知渠道，防车机 heads-up）。

### 3.6 R8：`android/app/proguard-rules.pro`（反射不被混淆）

```proguard
# VivoLyricsBridge 反射访问 AudioService 内部字段，R8 不得重命名
-keepclassmembers class com.ryanheise.audioservice.AudioService {
    static *** instance;
    *** mediaSession;
}
# MediaSessionCompat 已被 R8 混淆成 android.support.v4.media.session.t，
# 反射调 setExtras/getController/getMetadata/getLong/getString，必须整包 keep
-keep class android.support.v4.media.session.** { *; }
-keep class android.support.v4.media.MediaMetadataCompat { *; }
```
> 踩坑实录：不 keep 时 `MediaSessionCompat → android.support.v4.media.session.t`，反射 `getMethod("setExtras")` 抛 `NoSuchMethodException`，歌词发布静默失败。这是 task #13 的根因。

### 3.7 三类列表 browse（原子随身听歌单，配套）

`lib/services/vivo_library_bridge.dart` + `music_audio_handler.dart`：
- 三个 parent mediaId：`vivomusicmix_current_list` / `vivomusicmix_favorite_list` / `vivomusicmix_local_list`。
- `getChildren(parentMediaId)`（handler 约 236）→ `_vivoLibrary.songsFor(parent)` → `_mediaItemFor(song, includeArt:true)`。
- `getMediaItem` / `playFromMediaId` 用 `resolve(mediaId)` 反查歌曲与队列。
- **去重坑（task #11）：** `subscribeToChildren` 返回**非种子** `BehaviorSubject<Map<String,dynamic>>()`。默认 `seeded({})` 会立即触发 `notifyChildrenChanged` → Android 二次 `onLoadChildren` → 列表重复投递。不发射 = 不重加载。
- 本地列表 = `deduplicateByTitle([...localSongs(), ...downloadedSongs()])`（按 title 小写去重）。

---

## 4. 关键契约与坑（务必遵守，逐条都是真机/反编译验证过的）

1. **typo key 不可纠正**：`vivomusicmix.meida.extra.key.action` / `vivomusicmix.extra.key.lyric` / `vivomusicmix.extra.key.meidia_id`。value `vivomusicmix.extra.lrc_change`。照抄，别"修拼写"。
2. **mediaId 精确匹配**：原子岛 `k2.a` 对非 bbkmusic 包**只走 `musicId.equals(currentPlayingId)`**。`title|artist` 分支是 **bbkmusic 专用**，我们（`com.apple.android.music`）用不上。所以 mediaId 必须 = 会话当前 `MEDIA_ID` = `song.hash`（空则 `song.id`），全链路统一。
3. **support_event = 4095**：bit8=歌词能力，bit16=进度。消费方 `n7.f.n()` / `n7.s.X()` 都检查 bit8；不写或写错 → mini/大卡片直接判定"无歌词能力"。
4. **R8 混淆**：见 §3.6。keep 规则 + framework 字段扫描缺一不可。
5. **元数据一致性闸门**：见 §3.3。冷启动/首歌异步竞态，必须等 `MEDIA_ID` 一致再发 `lrc_change`。
6. **重发节奏**：立即 + 2/4/8/30/60/90s，90s 后停。MINI 打开期间才消费、绑定后不读旧 extras，所以要重发；但 6s 周期过多，已改稀疏一次性。
7. **"先开大卡片 → 再开 MINI 无歌词"是消费方 bug，应用侧修不了**（task #20 结论，用户同意"实在修不好就先这样"）：
   - 原子岛 init `l0.J(ctx,pkg,true)`（`IslandMusicWidget:1154`）会清 `f24218j/B/f24225q`；大卡片 init 不清。
   - `R(B)` 推送闸门要求 `B==f24218j`；同一首歌 `b0.l0()` 提前 return（469），`f24218j` 只能靠 `GET_MUSIC_ID` 恢复。
   - 原子岛 10s 超时 `msg5→o()` 标记"无歌词"。
   - PULL 兜底 `msg101→w()→ACTION_REQUEST_WHOLE_LRC` 是**绑定服务 IPC，第三方应用永远收不到**。
   - → 不要试图在应用侧"修"它，会白费功夫。
8. **MINI 单行通道**：`music.media.extras.LYRIC`（+ `LYRIC_IS_ALLOWED`）。锁屏岛正常但 mini 缺词，常因缺这条。车联 6.0.8.3 忽略它，老车联可能据此切单行。
9. **清空语义**：`lyricText == null` = 清空，整组歌词字段移除（不写空串），避免锁屏停在半句。
10. **audio_service 版本**：`^0.18.18`，用**旧** support 命名空间 `android.support.v4.media.session.MediaSessionCompat`；每次 `mediaItem.add()` 全量替换 `setMetadata()`。别升级到 androidx.media3 命名空间，反射/keep 全要重写。

---

## 5. 整包构建（Android-only / ARM64 / Impeller）

### 5.1 平台裁剪
- 删除 `windows/ ios/ macos/ linux/ web/` 目录与运行时入口；`pubspec.yaml` 里桌面依赖可保留（裁剪在平台目录/构建层，不在 pubspec）。
- 删除 `test/`、`Flutter Analyze & Test` 工作流、`Publish Release` 工作流。`.github/workflows/` 下**只剩** `build-android.yml`。

### 5.2 `android/app/build.gradle.kts`（关键段）
```kotlin
// 仅允许 android-arm64
val flutterTargetPlatforms = (project.findProperty("target-platform") as? String)
    ?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() } ?: listOf("android-arm64")
require(flutterTargetPlatforms == listOf("android-arm64")) { "This project only supports Android ARM64." }

android {
  namespace = "shiyin.famlife.top"
  defaultConfig {
    val customPkg = (project.findProperty("customPackageName") as? String)?.trim()
    applicationId = if (!customPkg.isNullOrEmpty()) customPkg else "com.apple.android.music"
    minSdk = 26                       // SuperLyricApi 3.4 要求
    ndk { abiFilters.clear(); abiFilters.add("arm64-v8a") }
  }
  signingConfigs { create("release") { /* 读 rootProject key.properties */ } }
  buildTypes { release { signingConfig = signingConfigs.getByName("release")
                         proguardFiles("proguard-rules.pro") } }
}
// JitPack 懒构建不缓存失败结果（首次 404 不被永久缓存）
configurations.all { resolutionStrategy { cacheChangingModulesFor(0, "seconds") } }
dependencies {
  implementation("com.github.HChenX:SuperLyricApi:3.4") { isChanging = true } // 车载歌词广播(Xposed)
}
// Rust → jniLibs（arm64）
tasks.register<Exec>("cargoBuildArm64") {
  workingDir = file("${project.projectDir}/../../rust")
  commandLine("cargo","ndk","-t","arm64-v8a","-o","../android/app/src/main/jniLibs","build","--release")
}
tasks.configureEach { if (name.startsWith("merge") && name.endsWith("JniLibFolders")) dependsOn("cargoBuildArm64") }
```
- Java/Kotlin 均 17（`JavaVersion.VERSION_17` / `JvmTarget.JVM_17`）。
- 签名读 `rootProject.file("key.properties")`（CI 写入 `android/key.properties`）。

### 5.3 其余 Gradle 配置
- `android/settings.gradle.kts`：repos `google / mavenCentral / jitpack.io / www.jitpack.io`；plugins `flutter-plugin-loader 1.0.0`、`com.android.application 8.11.1`、`org.jetbrains.kotlin.android 2.2.20`；`flutterSdkPath` 从 `local.properties` 读（`flutter build` 会自动生成 `android/local.properties`）。
- `android/build.gradle.kts`：`allprojects` 同样四 repos；buildDir 重定向到 `../../build`。
- `android/gradle.properties`：`-Xmx8G`；`android.useAndroidX=true`；`kotlin.incremental=false`（Windows 跨盘符 D:/C: 增量编译抛 IllegalArgumentException，禁用消除）。
- `android/gradle/wrapper/gradle-wrapper.properties`：**Gradle 8.14**。

### 5.4 Rust（`rust/`）
- crate `kugou_engine`，`crate-type = ["cdylib","staticlib"]`，`flutter_rust_bridge = "=2.12.0"`。
- 桌面专用依赖 `cpal/rubato` 用 `[target.'cfg(any(target_os="windows","linux","macos"))'.dependencies]` 门控 → **Android 构建不编译**。
- `[profile.release]`：`opt-level="z"`, `lto=true`, `codegen-units=1`, `strip=true`。
- 构建：`cargo ndk -t arm64-v8a -o ../android/app/src/main/jniLibs build --release`，产物落 `android/app/src/main/jniLibs/arm64-v8a/`。

### 5.5 Secrets 签名（名字固定，值永不打印）
| Secret 名 | 用途 |
|---|---|
| `RELEASE_KEYSTORE_BASE64` | keystore 的 base64，CI `base64 -d > android/app/release.keystore` |
| `RELEASE_KEYSTORE_PASSWORD` | storePassword |
| `RELEASE_KEY_ALIAS` | keyAlias（**完整读自 Secrets**） |
| `RELEASE_KEY_PASSWORD` | keyPassword（缺省回退 storePassword） |

CI 写 `android/key.properties`：`storeFile=release.keystore`（相对 `android/app`）、`storePassword`、`keyAlias`、`keyPassword`。缺前三个 secret 直接 `::error::` 退出。

### 5.6 GitHub Actions：`.github/workflows/build-android.yml`（唯一工作流）
- 触发：`push tags v*` 或 `workflow_dispatch`。`permissions: contents: read`。
- env：`FLUTTER_VERSION=3.44.8`、`JAVA_VERSION=17`、`NDK_VERSION=28.2.13676358`、`CUSTOM_PACKAGE_NAME=com.apple.android.music`。
- `runs-on: ubuntu-latest`，`timeout-minutes: 90`。
- 步骤顺序：checkout@v4 → setup-java@v4(zulu17) → setup-android@v3(`platform-tools ndk;<ver>`) → export `ANDROID_NDK_HOME` → flutter-action@v2(stable,cache) → `flutter pub get` → rust-toolchain@stable(`aarch64-linux-android`) → `cargo install cargo-ndk --locked` → rust-cache@v2(workspaces:rust) → **Configure release signing from secrets** → **Build** → Prepare artifact → upload-artifact@v4。
- 构建命令：
  ```bash
  flutter build apk --release \
    --target-platform android-arm64 \
    --android-project-arg=customPackageName=com.apple.android.music
  ```
- 产物：`build/app/outputs/flutter-apk/app-release.apk` → 复制为 `shiyin-<ref>-impeller-arm64.apk`；artifact 名 `apk-impeller-arm64-<ref>`。
- **版本校验：** 若 ref 是 `vX.Y.Z`，必须与 `pubspec.yaml` 的 `version:` 一致，否则 `::error::` 退出。

### 5.7 触发构建 & 取产物（本地无 gh）
- 本地环境**没有** java/jadx/node/python/gh/pub-cache；构建全在 GitHub Actions。可用：`unzip xxd od grep curl git`。
- 触发：push `v*` tag 或在 Actions 页 `workflow_dispatch`。
- 取产物：用 `curl` 调 GitHub REST API（凭据放 shell 变量，不回显），下载 artifact zip 后 `unzip`。**不要**用 gh CLI（未安装）。

### 5.8 本地环境限制（复现者注意）
- Windows + Git Bash；项目可能在 D:，pub cache 在 C:（故 `kotlin.incremental=false`）。
- 不在本地跑 `flutter build`（无工具链）；改完攒批 → push → Actions 构建 → curl 取 APK → 真机验证。

---

## 6. 复现检查清单（按序勾选）

- [ ] 分支 `lyrics`；仅 Android；删 windows/ios/macos/linux/web、test/、两个旧工作流。
- [ ] `applicationId=com.apple.android.music`，`namespace=shiyin.famlife.top`，`minSdk=26`，`abiFilters=arm64-v8a`。
- [ ] Manifest：Impeller meta-data=true；AudioService 两条 intent-filter action（含 `com.vivo.musicwidgetmix.support.service`）。
- [ ] `vivo_lyrics_service.dart`：metadataExtras（support_event=4095 + ucar.*）；重发 `[2,4,8,30,60,90]` 一次性 Timer + 立即发；签名去重；无 `Timer.periodic`。
- [ ] `music_audio_handler.dart`：mediaId=`hash?:id` 全链路统一；extras 含 `music.media.extras.LYRIC`/`LYRIC_IS_ALLOWED` + LyricInfo 全字段；null-aware 省略空值。
- [ ] `VivoLyricsBridge.kt`：三个 typo key 原样；一致性闸门（30×100ms）；compat+framework 双 setExtras；字段扫描 depth≤5。
- [ ] `MainActivity` 注册/注销桥；`proguard-rules.pro` 三条 keep。
- [ ] `build.gradle.kts`：require arm64；SuperLyricApi 3.4(JitPack,isChanging)；cargoBuildArm64 挂 merge*JniLibFolders。
- [ ] `build-android.yml`：四个 secret 名；版本校验；artifact 命名。
- [ ] Secrets 配齐（值不打印）；push tag/手动触发；curl 取 APK。

---

## 7. 真机验证（ground truth，别只看编译过）

1. 车机 JoviInCar：整首 LRC 滚动（metadata `LYRICS_WHOLE`）。
2. 原子随身听**大卡片**：切歌后数秒内出词（`lrc_change` + bit8）。
3. 原子岛 **MINI**：切歌后 ≤10s 出词；中途打开也能靠 30/60/90s 重发补上。
4. **锁屏岛/状态栏**：LyricInfo JSON 当前行 + 翻译/音译。
5. 本地歌曲封面：MediaStore `content://` 正常。
6. logcat 过滤 `VivoLyrics`：看 `publish result: compat=true framework=true`、`metadata: support_event=4095 mediaId=...`；若 `publish deferred` 频繁 → 检查 metadata 落地时序。
7. 已知**不可修**现象：先开大卡片再开 MINI 偶尔无词（消费方 bug，§4.7），不要回归测试时误判为本次改动失败。

---

## 附：关键文件索引（绝对路径以仓库根为准）

| 文件 | 作用 |
|---|---|
| `lib/services/vivo_lyrics_service.dart` | metadata extras + lrc_change 重发节奏 |
| `lib/services/music_audio_handler.dart` | MediaItem 歌词字段 + sync 驱动 + 三类列表 browse |
| `lib/services/vivo_library_bridge.dart` | 三类列表数据源 + mediaId 反查 + 去重 |
| `android/.../VivoLyricsBridge.kt` | 反射 setExtras + 一致性闸门 + 字段扫描 |
| `android/.../MainActivity.kt` | 桥注册（615）/注销（1473） |
| `android/.../MusicApplication.kt` | 通知渠道（phone LOW / car MIN） |
| `android/app/src/main/AndroidManifest.xml` | Impeller + AudioService 绑定 action |
| `android/app/proguard-rules.pro` | R8 keep（反射 + support 包） |
| `android/app/build.gradle.kts` | arm64/minSdk26/签名/SuperLyricApi/cargo |
| `.github/workflows/build-android.yml` | 唯一构建工作流 |
| `rust/Cargo.toml` | kugou_engine，桌面依赖 cfg 门控 |