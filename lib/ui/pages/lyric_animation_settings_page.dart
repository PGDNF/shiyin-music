import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/app_haptics.dart';
import '../../widgets/apple_lyrics/layout/lyric_animation_preset_store.dart';
import '../../widgets/apple_lyrics/layout/lyric_aux_scope.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../widgets/toast.dart';

/// 歌词动画调节子页面（移植自 md3Music，AGPL-3.0，见
/// lib/widgets/apple_lyrics/NOTICE.md；M3E 组件以原生 Material 重写）。
///
/// 集中调节 AM 歌词的逐行动画参数与歌词效果强度，全部为无极滑块：
/// 非当前行缩放 / 当前行位置 / 已播字上浮 / 已播与未播透明度 /
/// 间奏点位置·大小·间距 / 切行错峰上限·步长·衰减·起点 / 预启动提前量 /
/// 模糊·辉光·动态颜色·流光背景主开关及其强度参数 / 字内渐变样式。
///
/// AppBar 重置按钮二次确认后只恢复本页参数，不调用 [LyricPreferences.reset]
/// （那会清掉字号等不在本页的设置）。
///
/// 拖动中只刷新本页标签（[_SliderTile] 内部草稿值），松手才写入偏好，
/// 避免拖动过程反复触发歌词组件重渲染。
///
/// AppBar「动画预设」按钮弹出管理面板：保存/切换/重命名/删除预设，
/// 剪贴板 JSON 导入（兼容 md3music.lyric_animation 导出格式，导入前可
/// 逐个改名）与导出（当前设置 / 全部预设）。
class LyricAnimationSettingsPage extends StatefulWidget {
  const LyricAnimationSettingsPage({super.key});

  @override
  State<LyricAnimationSettingsPage> createState() =>
      _LyricAnimationSettingsPageState();
}

