# 第三方代码出处声明

本目录（`lib/widgets/apple_lyrics/`）及下列文件移植自 md3Music 项目：

- 来源仓库：https://github.com/zzyoxml/md3Music
- 许可证：AGPL-3.0（GNU Affero General Public License v3.0）
- 移植日期：2026-11-17

## 移植范围

- `lib/widgets/apple_lyrics/**`（Apple Music 风格歌词动效；其中逐字强调/间奏点
  规则移植自 AMLL，扫光渲染与流光背景 shader 移植自 myune，上游声明见各文件头）
- `lib/widgets/flowing_background.dart`、`flowing_background_palette.dart`、
  `flowing_background_uniforms.dart`、`flowing_gradient_painter.dart`、
  `flowing_palette_transition.dart`
- `shaders/flowing_background.frag`（上游 myune，Apache-2.0）
- `lib/core/build_flags.dart`、`lib/core/platform_capabilities.dart`、
  `lib/core/utils/app_haptics.dart`、`lib/core/utils/lyric_wrap_plan.dart`、
  `lib/core/utils/lyric_line_balance.dart`、
  `lib/core/services/player_frame_driver.dart`、
  `lib/core/services/windows_default_font.dart`、
  `lib/core/services/rhythm_motion.dart`、
  `lib/core/services/spectrum_service.dart`、
  `lib/core/services/diagnostic_logger.dart`
- `lib/ui/pages/lyric_animation_settings_page.dart`（重写自
  `lib/modules/settings/lyric_animation_settings_page.dart`：M3E 滑块/按钮组
  换原生 Material，TV 遥控分支移除，toast 换宿主 Toast；预设管理/JSON
  导入导出逻辑保留）

## 本地修改

- 包名 `package:md3music/` → `package:shiyin_music/`
- 移除 `material_ui` / `m3e_core` 依赖（设置面板 `lyric_preferences_panel.dart`
  与预览页 `preview/` 未移植），补齐 Flutter 基础导入
- `flowing_background_palette.dart` 的默认取色 loader 改为宿主注入
  （`defaultArtworkColorLoader`），不再依赖 md3Music 的封面缓存服务
- `layout/lyric_preferences.dart` 新增 `seedShiyinDefaults()`：首跑仅对缺失键
  写入时音默认（模糊/辉光/交叉淡化/流光开启、锚位 0.38、副行所有行），
  不覆盖用户设置
- `layout/lyric_layout.dart` 拖动自动回位时长 3000ms → 3500ms（对齐时音）
- `apple_lyrics_view.dart` 新增 `onLongPress` / `onUserScrollingChanged` /
  `onScrollFocusLineChanged` 钩子供宿主准星胶囊与长按调偏移使用

依据 AGPL-3.0，包含本代码的组合作品分发时需以 AGPL-3.0 提供完整对应源码。