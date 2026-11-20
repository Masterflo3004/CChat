import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';
import 'media_service.dart';
import 'session.dart';

/// GIF library, community gallery (skins, fonts, GIFs), personal library and reports.
class CommunityService {
  CommunityService(this.client, this.session, this.media);

  final SupabaseClient client;
  final AppSession session;
  final MediaService media;

  String get _uid => session.userId!;

  // ---------------------------------------------------------------------------
  // GIF library
  // ---------------------------------------------------------------------------

  /// Uploads a GIF to the library (hash-checked on the server).
  Future<GifItem> uploadGif({
    required Uint8List bytes,
    required String filename,
    String? title,
    bool isPublic = true,
    int? width,
    int? height,
  }) async {
    final asset = await media.upload(kind: 'gif', bytes: bytes, filename: filename, width: width, height: height);
    final existing = await client.from('gifs').select('id').eq('asset_id', asset.id).maybeSingle();
    final String id;
    if (existing != null) {
      id = existing['id'] as String; // same file uploaded again: reuse the library entry
    } else {
      final row = await client
          .from('gifs')
          .insert({
            'owner_id': _uid,
            'asset_id': asset.id,
            'title': (title == null || title.trim().isEmpty) ? null : title.trim(),
            'is_public': isPublic,
          })
          .select('id')
          .single();
      id = row['id'] as String;
    }
    return GifItem(
      id: id,
      ownerId: _uid,
      ownerUsername: session.me?.username ?? '',
      title: title,
      isPublic: isPublic,
      assetId: asset.id,
      path: asset.path,
      width: asset.width ?? width ?? 0,
      height: asset.height ?? height ?? 0,
    );
  }

  Future<List<GifItem>> gifs({bool mine = false, String? query, int offset = 0}) async {
    final rows = await client.rpc(
      'gallery_gifs',
      params: {'p_query': query, 'p_mine': mine, 'p_limit': 40, 'p_offset': offset},
    ) as List;
    return [for (final r in rows) GifItem.fromRow(Map<String, dynamic>.from(r as Map))];
  }

  Future<void> setGifPublic(String gifId, bool isPublic) =>
      client.from('gifs').update({'is_public': isPublic}).eq('id', gifId);

  Future<void> deleteGif(GifItem gif) async {
    await client.from('gifs').delete().eq('id', gif.id);
    // The file may still be referenced by sent messages, so it stays in storage.
  }

  // ---------------------------------------------------------------------------
  // Gallery: skins & fonts
  // ---------------------------------------------------------------------------

  Future<List<GalleryEntry<MessageSkin>>> gallerySkins({int offset = 0}) async {
    final rows = await client.rpc('gallery_skins', params: {'p_limit': 30, 'p_offset': offset}) as List;
    return [
      for (final r in rows)
        GalleryEntry(
          MessageSkin.fromRow(Map<String, dynamic>.from((r as Map)['skin'] as Map)),
          r['owner_username'] as String,
        ),
    ];
  }

  Future<List<GalleryEntry<UserFont>>> galleryFonts({int offset = 0}) async {
    final rows = await client.rpc('gallery_fonts', params: {'p_limit': 30, 'p_offset': offset}) as List;
    return [
      for (final r in rows)
        GalleryEntry(
          UserFont.fromRow(Map<String, dynamic>.from((r as Map)['font'] as Map)),
          r['owner_username'] as String,
        ),
    ];
  }

  Future<void> setSkinPublic(String skinId, bool isPublic) =>
      client.from('message_skins').update({'is_public': isPublic}).eq('id', skinId);

  Future<void> setFontPublic(String fontId, bool isPublic) =>
      client.from('user_fonts').update({'is_public': isPublic}).eq('id', fontId);

  // ---------------------------------------------------------------------------
  // Personal library (items saved from the gallery)
  // ---------------------------------------------------------------------------

  Future<void> save(String kind, String itemId) =>
      client.from('library_items').upsert({'user_id': _uid, 'kind': kind, 'item_id': itemId});

  Future<void> unsave(String kind, String itemId) =>
      client.from('library_items').delete().eq('user_id', _uid).eq('kind', kind).eq('item_id', itemId);

  Future<Set<String>> savedIds(String kind) async {
    final rows = await client.from('library_items').select('item_id').eq('user_id', _uid).eq('kind', kind);
    return {for (final r in rows) r['item_id'] as String};
  }

  Future<List<MessageSkin>> savedSkins() async {
    final ids = await savedIds('skin');
    if (ids.isEmpty) return [];
    final rows = await client.from('message_skins').select().inFilter('id', ids.toList());
    return [for (final r in rows) MessageSkin.fromRow(r)];
  }

  Future<List<UserFont>> savedFonts() async {
    final ids = await savedIds('font');
    if (ids.isEmpty) return [];
    final rows = await client.from('user_fonts').select().inFilter('id', ids.toList());
    return [for (final r in rows) UserFont.fromRow(r)];
  }

  // ---------------------------------------------------------------------------
  // Reports
  // ---------------------------------------------------------------------------

  Future<void> report(ReportTarget type, String targetId, String reason) async {
    try {
      await client.from('reports').insert({
        'reporter_id': _uid,
        'target_type': type.name,
        'target_id': targetId,
        'reason': reason,
      });
    } on PostgrestException catch (e) {
      if (e.code == '23505') return; // already reported and still open
      rethrow;
    }
  }

  /// Reports an end-to-end encrypted attachment by sharing a decrypted copy with
  /// the moderators (only after the user agreed to this).
  Future<void> reportAttachment(Uint8List decrypted, String filename, String reason) async {
    final asset = await media.upload(kind: 'evidence', bytes: decrypted, filename: filename);
    await client.from('reports').insert({
      'reporter_id': _uid,
      'target_type': 'attachment',
      'evidence_asset_id': asset.id,
      'reason': reason,
    });
  }
}
