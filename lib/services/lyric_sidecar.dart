import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/music_models.dart';

/// 下载歌曲的同名 `.lrc` 歌词侧车文件读写。
///
/// 与音频文件同目录、同主名，仅扩展名换成 `.lrc`（如 `歌曲名-歌手.mp3`
/// 对应 `歌曲名-歌手.lrc`）。第三方播放器/车机普遍按同名 `.lrc` 自动加载歌词。
/// 写入/删除均为尽力而为：任何异常只记日志，绝不影响下载/删除主流程。

/// 音频路径 → 同名 `.lrc` 路径（替换最后一个扩展名；无扩展名则直接追加）。
String lyricSidecarPath(String audioPath) {
  final dot = audioPath.lastIndexOf('.');
  final slash = audioPath.lastIndexOf(RegExp(r'[/\\]'));
  final stem = dot > slash ? audioPath.substring(0, dot) : audioPath;
  return '$stem.lrc';
}

/// 把歌词行序列化为标准 LRC 文本（`[mm:ss.xx]` 时间轴 + 可选 ti/ar/al 头）。
String lyricLinesToLrc(List<LyricLine> lines, {Song? song}) {
  final buffer = StringBuffer();
  if (song != null) {
    if (song.title.trim().isNotEmpty) buffer.writeln('[ti:${song.title}]');
    if (song.artist.trim().isNotEmpty) buffer.writeln('[ar:${song.artist}]');
    final album = song.albumName;
    if (album != null && album.trim().isNotEmpty) buffer.writeln('[al:$album]');
  }
  for (final line in lines) {
    final ms = line.time.inMilliseconds;
    final minutes = ms ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    final centis = (ms % 1000) ~/ 10;
    final tag = '[${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${centis.toString().padLeft(2, '0')}]';
    buffer.writeln('$tag${line.text}');
  }
  return buffer.toString();
}

/// 写同名 `.lrc`（UTF-8）。空歌词不写；失败静默。
Future<void> writeLyricSidecar(
  String audioPath,
  List<LyricLine> lines, {
  Song? song,
}) async {
  if (lines.isEmpty) return;
  try {
    final file = File(lyricSidecarPath(audioPath));
    await file.writeAsString(lyricLinesToLrc(lines, song: song), flush: true);
  } catch (error) {
    debugPrint('[LyricSidecar] 写入 .lrc 失败（已忽略）: $error');
  }
}

/// 删除同名 `.lrc`（不存在/失败都静默）。
Future<void> deleteLyricSidecar(String audioPath) async {
  try {
    final file = File(lyricSidecarPath(audioPath));
    if (await file.exists()) await file.delete();
  } catch (_) {}
}