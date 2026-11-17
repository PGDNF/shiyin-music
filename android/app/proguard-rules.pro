# VivoLyricsBridge 通过反射访问 AudioService 内部字段，
# R8 不得重命名这两个字段（否则 NoSuchFieldException）。
-keepclassmembers class com.ryanheise.audioservice.AudioService {
    static *** instance;
    *** mediaSession;
}

# MediaSessionCompat/MediaControllerCompat/MediaMetadataCompat 同样被反射调用
# （setExtras/getController/getMetadata/getLong/getString）。
# R8 已把 MediaSessionCompat 混淆成 android.support.v4.media.session.t，
# 必须整包 keep，否则 NoSuchMethodException。
-keep class android.support.v4.media.session.** { *; }
-keep class android.support.v4.media.MediaMetadataCompat { *; }