class _LyricAnimationSettingsPageState
    extends State<LyricAnimationSettingsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(LyricPreferences.instance.seedShiyinDefaults());
    unawaited(LyricAnimationPresetStore.instance.load());
  }

  @override
  Widget build(BuildContext context) {
    final prefs = LyricPreferences.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('歌词动画'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: '动画预设',
            onPressed: () => _openPresetSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: '恢复本页默认',
            onPressed: () => _confirmResetAll(context, prefs),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: prefs,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _SliderTile(
                title: '歌词非当前行缩放',
                subtitle: '除当前行外所有行的字号缩放（只改大小，不改清晰度）',
                value: prefs.inactiveScale,
                min: LyricPreferences.minInactiveScaleForCurrentPlatform,
                max: LyricPreferences.maxInactiveScaleForCurrentPlatform,
                format: (v) => v.toStringAsFixed(3),
                onCommit: prefs.setInactiveScale,
              ),
              _SliderTile(
                title: '歌词当前行位置',
                value: prefs.alignPosition,
                min: LyricPreferences.minAlignPositionForCurrentPlatform,
                max: LyricPreferences.maxAlignPositionForCurrentPlatform,
                format: (v) => v.toStringAsFixed(2),
                onCommit: prefs.setAlignPosition,
              ),
              _SliderTile(
                title: '歌词行间距',
                subtitle: '行与行之间的垂直间距倍数（调小更紧凑、调大更疏朗）',
                value: prefs.lineSpacing,
                min: LyricPreferences.minLineSpacingForCurrentPlatform,
                max: LyricPreferences.maxLineSpacingForCurrentPlatform,
                format: (v) => v.toStringAsFixed(2),
                onCommit: prefs.setLineSpacing,
              ),
              _section('当前行细节'),
              _SliderTile(
                title: '已播字上浮高度',
                subtitle: '当前行已唱过的字向上浮起的高度（0 = 不上浮）',
                value: prefs.liftHeightPx,
                min: LyricPreferences.minLiftHeightPxForCurrentPlatform,
                max: LyricPreferences.maxLiftHeightPxForCurrentPlatform,
                format: (v) => '${v.toStringAsFixed(1)} px',
                onCommit: prefs.setLiftHeightPx,
              ),
              _section('歌词透明度'),
              _SliderTile(
                title: '已播歌词透明度',
                subtitle: '当前行已唱过的字与上方已播行的亮度（逐字渐变与整行'
                    '同时生效；100% = 完全不透明）',
                value: prefs.playedOpacity,
                min: LyricPreferences.minPlayedOpacityForCurrentPlatform,
                max: LyricPreferences.maxPlayedOpacityForCurrentPlatform,
                format: (v) => '${(v * 100).round()}%',
                onCommit: prefs.setPlayedOpacity,
              ),
              _SliderTile(
                title: '未播歌词透明度',
                subtitle: '当前行未唱的字与其它行的暗度（0% = 完全隐藏，'
                    '默认 40%；高斯模糊全开时仅「调低」在模糊层生效）',
                value: prefs.unplayedOpacity,
                min: LyricPreferences.minUnplayedOpacityForCurrentPlatform,
                max: LyricPreferences.maxUnplayedOpacityForCurrentPlatform,
                format: (v) => '${(v * 100).round()}%',
                onCommit: prefs.setUnplayedOpacity,
              ),
              _section('翻译 / 音译副行'),
              _buildAuxScopeTile(prefs),
              _section('间奏点（节奏点）'),
              _SliderTile(
                title: '间奏点水平位置',
                subtitle: '整组圆点左边缘相对视口的水平起点（× 字号；'
                    '1.5 = 默认，比歌词左边界右移 0.5em）',
                value: prefs.interludeDotsStartX,
                min: LyricPreferences.minInterludeDotsStartXForCurrentPlatform,
                max: LyricPreferences.maxInterludeDotsStartXForCurrentPlatform,
                format: (v) => '${v.toStringAsFixed(2)} ×字号',
                onCommit: prefs.setInterludeDotsStartX,
              ),
              _SliderTile(
                title: '间奏点圆点大小',
                subtitle: '单个圆点的半径（× 字号；0.18 = 默认）',
                value: prefs.interludeDotRadius,
                min: LyricPreferences.minInterludeDotRadiusForCurrentPlatform,
                max: LyricPreferences.maxInterludeDotRadiusForCurrentPlatform,
                format: (v) => '${v.toStringAsFixed(2)} ×字号',
                onCommit: prefs.setInterludeDotRadius,
              ),
              _SliderTile(
                title: '间奏点间距',
                subtitle: '相邻圆点圆心到圆心的距离（× 字号；0.9 = 默认）',
                value: prefs.interludeDotSpacing,
                min: LyricPreferences.minInterludeDotSpacingForCurrentPlatform,
                max: LyricPreferences.maxInterludeDotSpacingForCurrentPlatform,
                format: (v) => '${v.toStringAsFixed(2)} ×字号',
                onCommit: prefs.setInterludeDotSpacing,
              ),
              _section('切行错峰（下方行滞后跟随）'),
              _SliderTile(
                title: '错峰上限',
                subtitle: '越靠下的行最多"粘"这么久才回位',
                value: prefs.cascadeMaxDelayMs,
                min: LyricPreferences.minCascadeMaxDelayMsForCurrentPlatform,
                max: LyricPreferences.maxCascadeMaxDelayMsForCurrentPlatform,
                format: (v) => '${v.round()} ms',
                onCommit: prefs.setCascadeMaxDelayMs,
              ),
              _SliderTile(
                title: '错峰步长',
                subtitle: '相邻行的错峰时间间隔',
                value: prefs.cascadeBaseStepMs,
                min: LyricPreferences.minCascadeBaseStepMsForCurrentPlatform,
                max: LyricPreferences.maxCascadeBaseStepMsForCurrentPlatform,
                format: (v) => '${v.round()} ms',
                onCommit: prefs.setCascadeBaseStepMs,
              ),
              _SliderTile(
                title: '错峰衰减',
                subtitle: '每越过一行步长 × 1/x（越大衰减越快）',
                value: prefs.cascadeDecayX,
                min: LyricPreferences.minCascadeDecayXForCurrentPlatform,
                max: LyricPreferences.maxCascadeDecayXForCurrentPlatform,
                format: (v) => '1/${v.toStringAsFixed(2)}',
                onCommit: prefs.setCascadeDecayX,
              ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('错峰从当前行上方开始'),
                subtitle: const Text(
                  '开启：当前行的上一行领头回位，以下各行依次跟随；'
                  '关闭：从视口顶部开始错峰（慢歌提前预滚动消除当前行'
                  '滞后，快歌滞后固定为 3 倍步长）',
                ),
                value: prefs.staggerFromCurrentLine,
                onChanged: prefs.setStaggerFromCurrentLine,
              ),
              if (!prefs.staggerFromCurrentLine)
                _SliderTile(
                  title: '预启动提前量微调',
                  subtitle: '级联比换行边界再提前这么多毫秒，给弹簧留收敛时间'
                      '（0 = 恰在边界释放）',
                  value: prefs.preStartBiasMs,
                  min: LyricPreferences.minPreStartBiasMs,
                  max: LyricPreferences.maxPreStartBiasMs,
                  format: (v) => '${v.round()} ms',
                  onCommit: prefs.setPreStartBiasMs,
                ),
              _section('歌词效果'),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('歌词高斯模糊'),
                subtitle: const Text('非当前行模糊景深，关闭后所有行清晰'),
                value: prefs.useGaussianBlur,
                onChanged: prefs.setUseGaussianBlur,
              ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('歌词辉光效果'),
                subtitle: const Text('长时值的字触发呼吸辉光'),
                value: prefs.useGlowEffect,
                onChanged: prefs.setUseGlowEffect,
              ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('歌词动态颜色'),
                subtitle: const Text('当前行颜色混入封面提取色'),
                value: prefs.useDynamicLyricColor,
                onChanged: prefs.setUseDynamicLyricColor,
              ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('流光背景'),
                subtitle: const Text('封面与歌词页共用：封面取色驱动的流光渐变背景'),
                value: prefs.useFlowingBackground,
                onChanged: prefs.setUseFlowingBackground,
              ),
              if (prefs.useDynamicLyricColor)
                _SliderTile(
                  title: '动态颜色混色比例',
                  subtitle: '当前行颜色 = 白色与封面提取色的混色比例',
                  value: prefs.dynamicColorMixRatio,
                  min:
                      LyricPreferences.minDynamicColorMixRatioForCurrentPlatform,
                  max:
                      LyricPreferences.maxDynamicColorMixRatioForCurrentPlatform,
                  format: (v) => '${(v * 100).round()}%',
                  onCommit: prefs.setDynamicColorMixRatio,
                ),
              if (prefs.useGaussianBlur) ...[
                _SliderTile(
                  title: '歌词模糊强度',
                  subtitle: '非当前行高斯模糊强度倍数；调低或关闭「歌词高斯模糊」'
                      '可让其它行更清楚',
                  value: prefs.blurIntensity,
                  min: LyricPreferences.minBlurIntensityForCurrentPlatform,
                  max: LyricPreferences.maxBlurIntensityForCurrentPlatform,
                  format: (v) => v.toStringAsFixed(1),
                  onCommit: prefs.setBlurIntensity,
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text('模糊等级渐变切换'),
                  subtitle: const Text(
                    '切行时不同模糊程度的图用透明度交叉淡入淡出，'
                    '时长在下方调节；关闭时保持原有直接切换（默认）',
                  ),
                  value: prefs.blurLevelCrossfade,
                  onChanged: prefs.setBlurLevelCrossfade,
                ),
                _SliderTile(
                  title: '模糊等级渐变时长',
                  subtitle: '交叉淡入淡出的持续时间，最长 1000ms（需开启渐变切换）',
                  value: prefs.blurLevelFadeMs,
                  min: LyricPreferences.minBlurLevelFadeMs,
                  max: LyricPreferences.maxBlurLevelFadeMs,
                  format: (v) => '${v.round()} ms',
                  onCommit: prefs.setBlurLevelFadeMs,
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text('提前换行'),
                  subtitle: const Text(
                    '当前行逐字完成后提前滚到下一行，但保持模糊与缩放，'
                    '等字内渐变开始才激活（仅逐字歌词生效，默认关闭）',
                  ),
                  value: prefs.earlyLineSwitch,
                  onChanged: prefs.setEarlyLineSwitch,
                ),
                _SliderTile(
                  title: '模糊褪去时长',
                  subtitle: '下一行变当前行时，旧模糊图褪去的时长上限，'
                      '最长 1000ms（清晰层亮得更快会跟着更早退完）',
                  value: prefs.entryBlurFadeMs,
                  min: LyricPreferences.minEntryBlurFadeMs,
                  max: LyricPreferences.maxEntryBlurFadeMs,
                  format: (v) => '${v.round()} ms',
                  onCommit: prefs.setEntryBlurFadeMs,
                ),
              ],
              if (prefs.useGlowEffect)
                _SliderTile(
                  title: '辉光强度',
                  subtitle: '辉光亮度倍数，只调亮度不改光形',
                  value: prefs.glowIntensity,
                  min: LyricPreferences.minGlowIntensityForCurrentPlatform,
                  max: LyricPreferences.maxGlowIntensityForCurrentPlatform,
                  format: (v) => '${(v * 100).round()}%',
                  onCommit: prefs.setGlowIntensity,
                ),
              _buildGlowModeTile(prefs),
              if (prefs.glowThresholdMode == GlowThresholdMode.adaptive)
                _SliderTile(
                  title: '辉光触发阈值',
                  subtitle: '触发阈值 = 歌词字长中位数 × 该系数（越小越易触发）',
                  value: prefs.glowThresholdFactor,
                  min:
                      LyricPreferences.minGlowThresholdFactorForCurrentPlatform,
                  max:
                      LyricPreferences.maxGlowThresholdFactorForCurrentPlatform,
                  format: (v) => v.toStringAsFixed(1),
                  onCommit: prefs.setGlowThresholdFactor,
                ),
              if (prefs.glowThresholdMode == GlowThresholdMode.fixed)
                _SliderTile(
                  title: '辉光固定时长',
                  subtitle: '字时长 ≥ 该固定阈值才触发辉光（固定判定模式）',
                  value: prefs.glowFixedThresholdMs,
                  min:
                      LyricPreferences.minGlowFixedThresholdMsForCurrentPlatform,
                  max:
                      LyricPreferences.maxGlowFixedThresholdMsForCurrentPlatform,
                  format: (v) => '${v.round()} ms',
                  onCommit: prefs.setGlowFixedThresholdMs,
                ),
              _buildFillModeTile(prefs),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _section(String title) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  /// 「字内渐变样式」二选一（经典 ⇄ 扫光）。
  Widget _buildFillModeTile(LyricPreferences prefs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: 16),
          title: Text('字内渐变样式'),
          subtitle: Text(
            '经典 = 宽过渡带（旧观感）；'
            '扫光 = 锐利且按字长/时长自适应、更快掠过字间空白（默认）',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('经典')),
                ButtonSegment(value: 1, label: Text('扫光')),
              ],
              selected: {prefs.fillMode == LyricFillMode.sweep ? 1 : 0},
              onSelectionChanged: (selection) {
                prefs.setFillMode(
                  selection.first == 1 ? LyricFillMode.sweep : LyricFillMode.classic,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 「辉光判定方式」二选一（自适应 ⇄ 固定时长）。
  Widget _buildGlowModeTile(LyricPreferences prefs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: 16),
          title: Text('辉光判定方式'),
          subtitle: Text(
            '自适应 = 按歌曲节奏 / 字长 × 系数推断阈值；'
            '固定时长 = 字时长 ≥ 固定阈值才触发辉光',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('自适应')),
                ButtonSegment(value: 1, label: Text('固定时长')),
              ],
              selected: {
                prefs.glowThresholdMode == GlowThresholdMode.fixed ? 1 : 0,
              },
              onSelectionChanged: (selection) {
                prefs.setGlowThresholdMode(
                  selection.first == 1
                      ? GlowThresholdMode.fixed
                      : GlowThresholdMode.adaptive,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 「副行显示范围」二选一（当前行 ⇄ 所有行）。
  ///
  /// 当前行 = 翻译/音译随切行展开收起（带出现/消失动画，md3 默认观感）；
  /// 所有行 = 每行副行常驻（进度恒 1，无展开收起动画）。
  Widget _buildAuxScopeTile(LyricPreferences prefs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: 16),
          title: Text('副行显示范围'),
          subtitle: Text(
            '当前行 = 翻译/音译只跟随当前行展开收起（有出现与消失动画）；'
            '所有行 = 每行副行常驻显示（无展开收起动画）',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('当前行')),
                ButtonSegment(value: 1, label: Text('所有行')),
              ],
              selected: {prefs.auxScope == LyricAuxScope.allLines ? 1 : 0},
              onSelectionChanged: (selection) {
                prefs.setAuxScope(
                  selection.first == 1
                      ? LyricAuxScope.allLines
                      : LyricAuxScope.currentLine,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 二次确认后把本页全部参数恢复默认（不动字号/行距等页外设置）。
  Future<void> _confirmResetAll(
    BuildContext context,
    LyricPreferences prefs,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('恢复本页默认值'),
          content: const Text(
            '将把本页全部参数（非当前行缩放、当前行位置、歌词行间距、已播字上浮高度、'
            '已播歌词透明度、未播歌词透明度、副行显示范围、'
            '间奏点水平位置、间奏点圆点大小、间奏点间距、'
            '错峰上限/步长/衰减、错峰起点开关、歌词模糊强度、'
            '模糊等级渐变切换、模糊等级渐变时长、提前换行、模糊褪去时长、'
            '动态颜色混色比例、辉光强度、辉光触发阈值、'
            '辉光判定方式、辉光固定时长、字内渐变样式）'
            '恢复为默认值，确定继续吗？',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('恢复默认'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    AppHaptics.mediumImpact(HapticCategory.control);
    await prefs.setInactiveScale(
        LyricPreferences.defaultInactiveScaleForCurrentPlatform);
    await prefs.setAlignPosition(
        LyricPreferences.defaultAlignPositionForCurrentPlatform);
    await prefs.setLineSpacing(
        LyricPreferences.defaultLineSpacingForCurrentPlatform);
    await prefs.setLiftHeightPx(
        LyricPreferences.defaultLiftHeightPxForCurrentPlatform);
    await prefs.setPlayedOpacity(
        LyricPreferences.defaultPlayedOpacityForCurrentPlatform);
    await prefs.setUnplayedOpacity(
        LyricPreferences.defaultUnplayedOpacityForCurrentPlatform);
    await prefs.setAuxScope(LyricAuxScope.currentLine);
    await prefs.setInterludeDotsStartX(
        LyricPreferences.defaultInterludeDotsStartXForCurrentPlatform);
    await prefs.setInterludeDotRadius(
        LyricPreferences.defaultInterludeDotRadiusForCurrentPlatform);
    await prefs.setInterludeDotSpacing(
        LyricPreferences.defaultInterludeDotSpacingForCurrentPlatform);
    await prefs.setCascadeMaxDelayMs(
        LyricPreferences.defaultCascadeMaxDelayMsForCurrentPlatform);
    await prefs.setCascadeBaseStepMs(
        LyricPreferences.defaultCascadeBaseStepMsForCurrentPlatform);
    await prefs.setCascadeDecayX(
        LyricPreferences.defaultCascadeDecayXForCurrentPlatform);
    await prefs
        .setStaggerFromCurrentLine(LyricPreferences.defaultStaggerFromCurrentLine);
    await prefs.setPreStartBiasMs(LyricPreferences.minPreStartBiasMs);
    await prefs.setBlurIntensity(
        LyricPreferences.defaultBlurIntensityForCurrentPlatform);
    await prefs.setBlurLevelCrossfade(false);
    await prefs.setBlurLevelFadeMs(LyricPreferences.defaultBlurLevelFadeMs);
    await prefs.setEarlyLineSwitch(false);
    await prefs.setEntryBlurFadeMs(LyricPreferences.defaultEntryBlurFadeMs);
    await prefs.setDynamicColorMixRatio(
        LyricPreferences.defaultDynamicColorMixRatioForCurrentPlatform);
    await prefs.setGlowThresholdFactor(
        LyricPreferences.defaultGlowThresholdFactorForCurrentPlatform);
    await prefs.setGlowIntensity(
        LyricPreferences.defaultGlowIntensityForCurrentPlatform);
    await prefs.setGlowThresholdMode(GlowThresholdMode.fixed);
    await prefs.setGlowFixedThresholdMs(
        LyricPreferences.defaultGlowFixedThresholdMsForCurrentPlatform);
    await prefs.setFillMode(LyricFillMode.sweep);
    Toast.success('已恢复本页全部默认值');
  }

  Future<void> _openPresetSheet(BuildContext context) async {
    AppHaptics.tick(HapticCategory.control);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _AnimationPresetSheet(),
    );
  }
}

/// 无极滑块 tile：拖动中只刷新本地草稿（标签跟随），松手才写入偏好，
/// 避免拖动过程反复通知歌词组件重渲染。
class _SliderTile extends StatefulWidget {
  const _SliderTile({
    required this.title,
    this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onCommit,
  });

  final String title;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onCommit;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  late double _draft = widget.value;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant _SliderTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && widget.value != oldWidget.value) {
      _draft = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = _draft.clamp(widget.min, widget.max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(widget.title),
          subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
          trailing: Text(widget.format(value)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Slider(
            value: value,
            min: widget.min,
            max: widget.max,
            label: widget.format(value),
            onChanged: (v) {
              _dragging = true;
              setState(() => _draft = v);
            },
            onChangeEnd: (v) {
              _dragging = false;
              widget.onCommit(v);
            },
          ),
        ),
      ],
    );
  }
}

/// 「动画预设」底部管理面板。
///
/// 保存当前设置为预设（同名覆盖）、点击切换、长按重命名、行尾删除；
/// 剪贴板 JSON 导入（导入前可逐个改名）/ 导出（当前设置、全部预设）。
/// 同时监听预设仓库与 [LyricPreferences]：应用预设后对勾立即跟随。
class _AnimationPresetSheet extends StatelessWidget {
  const _AnimationPresetSheet();

  static const String _emptyHint =
      '还没有自定义预设。调好参数后点「保存当前设置为预设」，'
      '或用「从剪贴板导入」导入 JSON。';

  @override
  Widget build(BuildContext context) {
    final store = LyricAnimationPresetStore.instance;
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        store,
        LyricPreferences.instance,
      ]),
      builder: (context, _) {
        final activeName = store.activePresetName();
        final allPresets = store.allPresets;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('动画预设', style: theme.textTheme.titleLarge),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  FilledButton.icon(
                    onPressed: () => _saveCurrentAsPreset(context),
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('保存当前设置为预设'),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: () => _importFromClipboard(context),
                        icon: const Icon(Icons.content_paste_go, size: 18),
                        label: const Text('从剪贴板导入'),
                      ),
                      TextButton.icon(
                        onPressed: () => _copyCurrentJson(context),
                        icon: const Icon(Icons.content_copy, size: 18),
                        label: const Text('复制当前设置'),
                      ),
                      TextButton.icon(
                        onPressed: () => _copyAllJson(context),
                        icon: const Icon(Icons.copy_all, size: 18),
                        label: const Text('复制全部预设'),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  if (store.presets.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        _emptyHint,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: allPresets.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final preset = allPresets[index];
                        final isActive = preset.name == activeName;
                        final isBuiltIn =
                            LyricAnimationPresetStore.isBuiltInPreset(
                          preset.name,
                        );
                        final platformLabel =
                            LyricAnimationPresetStore.platformLabel(
                          preset.platform,
                        );
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            isActive
                                ? Icons.check_circle
                                : Icons.bookmark_border,
                            color: isActive
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          title: Text(preset.name),
                          subtitle: Text(
                            isBuiltIn
                                ? _builtInSubtitle(preset.name)
                                : (platformLabel.isEmpty
                                    ? '点击切换 · 长按重命名'
                                    : '$platformLabel · 点击切换 · 长按重命名'),
                          ),
                          onTap: () => _applyPreset(context, preset.name),
                          onLongPress: isBuiltIn
                              ? () => Toast.show('内置预设不可修改或删除')
                              : () => _renamePreset(context, preset.name),
                          trailing: isBuiltIn
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: '删除预设',
                                  onPressed: () =>
                                      _confirmDelete(context, preset.name),
                                ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _builtInSubtitle(String name) {
    final note = LyricAnimationPresetStore.builtInPresetDescriptions[name];
    const hint = '内置兜底 · 点击应用（不可删除或修改）';
    return note == null || note.isEmpty ? hint : '$note · $hint';
  }

  Future<void> _applyPreset(BuildContext context, String name) async {
    await LyricAnimationPresetStore.instance.applyPreset(name);
    if (!context.mounted) return;
    AppHaptics.tick(HapticCategory.control);
    Toast.success('已切换到「$name」');
  }

  Future<void> _saveCurrentAsPreset(BuildContext context) async {
    final name = await _askPresetName(context);
    if (name == null || !context.mounted) return;
    final isNew =
        await LyricAnimationPresetStore.instance.saveCurrentAsPreset(name);
    if (!context.mounted) return;
    AppHaptics.mediumImpact(HapticCategory.control);
    Toast.success(isNew ? '已保存预设「$name」' : '已更新预设「$name」');
  }

  Future<String?> _askPresetName(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => _PresetNameDialog(
        title: '保存为预设',
        confirmLabel: '保存',
        reservedNames: LyricAnimationPresetStore.builtInPresetNames,
        existingNames: LyricAnimationPresetStore.instance.presets
            .map((preset) => preset.name)
            .toSet(),
      ),
    );
  }

  Future<void> _renamePreset(BuildContext context, String name) async {
    final store = LyricAnimationPresetStore.instance;
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _PresetNameDialog(
        title: '重命名预设',
        confirmLabel: '重命名',
        initialName: name,
        allowOverwrite: false,
        reservedNames: LyricAnimationPresetStore.builtInPresetNames,
        existingNames: store.presets
            .where((preset) => preset.name != name)
            .map((preset) => preset.name)
            .toSet(),
      ),
    );
    if (newName == null || !context.mounted) return;
    if (newName == name) return;

    final renamed = await store.renamePreset(name, newName);
    if (!context.mounted) return;
    if (!renamed) {
      Toast.show('已存在同名预设', duration: const Duration(seconds: 4));
      return;
    }
    AppHaptics.mediumImpact(HapticCategory.control);
    Toast.success('已重命名为「$newName」');
  }

  Future<void> _confirmDelete(BuildContext context, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('删除预设'),
          content: Text('确定删除「$name」吗？此操作不可撤销。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;
    await LyricAnimationPresetStore.instance.deletePreset(name);
    if (!context.mounted) return;
    AppHaptics.mediumImpact(HapticCategory.control);
    Toast.success('已删除预设「$name」');
  }

  Future<void> _importFromClipboard(BuildContext context) async {
    String text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text?.trim() ?? '';
    } catch (error) {
      debugPrint('[LyricAnimation] 读取剪贴板失败: $error');
      if (context.mounted) Toast.error('读取剪贴板失败');
      return;
    }
    if (text.isEmpty) {
      if (context.mounted) Toast.show('剪贴板为空，请先复制 JSON 文本');
      return;
    }

    // 先解析（不落盘），再弹名称编辑弹窗，导入前可自定义每一档名称。
    final List<LyricAnimationPreset> presets;
    try {
      presets = LyricAnimationPresetStore.instance.parsePresetsFromJson(text);
    } on FormatException catch (error) {
      if (!context.mounted) return;
      Toast.error('导入失败：${error.message}');
      return;
    } catch (error) {
      debugPrint('[LyricAnimation] 解析 JSON 失败: $error');
      if (context.mounted) Toast.error('导入失败：$error');
      return;
    }
    if (!context.mounted) return;

    final names = await _askImportNames(context, presets);
    if (names == null || !context.mounted) return;

    try {
      final count = await LyricAnimationPresetStore.instance
          .importPresets(presets, names: names);
      if (!context.mounted) return;
      AppHaptics.mediumImpact(HapticCategory.control);
      Toast.success('已导入 $count 个预设');
    } catch (error) {
      debugPrint('[LyricAnimation] 导入预设失败: $error');
      if (!context.mounted) return;
      Toast.error('导入失败：$error');
    }
  }

  Future<List<String>?> _askImportNames(
    BuildContext context,
    List<LyricAnimationPreset> presets,
  ) {
    final used = <String>{};
    final defaults = <String>[];
    for (final preset in presets) {
      var name = preset.name.trim().isEmpty ? '导入预设' : preset.name.trim();
      if (LyricAnimationPresetStore.isBuiltInPreset(name)) {
        var suffix = 2;
        var candidate = '$name $suffix';
        while (used.contains(candidate)) {
          suffix++;
          candidate = '$name $suffix';
        }
        name = candidate;
      }
      if (used.contains(name)) {
        var suffix = 2;
        var candidate = '$name $suffix';
        while (used.contains(candidate)) {
          suffix++;
          candidate = '$name $suffix';
        }
        name = candidate;
      }
      used.add(name);
      defaults.add(name);
    }
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _ImportNamesDialog(
        initialNames: defaults,
        platformLabels: presets
            .map((preset) =>
                LyricAnimationPresetStore.platformLabel(preset.platform))
            .toList(growable: false),
      ),
    );
  }

  Future<void> _copyCurrentJson(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _PresetNameDialog(
        title: '导出当前设置',
        confirmLabel: '复制',
        initialName: '当前设置',
        existingNames: <String>{},
      ),
    );
    if (name == null || !context.mounted) return;

    final json =
        LyricAnimationPresetStore.instance.exportCurrentAsJson(name: name);
    try {
      await Clipboard.setData(ClipboardData(text: json));
      if (!context.mounted) return;
      AppHaptics.tick(HapticCategory.control);
      Toast.success('已复制「$name」为 JSON');
    } catch (error) {
      debugPrint('[LyricAnimation] 复制 JSON 失败: $error');
      if (context.mounted) Toast.error('复制失败：$error');
    }
  }

  Future<void> _copyAllJson(BuildContext context) async {
    final store = LyricAnimationPresetStore.instance;
    if (store.presets.isEmpty) {
      Toast.show('还没有可导出的预设');
      return;
    }
    final json = store.exportAllAsJson();
    try {
      await Clipboard.setData(ClipboardData(text: json));
      if (!context.mounted) return;
      AppHaptics.tick(HapticCategory.control);
      Toast.success('已复制全部 ${store.presets.length} 个预设为 JSON');
    } catch (error) {
      debugPrint('[LyricAnimation] 复制 JSON 失败: $error');
      if (context.mounted) Toast.error('复制失败：$error');
    }
  }
}

