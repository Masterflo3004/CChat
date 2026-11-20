import 'package:supabase_flutter/supabase_flutter.dart';

class GifResult {
  GifResult({
    required this.id,
    required this.url,
    required this.previewUrl,
    required this.width,
    required this.height,
    this.title,
  });

  final String id;
  final String url;
  final String previewUrl;
  final int width;
  final int height;
  final String? title;

  factory GifResult.fromJson(Map<String, dynamic> j) => GifResult(
    id: j['id'] as String,
    url: j['url'] as String,
    previewUrl: j['preview'] as String,
    width: (j['w'] as num).toInt(),
    height: (j['h'] as num).toInt(),
    title: j['title'] as String?,
  );
}

/// GIF search through the `gif-search` Edge Function, which holds the provider
/// API key and keeps search terms away from the provider's tracking.
class GifService {
  GifService(this.client);
  final SupabaseClient client;

  Future<List<GifResult>> search(String query, {int offset = 0}) async {
    final res = await client.functions.invoke('gif-search', body: {'q': query.trim(), 'offset': offset});
    final data = Map<String, dynamic>.from(res.data as Map);
    return [
      for (final r in (data['results'] as List? ?? const [])) GifResult.fromJson(Map<String, dynamic>.from(r as Map)),
    ];
  }
}
