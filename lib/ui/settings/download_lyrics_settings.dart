import 'package:flutter/material.dart';

import '../../controllers/download_controller.dart';
import 'settings_widgets.dart';

/// 「歌词文件下载」开关（设置 → 存储与下载）。
///
/// 开启后下载歌曲时同步保存同名 `歌曲名-歌手.lrc`；在已下载页删除歌曲时
/// 一并删除该歌词文件。默认关闭。状态由 [DownloadController] 持久化，
/// 这里只负责读写与监听重建（控制器实例换绑由 ListenableBuilder 天然跟随）。
class DownloadLyricsSettings extends StatelessWidget {
  const DownloadLyricsSettings({super.key, required this.downloads});

  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) => SettingsSwitchTile(
        icon: Icons.lyrics_rounded,
        iconColor: const Color(0xFF00897B),
        title: '歌词文件下载',
        subtitle: '下载歌曲时同步保存 歌曲名-歌手.lrc',
        value: downloads.downloadLyricsEnabled,
        onChanged: (value) => downloads.setDownloadLyricsEnabled(value),
      ),
    );
  }
}