/// 预设名称输入弹窗（保存 / 重命名 / 导出共用）。
///
/// [allowOverwrite] = true 时同名仅提示「将被覆盖」；false 时（重命名）
/// 同名视为冲突并禁用确认按钮。
class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog({
    required this.title,
    required this.existingNames,
    this.initialName = '',
    this.allowOverwrite = true,
    this.reservedNames = const <String>{},
    this.confirmLabel = '保存',
  });

  final String title;
  final Set<String> existingNames;
  final String initialName;
  final bool allowOverwrite;
  final Set<String> reservedNames;
  final String confirmLabel;

  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _controller.text.trim();
    final reserved = widget.reservedNames.contains(trimmed);
    final conflict =
        trimmed.isNotEmpty && widget.existingNames.contains(trimmed);
    final blocked = trimmed.isEmpty ||
        reserved ||
        (conflict && !widget.allowOverwrite);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: LyricAnimationPresetStore.maxNameLength,
        decoration: InputDecoration(
          hintText: '例如：慢歌错峰、现场感',
          helperText: reserved
              ? '该名称为内置预设保留'
              : (conflict
                  ? (widget.allowOverwrite ? '同名预设将被覆盖' : '已存在同名预设')
                  : null),
        ),
        onChanged: (_) => setState(() {}),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              blocked ? null : () => Navigator.of(context).pop(trimmed),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 导入预设时的名称编辑弹窗：每档预设一个输入框，可逐个改名后确认。
