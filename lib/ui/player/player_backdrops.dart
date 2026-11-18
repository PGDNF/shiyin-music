import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import '../form_factor.dart';
import '../widgets/artwork.dart';

class ArtworkBackground extends StatefulWidget {
  const ArtworkBackground({
    super.key,
    required this.song,
    this.playing = true,
    this.pageVisible = true,
    this.blurSigma = 30,
    this.rotationEnabled = false,
  });

  final Song song;

  /// 是否正在播放：旋转+全屏模糊背景按显示刷新率持续消耗 GPU，
  /// 暂停或窗口不可见（最小化/后台，音乐还在放）时冻结在当前角度，
  /// 纯装饰动画暂停不动无可感知差异。
  final bool playing;

  /// 宿主页面是否可见：不可见时冻结旋转，避免整屏模糊+变换按刷新率空转。
  /// 播放页背景为封面/歌词页共用（始终可见），宿主恒传 true；门控交给
  /// 播放态、旋转开关与应用生命周期。
  final bool pageVisible;

  /// 高斯模糊强度（0 = 跳过模糊层，清晰原图）。默认 30 对齐 md3Music。
  final double blurSigma;

  /// 是否允许播放时缓慢旋转；关闭时角度归零保持静态背景。
  final bool rotationEnabled;

  @override
  State<ArtworkBackground> createState() => _ArtworkBackgroundState();
}

class _ArtworkBackgroundState extends State<ArtworkBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _rotationController;
  bool _appHidden = false;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 40), // 40 seconds for a full rotation
    );
    WidgetsBinding.instance.addObserver(this);
    // 组件可能在应用已不可见时才构建（如后台期间换歌重建），从当前
    // 生命周期初始化，避免首帧先转起来再等回调纠正。
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appHidden = lifecycle != null && _isHiddenState(lifecycle);
    _syncRotation();
  }

  /// 仅在窗口真正不可见（hidden/paused/detached）时冻结：最小化后桌面端
  /// 仍会继续出帧，空跑全屏模糊是切桌面掉帧的来源。仅失焦（inactive）
  /// 但窗口可见时保持旋转——桌面端多软件并排是常态，转着更自然；
  /// 移动端 inactive 只是通知栏下拉等仍可见的瞬时态，不受影响。
  static bool _isHiddenState(AppLifecycleState state) =>
      state != AppLifecycleState.resumed && state != AppLifecycleState.inactive;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appHidden = _isHiddenState(state);
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant ArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing ||
        oldWidget.pageVisible != widget.pageVisible ||
        oldWidget.rotationEnabled != widget.rotationEnabled) {
      _syncRotation();
    }
  }

  void _syncRotation() {
    if (widget.rotationEnabled &&
        widget.playing &&
        widget.pageVisible &&
        !_appHidden) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else if (_rotationController.isAnimating) {
      _rotationController.stop(canceled: false);
    }
    // 开关关闭时归零角度：静态背景保持封面正立，而不是停在斜角。
    if (!widget.rotationEnabled && _rotationController.value != 0) {
      _rotationController.value = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coverUrl = widget.song.coverUrl;
    final size = MediaQuery.sizeOf(context);
    final maxDim = math.max(size.width, size.height);
    final squareSize = maxDim * 1.2;
    // 走磁盘缓存链路：重进播放页时背景从本地字节秒出，不再等网络往返。
    // 本地音乐封面是 content:// 专辑 URI，走本地通道（与海报封面同链路）。
    // 解码档位对齐 md3：sigma≥30 强模糊只留低频，100px 小图足够且改 sigma
    // 的重栅格化极便宜（滑块实时预览）；sigma<30 保留中频结构，走全分辨率
    // 避免小图放大的色带穿帮；0 档不模糊同样全分辨率。
    final int? decodeSide = widget.blurSigma >= 30 ? 100 : null;
    Widget coverImage(String url) => url.startsWith('content://')
        ? ContentUriImage(
            uri: url,
            size: double.infinity,
            decodeSide: decodeSide,
            loadingPlaceholder: const SizedBox.shrink(),
            errorPlaceholder: const SizedBox.shrink(),
          )
        : RetryableNetworkImage(
            url: url,
            fit: BoxFit.cover,
            cacheWidth: decodeSide,
            cacheHeight: decodeSide,
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          );

    // 旋转动画背景是纯装饰性的，仅桌面 Windows 排除语义树（AXTree 竞态）。
    // 外层 RepaintBoundary 把整块装饰背景与上层 UI 的图层彻底隔离：
    // 旋转每帧都改变换，没有独立图层时会连带污染兄弟节点的缓存。
    return RepaintBoundary(
      child: ExcludeSemantics(
        excluding: isDesktopPlatform,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 始终显示渐变兜底背景，避免封面加载期间出现纯黑背景
            const FallbackBackground(),
            if (coverUrl != null)
              OverflowBox(
                maxWidth: squareSize,
                maxHeight: squareSize,
                minWidth: squareSize,
                minHeight: squareSize,
                // 旋转必须在模糊之外。旋转在内时模糊的输入每帧都在变，
                // 整块全屏图层每帧都要重跑高斯模糊，光栅缓存永远命中不了；
                // 换序后模糊结果落在 RepaintBoundary 的独立图层里只栅格化
                // 一次，每帧只付一次廉价变换。
                // 各向同性高斯对旋转可交换，且封面被 OverflowBox 放大到
                // maxDim*1.2（旋转后仍完全覆盖视口），边缘采样差异不可见。
                child: RotationTransition(
                  turns: _rotationController,
                  child: RepaintBoundary(
                    child: widget.blurSigma <= 0
                        ? coverImage(coverUrl)
                        : ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: widget.blurSigma,
                              sigmaY: widget.blurSigma,
                              // Impeller 默认 decal 会把图层外透明黑卷进
                              // 卷积核 → 屏幕四周暗晕（md3 同坑）；clamp
                              // 以边缘像素延续，暗晕消失、观感更亮。
                              tileMode: TileMode.clamp,
                            ),
                            child: coverImage(coverUrl),
                          ),
                  ),
                ),
              ),
            // 蒙版对齐 md3：均匀 rgba(0,0,0,0.35)。旧版 .32/.56/.82 渐变
            // 再叠 .12 底部过暗，封面色彩几乎被吃掉；均匀 0.35 既保文字
            // 对比度又留住封面亮度与色相。
            const ColoredBox(color: Color(0x59000000)),
          ],
        ),
      ),
    );
  }
}

class FallbackBackground extends StatelessWidget {
  const FallbackBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF153D35), Color(0xFF061219), Color(0xFF2C1320)],
        ),
      ),
    );
  }
}
