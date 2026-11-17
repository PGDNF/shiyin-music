import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/music_models.dart';

/// 为已落盘的 FLAC 文件写入 Vorbis comment（歌名/歌手/专辑）与 PICTURE 封面。
///
/// 与 [Id3TagWriter]（MP3 专用）同一套口径：
/// - **不自行联网下载封面**：封面字节由调用方（DownloadService）从磁盘缓存
///   或网络兜底读好传入；拿不到就只写文本标签，绝不为写标签多打一次网络请求。
/// - **失败一律静默降级**：任何异常（文件被占用、磁盘满、封面损坏）都返回
///   false 并只记日志，绝不把已完整下载的音频判为失败，也不破坏原文件。
///
/// FLAC 元数据结构：文件以 `fLaC` 魔数开头，后接若干元数据块，每块 4 字节头
/// （bit7 = 是否最后一块，bit6-0 = 块类型）+ 3 字节大端长度 + 数据；最后一块
/// 之后即音频帧。块类型：0=STREAMINFO（必须首块）、1=PADDING、2=APPLICATION、
/// 3=SEEKTABLE、4=VORBIS_COMMENT、5=CUESHEET、6=PICTURE。
///
/// 写入策略：解析现有块，保留 STREAMINFO/APPLICATION/SEEKTABLE/CUESHEET，
/// 丢弃旧的 PADDING/VORBIS_COMMENT/PICTURE（二次注入是替换而非叠加），追加
/// 新的 VORBIS_COMMENT 与 PICTURE（封面为最后一块）；先写同目录临时文件
/// （新元数据 + 原音频帧字节）再 rename 覆盖，写一半被杀进程时原文件仍完整。
class FlacTagWriter {
  FlacTagWriter._();

  /// 临时文件后缀：与目标同目录，保证 rename 是同一文件系统内的原子操作。
  static const String tempSuffix = '.flac.tmp';

  /// PICTURE 封面上限（字节）：超限则跳过封面块（与 Id3TagWriter 同口径）。
  static const int maxCoverBytes = 4 * 1024 * 1024;

