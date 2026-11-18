import 'package:flutter/painting.dart';
import 'package:palette_generator/palette_generator.dart';

import '../controllers/local_music_controller.dart';
import '../widgets/flowing_background_palette.dart';
import 'disk_cached_image_provider.dart';

/// 流光背景封面取色（Apple Music 动效移植配套）。
///
/// 复用 UI 封面同一份磁盘缓存（[DiskCachedImageProvider]），缩到 128px 再跑
/// PaletteGenerator，避免全尺寸解码；结果交给 [buildFlowingPalette] 挑 4 场
/// pigment。失败/无色返回 null → FlowingPalette.fallback 兜底。
/// 本地音乐封面是 content:// 专辑 URI（HTTP 缓存链路不认），走本地通道字节流。
Future<List<Color>?> loadFlowingArtworkColors(String url) async {
  if (url.isEmpty) return null;
  final ImageProvider<Object> provider;
  if (url.startsWith('content://')) {
    final bytes = await LocalMusicController.albumArtBytes(url);
    if (bytes == null || bytes.isEmpty) return null;
    provider = ResizeImage(
      MemoryImage(bytes),
      width: 128,
      height: 128,
      allowUpscaling: false,
    );
  } else {
    provider = ResizeImage(
      DiskCachedImageProvider(url),
      width: 128,
      height: 128,
      allowUpscaling: false,
    );
  }
  final palette = await PaletteGenerator.fromImageProvider(
    provider,
    maximumColorCount: 12,
    timeout: const Duration(seconds: 10),
  );
  final colors = palette.colors.toList();
  return colors.isEmpty ? null : colors;
}

/// 注册一次默认取色 loader（幂等）。
void ensureFlowingPaletteLoader() {
  defaultArtworkColorLoader ??= loadFlowingArtworkColors;
}