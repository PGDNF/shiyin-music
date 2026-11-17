import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/player_controller.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 「播后缓存延迟」设置项（设置 → 存储与下载）。
///
/// 默认稳定播放 15s 后才后台缓存当前歌曲；这里把秒数开放给用户自定
/// （1–600），越大越省流量（只听一会儿的歌不缓存）。状态由
/// [PlayerController] 持久化，监听重建以反映控制器异步恢复/外部修改。
class PlayCacheDelaySettings extends StatefulWidget {
  const PlayCacheDelaySettings({super.key, required this.player});

  final PlayerController player;

  @override
  State<PlayCacheDelaySettings> createState() => _PlayCacheDelaySettingsState();
}

class _PlayCacheDelaySettingsState extends State<PlayCacheDelaySettings> {
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_handleChanged);
  }

  @override
  void didUpdateWidget(covariant PlayCacheDelaySettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      oldWidget.player.removeListener(_handleChanged);
      widget.player.addListener(_handleChanged);
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_handleChanged);
    super.dispose();
  }

  void _handleChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _edit() async {
    if (_saving) return;
    final controller = TextEditingController(
      text: widget.player.playCacheDelaySeconds.toString(),
    );
    final seconds = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('播后缓存延迟'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '稳定播放多少秒后才缓存当前歌曲。越大越省流量，'
                '只听一会儿的歌不会缓存。范围 1–600 秒。',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: '秒数',
                  suffixText: '秒',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) =>
                    Navigator.of(dialogContext).pop(int.tryParse(value)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(int.tryParse(controller.text)),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (seconds == null || !mounted) return; // null = 取消或非法输入
    if (seconds < 1 || seconds > 600) {
      Toast.error('请输入 1–600 之间的秒数');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.player.setPlayCacheDelaySeconds(seconds);
      debugPrint('[设置] 播后缓存延迟已更新: ${seconds}s');
    } catch (error) {
      debugPrint('[设置] 保存播后缓存延迟失败: $error');
      if (mounted) Toast.error('保存失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      icon: Icons.timer_rounded,
      iconColor: const Color(0xFFFB8C00),
      title: '播后缓存延迟',
      subtitle: '播放 ${widget.player.playCacheDelaySeconds} 秒后才缓存当前歌曲',
      loading: _saving,
      onTap: _edit,
    );
  }
}