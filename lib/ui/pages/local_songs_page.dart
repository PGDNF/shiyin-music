import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../adaptive_layout.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../models/music_models.dart';
import '../widgets/toast.dart';
import '../widgets/app_search_field.dart';
import '../widgets/app_song_row.dart';
import '../widgets/mini_player.dart';
import '../player/song_tap_handler.dart';

class LocalSongsPage extends StatefulWidget {
  const LocalSongsPage({
    super.key,
    required this.player,
    required this.auth,
    required this.localMusic,
  });

  final PlayerController player;
  final AuthController auth;
  final LocalMusicController localMusic;

  @override
  State<LocalSongsPage> createState() => _LocalSongsPageState();
}

class _LocalSongsPageState extends State<LocalSongsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // 当前播放歌曲自动定位（切歌后滚动到可视区域中部）。
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _currentSongRowKey = GlobalKey();
  String? _lastLocatedSongIdentity;
  bool _locateScheduled = false;

  /// 懒构建列表的统一估算行高（与 AppSongRow 视觉行高一致）。
  static const double _estimatedRowHeight = 62;

  /// 歌曲身份：hash 优先，缺失时回落 id（本地歌曲两者同为文件路径）。
  String _songIdentity(Song song) =>
      song.hash.isNotEmpty ? song.hash : song.id;

  bool _isSameSong(Song a, Song b) =>
      identical(a, b) || _songIdentity(a) == _songIdentity(b);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 切歌后把当前歌曲行带到可视区域中部：先按估算行高 animateTo，
  /// 再用 Scrollable.ensureVisible 对真实行做精确校正。身份只在滚动回调
  /// 真正执行时写入，避免多次 build/过滤切换造成定位丢失后无法重试。
  void _maybeLocateCurrentSong(List<Song> filteredSongs) {
    final current = widget.player.currentSong;
    if (current == null) {
      _lastLocatedSongIdentity = null;
      return;
    }
    final identity = _songIdentity(current);
    final index = filteredSongs.indexWhere((s) => _isSameSong(s, current));
    if (index < 0) {
      // 当前歌曲被搜索条件过滤掉：清空身份，重新进入可见列表后仍可定位。
      _lastLocatedSongIdentity = null;
      return;
    }
    if (identity == _lastLocatedSongIdentity || _locateScheduled) return;
    _locateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _locateScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target = (index * _estimatedRowHeight -
              position.viewportDimension / 2 +
              _estimatedRowHeight / 2)
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      _lastLocatedSongIdentity = identity;
      _scrollController
          .animateTo(
            target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            if (!mounted) return;
            final rowContext = _currentSongRowKey.currentContext;
            if (rowContext != null) {
              Scrollable.ensureVisible(
                rowContext,
                duration: const Duration(milliseconds: 120),
                alignment: 0.5,
                curve: Curves.easeOut,
              );
            }
          });
    });
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.trim().toLowerCase();
    });
  }

  Future<void> _requestPermission() async {
    final granted = await widget.localMusic.requestPermission();
    if (granted) {
      Toast.success('授权成功，正在扫描本地音乐');
    } else {
      Toast.error('未授予音频访问权限');
    }
  }

  // ---- 桌面（Windows/Linux）：目录添加 / 管理 ----

  bool get _isDesktop => LocalMusicController.isDesktopScanSupported;

  /// file_picker 选择目录加入扫描根（选择器打开较慢，先给 loading 提示）。
  Future<void> _pickAndAddDesktopRoot() async {
    Toast.info('请选择音乐文件夹...');
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择音乐文件夹',
      lockParentWindow: true,
    );
    if (directory == null) return;
    await widget.localMusic.addDesktopRoot(directory);
    Toast.success('已添加目录，正在扫描本地音乐');
  }

  /// 桌面目录管理：列出扫描根，可删除/继续添加。
  void _showDesktopRootsDialog() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AnimatedBuilder(
          animation: widget.localMusic,
          builder: (context, _) {
            final colorScheme = Theme.of(dialogContext).colorScheme;
            final roots = widget.localMusic.desktopRoots;
            return AlertDialog(
              title: const Text('音乐目录'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: SizedBox(
                  width: double.maxFinite,
                  child: roots.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            '尚未添加任何目录。添加后时会递归扫描目录内的音频文件。',
                            style: Theme.of(dialogContext).textTheme.bodyMedium
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: roots.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final root = roots[index];
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                Icons.folder_rounded,
                                color: colorScheme.primary.withValues(alpha: .8),
                              ),
                              title: Text(
                                root,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              trailing: IconButton(
                                tooltip: '移除目录',
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: colorScheme.error,
                                ),
                                onPressed: widget.localMusic.isScanning
                                    ? null
                                    : () => widget.localMusic
                                        .removeDesktopRoot(root),
                              ),
                            );
                          },
                        ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
                FilledButton.icon(
                  onPressed: widget.localMusic.isScanning
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                          _pickAndAddDesktopRoot();
                        },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('添加目录'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 打开「扫描目录设置」：勾选/取消勾选文件夹以排除录音等目录。
  void _showFolderFilterSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return AnimatedBuilder(
          animation: widget.localMusic,
          builder: (context, _) {
            final folders = widget.localMusic.availableFolders;
            final excludedCount = widget.localMusic.excludedFolders.length;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '扫描目录设置',
                              style: Theme.of(sheetContext).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                          ),
                          if (excludedCount > 0)
                            TextButton(
                              onPressed: () =>
                                  widget.localMusic.clearExcludedFolders(),
                              child: const Text('恢复全部'),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                      child: Text(
                        '取消勾选的文件夹将从本地音乐中排除（例如录音文件夹），'
                        '其子目录中的音频也不会显示。',
                        style: Theme.of(sheetContext).textTheme.bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                    Flexible(
                      child: folders.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(32),
                              child: Center(
                                child: Text(
                                  '未扫描到任何音频文件夹',
                                  style: Theme.of(sheetContext)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: folders.length,
                              separatorBuilder: (_, _) => Divider(
                                height: 1,
                                indent: 56,
                                color: colorScheme.outlineVariant.withValues(
                                  alpha: .3,
                                ),
                              ),
                              itemBuilder: (context, index) {
                                final entry = folders[index];
                                final folder = entry.folder;
                                final excluded = widget.localMusic
                                    .isFolderExcluded(folder);
                                return CheckboxListTile(
                                  value: !excluded,
                                  onChanged: (checked) =>
                                      widget.localMusic.setFolderExcluded(
                                        folder,
                                        checked != true,
                                      ),
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  secondary: Icon(
                                    excluded
                                        ? Icons.folder_off_rounded
                                        : Icons.folder_rounded,
                                    color: excluded
                                        ? colorScheme.outline
                                        : colorScheme.primary.withValues(
                                            alpha: .8,
                                          ),
                                  ),
                                  title: Text(
                                    _folderDisplayName(folder),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: excluded
                                          ? colorScheme.onSurfaceVariant
                                          : colorScheme.onSurface,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '$folder · ${entry.count} 首',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(sheetContext)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                );
                              },
                            ),
                    ),
                    if (excludedCount > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
                        child: Text(
                          '已排除 $excludedCount 个文件夹',
                          style: Theme.of(sheetContext).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.primary),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('本地音乐'),
        actions: [
          AnimatedBuilder(
            animation: widget.localMusic,
            builder: (context, _) {
              if (widget.localMusic.isScanning) {
                final progress = widget.localMusic.scanProgress;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: progress.total > 0
                            ? progress.done / progress.total
                            : null,
                      ),
                    ),
                  ),
                );
              }
              if (_isDesktop) {
                return Row(
                  children: [
                    IconButton(
                      tooltip: '音乐目录',
                      onPressed: _showDesktopRootsDialog,
                      icon: const Icon(Icons.folder_open_rounded),
                    ),
                    IconButton(
                      tooltip: '扫描目录设置',
                      onPressed:
                          widget.localMusic.songs.isEmpty ? null : _showFolderFilterSheet,
                      icon: const Icon(Icons.rule_folder_rounded),
                    ),
                    IconButton(
                      tooltip: '重新扫描',
                      onPressed:
                          widget.localMusic.desktopRoots.isEmpty
                              ? null
                              : () async {
                                  await widget.localMusic.scanLocalMusic();
                                  Toast.success('扫描完成');
                                },
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                );
              }
              if (defaultTargetPlatform != TargetPlatform.android ||
                  !widget.localMusic.hasPermission) {
                return const SizedBox.shrink();
              }
              return Row(
                children: [
                  IconButton(
                    tooltip: '扫描目录设置',
                    onPressed: _showFolderFilterSheet,
                    icon: const Icon(Icons.rule_folder_rounded),
                  ),
                  IconButton(
                    tooltip: '重新扫描',
                    onPressed: () async {
                      await widget.localMusic.scanLocalMusic();
                      Toast.success('扫描完成');
                    },
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: AdaptiveContentPadding(
        // 悬浮迷你播放条：桌面形态由 MiniPlayerSlot 内部收敛为 shrink，
        // 移动端有播放时浮在列表底部（歌单/历史页同款挂法）。
        child: Stack(
          children: [
            AnimatedBuilder(
              animation: Listenable.merge([widget.localMusic, widget.player]),
              builder: (context, _) {
            // 桌面（Windows/Linux）：无目录时引导添加；有目录走通用列表。
            if (_isDesktop) {
              if (widget.localMusic.desktopRoots.isEmpty) {
                return _buildEmptyState(
                  context,
                  colorScheme,
                  icon: Icons.library_music_rounded,
                  title: '添加本地音乐目录',
                  subtitle: '选择存放音乐文件的文件夹，会递归扫描其中的音频并读取标签信息',
                  action: FilledButton.icon(
                    onPressed: _pickAndAddDesktopRoot,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('添加音乐目录'),
                  ),
                );
              }
            } else if (defaultTargetPlatform != TargetPlatform.android) {
              // macOS：Rust 引擎未接入（见 form_factor.dart 的 macOS 适配清单）。
              return _buildEmptyState(
                context,
                colorScheme,
                icon: Icons.phone_android_rounded,
                title: '暂不支持当前平台',
                subtitle: '本地音乐功能支持 Android / Windows / Linux',
              );
            }

            // Android 未授权状态（桌面跳过）
            if (!_isDesktop && !widget.localMusic.hasPermission) {
              return _buildEmptyState(
                context,
                colorScheme,
                icon: Icons.lock_outline_rounded,
                title: '需要音频访问权限',
                subtitle: '授予音频访问权限后，即可扫描并播放设备上的本地音乐',
                action: FilledButton.icon(
                  onPressed: _requestPermission,
                  icon: const Icon(Icons.security_rounded),
                  label: const Text('授予权限'),
                ),
              );
            }

            final allSongs = widget.localMusic.songs;
            final filteredSongs = allSongs.where((song) {
              final titleMatch = song.title.toLowerCase().contains(
                _searchQuery,
              );
              final artistMatch = song.artist.toLowerCase().contains(
                _searchQuery,
              );
              return titleMatch || artistMatch;
            }).toList();

            _maybeLocateCurrentSong(filteredSongs);

            return Column(
              children: [
                // 搜索栏：与首页/搜索页/歌单内搜索同款胶囊（36 高整圆角）。
                // 歌曲总数常驻搜索框尾部（统计 allSongs，不随搜索匹配数变化）。
                if (allSongs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: AppSearchField(
                      controller: _searchController,
                      hintText: '检索本地音乐...',
                      onSubmitted: (_) =>
                          FocusScope.of(context).unfocus(),
                      trailing: Text(
                        '共${allSongs.length}首',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                // 歌曲列表
                Expanded(
                  child: widget.localMusic.isScanning
                      ? const Center(child: CircularProgressIndicator())
                      : filteredSongs.isEmpty
                      ? _buildEmptyState(
                          context,
                          colorScheme,
                          icon: Icons.library_music_rounded,
                          title: allSongs.isEmpty ? '未找到本地音乐' : '没有检索到匹配的歌曲',
                          subtitle: allSongs.isEmpty
                              ? (_isDesktop ? '所选目录中没有音频文件，可添加或更换目录' : '设备上没有可播放的音频文件')
                              : '尝试其他关键词搜索',
                          action: allSongs.isEmpty && _isDesktop
                              ? TextButton.icon(
                                  onPressed: _showDesktopRootsDialog,
                                  icon: const Icon(Icons.folder_open_rounded),
                                  label: const Text('管理音乐目录'),
                                )
                              : null,
                        )
                      : ListView.separated(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 120),
                          itemCount: filteredSongs.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 2),
                          itemBuilder: (context, index) {
                            final song = filteredSongs[index];
                            final current = widget.player.currentSong;
                            final isCurrent =
                                current != null && _isSameSong(song, current);
                            // 行视觉与歌单/搜索/歌手页统一见 AppSongRow。
                            // 本页歌全部来自本机文件，不显示「已下载」角标。
                            // 当前播放行挂 GlobalKey 供 ensureVisible 精确校正，
                            // 其余行用稳定身份 key，切歌/过滤时复用不错位。
                            return AppSongRow(
                              key: isCurrent
                                  ? _currentSongRowKey
                                  : ValueKey(
                                      'local-song-${_songIdentity(song)}',
                                    ),
                              song: song,
                              player: widget.player,
                              showDownloadedBadge: false,
                              onTap: () {
                                if (openPlayerIfSameSong(
                                  context,
                                  player: widget.player,
                                  auth: widget.auth,
                                  song: song,
                                )) {
                                  return;
                                }
                                widget.player.playSong(
                                  song,
                                  queue: filteredSongs,
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 10,
              child: MiniPlayerSlot(
                player: widget.player,
                auth: widget.auth,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    ColorScheme colorScheme, {
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 72,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action],
          ],
        ),
      ),
    );
  }
}

/// 取文件夹显示名：优先末级目录名，顶层存储目录（末级为 `0`）显示完整路径。
String _folderDisplayName(String folder) {
  final separator = folder.contains('\\') ? '\\' : '/';
  final segments = folder.split(separator).where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return folder;
  final last = segments.last;
  if (last == '0' || last == 'storage') return folder;
  return last;
}