class _ImportNamesDialog extends StatefulWidget {
  const _ImportNamesDialog({
    required this.initialNames,
    required this.platformLabels,
  });

  final List<String> initialNames;
  final List<String> platformLabels;

  @override
  State<_ImportNamesDialog> createState() => _ImportNamesDialogState();
}

class _ImportNamesDialogState extends State<_ImportNamesDialog> {
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = widget.initialNames
        .map((name) => TextEditingController(text: name))
        .toList(growable: false);
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  String _labelFor(int index, bool single) {
    final platform =
        index < widget.platformLabels.length ? widget.platformLabels[index] : '';
    if (single) {
      return platform.isEmpty ? '预设名称' : '预设名称（$platform）';
    }
    return platform.isEmpty ? '预设 ${index + 1}' : '预设 ${index + 1}（$platform）';
  }

  @override
  Widget build(BuildContext context) {
    final single = _controllers.length == 1;
    final sourceLabels =
        widget.platformLabels.where((label) => label.isNotEmpty).toSet();
    final sourceHint =
        sourceLabels.isEmpty ? '' : '来源平台：${sourceLabels.join(' / ')}。';
    return AlertDialog(
      title: const Text('导入预设'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$sourceHint共 ${_controllers.length} 个预设，可修改名称后导入。'
                '同名预设会被覆盖。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _controllers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _controllers[i],
                    maxLength: LyricAnimationPresetStore.maxNameLength,
                    decoration: InputDecoration(
                      labelText: _labelFor(i, single),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _controllers.map((controller) => controller.text.trim()).toList(),
          ),
          child: const Text('导入'),
        ),
      ],
    );
  }
}