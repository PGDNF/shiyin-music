import 'model_parsing.dart';

String? normalizeSongArtworkUri(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri != null && uri.scheme == 'content' && uri.host == 'media') {
    return raw;
  }
  return normalizeImageUrl(raw);
}
