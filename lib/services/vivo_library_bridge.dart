import '../models/music_models.dart';

class VivoLibraryBridge {
  VivoLibraryBridge({
    required this.currentQueue,
    required this.favoriteSongs,
    required this.localSongs,
    required this.downloadedSongs,
    required this.playSong,
  });

  static const currentListParent = 'vivomusicmix_current_list';
  static const favoriteListParent = 'vivomusicmix_favorite_list';
  static const localListParent = 'vivomusicmix_local_list';

  final List<Song> Function() currentQueue;
  final List<Song> Function() favoriteSongs;
  final List<Song> Function() localSongs;
  final List<Song> Function() downloadedSongs;
  final Future<void> Function(Song song, List<Song> queue) playSong;
  final Map<String, String> _parentByMediaId = {};

  static String mediaIdFor(Song song) =>
      song.hash.isEmpty ? song.id : song.hash;

  List<Song> songsFor(String parentMediaId) {
    final songs = List<Song>.of(_songsForSource(parentMediaId));
    for (final song in songs) {
      _parentByMediaId[mediaIdFor(song)] = parentMediaId;
    }
    return songs;
  }

  List<Song> _songsForSource(String parentMediaId) => switch (parentMediaId) {
    currentListParent => currentQueue(),
    favoriteListParent => favoriteSongs(),
    localListParent => localAndDownloaded,
    _ => const <Song>[],
  };

  List<Song> get localAndDownloaded =>
      deduplicateByTitle([...localSongs(), ...downloadedSongs()]);

  ({Song song, List<Song> queue})? resolve(String mediaId) {
    final browsedParent = _parentByMediaId[mediaId];
    final sources = <List<Song>>[
      if (browsedParent != null) _songsForSource(browsedParent),
      currentQueue(),
      favoriteSongs(),
      localAndDownloaded,
    ];
    for (final songs in sources) {
      for (final song in songs) {
        if (mediaIdFor(song) == mediaId) {
          return (song: song, queue: List<Song>.of(songs));
        }
      }
    }
    return null;
  }

  static List<Song> deduplicateByTitle(Iterable<Song> songs) {
    final seenTitles = <String>{};
    final result = <Song>[];
    for (final song in songs) {
      final title = song.title.trim().toLowerCase();
      if (seenTitles.add(title)) result.add(song);
    }
    return result;
  }
}
