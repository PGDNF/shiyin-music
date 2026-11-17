import 'package:flutter/painting.dart';
import 'package:palette_generator/palette_generator.dart';

import '../widgets/flowing_background_palette.dart';
import 'disk_cached_image_provider.dart';

/// 流光背景封面取色（Apple Music 动效移植配套）。
///
/// 复用 UI 封面同一份磁盘缓存（[DiskCachedImageProvider]），缩到 128px 再跑
/// PaletteGenerator，避免全尺寸解码；结果交给 [buildFlowingPalette] 挑 4 场
/// pigment。失败/无色返回 null → FlowingPalette.fallback 兜底。
Future<List<Color>?> loadFlowingArtworkColors(String url) async {
  if (url.isEmpty) return null;
  final provider = ResizeImage(
    DiskCachedImageProvider(url),
    width: 128,
    height: 128,
    allowUpscaling: false,
  );
  final palette = await PaletteGenerator.fromImageProvider(
    provider,
    maximumColorCount: 12,
    timeout: const Duration(seconds: 10),
  );
  final colors = <Color>[
    for (final target in PaletteTarget.values)
      if (palette.paletteColors[target] != null)
        palette.paletteColors[target]!.color,
  ];
  return colors.isEmpty ? null : colors;
}

/// 注册一次默认取色 loader（幂等）。
void ensureFlowingPaletteLoader() {
  defaultArtworkColorLoader ??= loadFlowingArtworkColors;
}