  /// 向 [filePath] 写入 FLAC 标签，成功返回 true；非 FLAC / 无可写字段 /
  /// 任何异常都返回 false（静默降级，调用方无需视为错误）。
  static Future<bool> injectMetadata({
    required String filePath,
    required Song song,
    Uint8List? coverBytes,
  }) async {
    if (!filePath.toLowerCase().endsWith('.flac')) return false;
    final file = File(filePath);
    try {
      if (!await file.exists()) return false;
      final fileLength = await file.length();
      final parsed = await _parseBlocks(file, fileLength);
      if (parsed == null) return false;

      final comment = _buildVorbisComment(song);
      final picture = coverBytes == null ? null : _buildPicture(coverBytes);
      // 文本与封面都没有：不动原文件（与 Id3TagWriter 空帧返回 false 一致）。
      if (comment == null && picture == null) return false;

      final out = BytesBuilder(copy: false)
        ..add(const <int>[0x66, 0x4C, 0x61, 0x43]); // 'fLaC'
      // 保留块按原序重写（STREAMINFO 仍为首块），均非最后一块。
      for (final block in parsed.preserved) {
        out
          ..add(_blockHeader(block.type, block.data.length, isLast: false))
          ..add(block.data);
      }
      if (comment != null) {
        out
          ..add(_blockHeader(4, comment.length, isLast: picture == null))
          ..add(comment);
      }
      if (picture != null) {
        out
          ..add(_blockHeader(6, picture.length, isLast: true))
          ..add(picture);
      }
      final tagBytes = out.takeBytes();

      final tmp = File('$filePath$tempSuffix');
      var renamed = false;
      try {
        final sink = tmp.openWrite();
        try {
          sink.add(tagBytes);
          // 原音频帧原样拼在元数据之后；分块流式拷贝，避免整首歌读进内存。
          if (parsed.audioOffset < fileLength) {
            await sink.addStream(file.openRead(parsed.audioOffset));
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        await tmp.rename(filePath);
        renamed = true;
        return true;
      } finally {
        if (!renamed) {
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {
            // 临时文件清理失败不影响原文件，下次注入会覆盖它。
          }
        }
      }
    } catch (error) {
      debugPrint('[FlacTagWriter] 写入 FLAC 标签失败（已忽略，不影响下载）: $error');
      return false;
    }
  }

  /// 同步读取 FLAC 元数据占用的字节数（含 `fLaC` 魔数，到最后一块结束）；
  /// 非 FLAC / 损坏 / 读失败返回 0。
  ///
  /// 供下载服务做同名文件冲突判定：写标签后目标文件比新下载的纯音频 `.part`
  /// 多出一段元数据，按「音频帧字节数」比较才是同一首歌（见
  /// DownloadService._audioContentLength）。只解析块头长度，不读块数据。
  static int existingMetadataLengthSync(File file) {
    try {
      final fileLength = file.lengthSync();
      if (fileLength < 4) return 0;
      final reader = file.openSync();
      try {
        final magic = reader.readSync(4);
        if (!_isFlacMagic(magic)) return 0;
        var offset = 4;
        while (offset + 4 <= fileLength) {
          final header = reader.readSync(4);
          if (header.length < 4) return 0;
          final isLast = (header[0] & 0x80) != 0;
          final type = header[0] & 0x7F;
          final len = (header[1] << 16) | (header[2] << 8) | header[3];
          if (type == 127 || offset + 4 + len > fileLength) return 0;
          offset += 4 + len;
          if (isLast) return offset;
          reader.setPositionSync(offset);
        }
        return 0;
      } finally {
        try {
          reader.closeSync();
        } catch (_) {}
      }
    } catch (_) {
      return 0;
    }
  }

  /// 解析现有元数据块：返回音频起点与需保留的块（类型 + 原始数据）。
  /// 非 FLAC / 缺 STREAMINFO / 损坏返回 null。丢弃块只 seek 跳过，不读进内存
  /// （旧封面可能数 MB）。
  static Future<_FlacBlocks?> _parseBlocks(File file, int fileLength) async {
    if (fileLength < 4) return null;
    RandomAccessFile? reader;
    try {
      reader = await file.open();
      final magic = await reader.read(4);
      if (!_isFlacMagic(magic)) return null;
      var offset = 4;
      var sawStreamInfo = false;
      final preserved = <({int type, Uint8List data})>[];
      while (offset + 4 <= fileLength) {
        final header = await reader.read(4);
        if (header.length < 4) return null;
        final isLast = (header[0] & 0x80) != 0;
        final type = header[0] & 0x7F;
        final len = (header[1] << 16) | (header[2] << 8) | header[3];
        if (type == 127 || offset + 4 + len > fileLength) return null;
        final nextOffset = offset + 4 + len;
        // 保留 STREAMINFO(0)/APPLICATION(2)/SEEKTABLE(3)/CUESHEET(5)；
        // 丢弃 PADDING(1)/VORBIS_COMMENT(4)/PICTURE(6) 及未知类型。
        if (type == 0 || type == 2 || type == 3 || type == 5) {
          final data = len > 0 ? await reader.read(len) : Uint8List(0);
          if (data.length < len) return null;
          preserved.add((type: type, data: data));
          if (type == 0) sawStreamInfo = true;
        } else {
          await reader.setPosition(nextOffset);
        }
        offset = nextOffset;
        if (isLast) {
          if (!sawStreamInfo) return null;
          return _FlacBlocks(audioOffset: offset, preserved: preserved);
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await reader?.close();
      } catch (_) {}
    }
  }

  /// VORBIS_COMMENT 块数据（**小端**长度）：vendor 串 + 评论数 + 若干
  /// `KEY=value`（UTF-8）。无可写字段返回 null。
  static Uint8List? _buildVorbisComment(Song song) {
    final comments = <String>[];
    if (song.title.trim().isNotEmpty) comments.add('TITLE=${song.title}');
    if (song.artist.trim().isNotEmpty) comments.add('ARTIST=${song.artist}');
    final album = song.albumName;
    if (album != null && album.trim().isNotEmpty) comments.add('ALBUM=$album');
    if (comments.isEmpty) return null;

    final vendor = utf8.encode('shiyin-music');
    final b = BytesBuilder(copy: false)
      ..add(_uint32le(vendor.length))
      ..add(vendor)
      ..add(_uint32le(comments.length));
    for (final comment in comments) {
      final bytes = utf8.encode(comment);
      b
        ..add(_uint32le(bytes.length))
        ..add(bytes);
    }
    return b.takeBytes();
  }

  /// PICTURE 块数据（**大端**）：图片类型 3=封面(front) + MIME + 空描述 +
  /// 宽/高/色深/颜色数（均 0=未知，播放器按图片数据本身解码）+ 图片字节。
  /// 格式不受支持 / 超限返回 null。
  static Uint8List? _buildPicture(Uint8List imageBytes) {
    if (imageBytes.isEmpty || imageBytes.length > maxCoverBytes) return null;
    final mime = _imageMimeType(imageBytes);
    if (mime == null) return null;
    final mimeBytes = ascii.encode(mime);
    final b = BytesBuilder(copy: false)
      ..add(_uint32be(3))
      ..add(_uint32be(mimeBytes.length))
      ..add(mimeBytes)
      ..add(_uint32be(0)) // 描述长度 0
      ..add(_uint32be(0)) // 宽
      ..add(_uint32be(0)) // 高
      ..add(_uint32be(0)) // 色深
      ..add(_uint32be(0)) // 颜色数
      ..add(_uint32be(imageBytes.length))
      ..add(imageBytes);
    return b.takeBytes();
  }

  /// 4 字节元数据块头：bit7=最后一块标志 | 类型，后接 3 字节大端数据长度。
  static Uint8List _blockHeader(int type, int length, {required bool isLast}) {
    final header = Uint8List(4);
    header[0] = (isLast ? 0x80 : 0x00) | (type & 0x7F);
    header[1] = (length >> 16) & 0xFF;
    header[2] = (length >> 8) & 0xFF;
    header[3] = length & 0xFF;
    return header;
  }

  static Uint8List _uint32be(int value) {
    final b = Uint8List(4);
    b[0] = (value >> 24) & 0xFF;
    b[1] = (value >> 16) & 0xFF;
    b[2] = (value >> 8) & 0xFF;
    b[3] = value & 0xFF;
    return b;
  }

  static Uint8List _uint32le(int value) {
    final b = Uint8List(4);
    b[0] = value & 0xFF;
    b[1] = (value >> 8) & 0xFF;
    b[2] = (value >> 16) & 0xFF;
    b[3] = (value >> 24) & 0xFF;
    return b;
  }

  static bool _isFlacMagic(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x66 &&
      bytes[1] == 0x4C &&
      bytes[2] == 0x61 &&
      bytes[3] == 0x43;

  /// 按魔数判断封面 MIME；只认 PNG/JPEG（与 Id3TagWriter 一致，老车机只认这两种）。
  static String? _imageMimeType(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    return null;
  }
}

/// 解析结果：音频帧起点 + 需保留的元数据块。
class _FlacBlocks {
  _FlacBlocks({required this.audioOffset, required this.preserved});

  final int audioOffset;
  final List<({int type, Uint8List data})> preserved;
}