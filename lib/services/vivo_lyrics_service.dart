import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/music_models.dart';

class VivoLyricsService {
  static const _channel = MethodChannel('shiyin_music/vivo_lyrics');
  // 原子岛 mini 只在打开期间消费 lrc_change 事件：切歌后约 2s（冷启动更久）
  // 的布局切换窗口内丢弃事件，绑定后又不读已存 extras，只等下一笔事件。
  // 故切歌时立即发一笔，早期补投 +2/+4/+8 跨过冷启动窗口；之后只在
  // +30/+60/+90s 各稀疏补发一笔覆盖“mini 中途打开”，90s 后停发，避免后台
  // 持续周期重发。间距 ≥2s，避开切歌 1s 内写入风暴。大卡片持续监听不受影响。
  static const _retryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 90),
  ];

  String? _mediaId;
  String? _fullLrc;
  String? _lastSentSignature;
  final List<Timer> _retryTimers = [];

  static Map<String, dynamic> metadataExtras({
    required Song song,
    String? fullLyricLrc,
  }) {
    final hasLrc = fullLyricLrc != null && fullLyricLrc.isNotEmpty;
    return <String, dynamic>{
      'hash': song.hash,
      'songId': song.id,
      'vivomusicmix.media.metadata.support_event': 4095,
      'ucar.media.metadata.UCAR_TITLE': song.title,
      'ucar.media.metadata.UCAR_ARTIST': song.artist,
      if (hasLrc) ...{
        'ucar.media.metadata.LYRICS_WHOLE': fullLyricLrc,
        'ucar.media.metadata.LYRICS_STATUS': 0,
      },
    };
  }

  void sync({required Song song, String? fullLyricLrc}) {
    if (fullLyricLrc == null || fullLyricLrc.isEmpty) return;
    final mediaId = song.hash.isEmpty ? song.id : song.hash;
    if (mediaId.isEmpty) return;

    _mediaId = mediaId;
    _fullLrc = fullLyricLrc;

    final signature = '$mediaId\n$fullLyricLrc';
    if (signature == _lastSentSignature) return;
    _lastSentSignature = signature;
    _cancelRetries();
    for (final delay in _retryDelays) {
      _retryTimers.add(Timer(delay, () => unawaited(_publish())));
    }
    debugPrint('[VivoLyrics] sync: mediaId=$mediaId '
        'lrcLen=${fullLyricLrc.length}');
    unawaited(_publish());
  }

  Future<void> _publish() async {
    final mediaId = _mediaId;
    final fullLrc = _fullLrc;
    if (mediaId == null || fullLrc == null) return;
    try {
      final published = await _channel.invokeMethod<bool>('publish', {
        'mediaId': mediaId,
        'fullLrc': fullLrc,
      });
      if (published != true) {
        debugPrint('[VivoLyrics] native publish rejected: mediaId=$mediaId');
      } else {
        debugPrint('[VivoLyrics] publish OK: mediaId=$mediaId');
      }
    } on MissingPluginException {
      reset();
    } catch (error) {
      debugPrint('[VivoLyrics] publish failed: $error');
    }
  }

  void reset() {
    _cancelRetries();
    _mediaId = null;
    _fullLrc = null;
    _lastSentSignature = null;
  }

  void _cancelRetries() {
    for (final timer in _retryTimers) {
      timer.cancel();
    }
    _retryTimers.clear();
  }
}
