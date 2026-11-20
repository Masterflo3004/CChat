import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../data/models.dart';
import 'session.dart';

/// A skin with its decoded image, ready to paint behind a message bubble.
class LoadedSkin {
  LoadedSkin({required this.skin, required this.image, required this.width, required this.height});
  final MessageSkin skin;
  final ImageProvider image;
  final int width;
  final int height;

  Color get textColor => Color(int.parse('FF${skin.textColor.substring(1)}', radix: 16));

  DecorationImage decoration() {
    switch (skin.fit) {
      case SkinFit.tile:
        return DecorationImage(image: image, repeat: ImageRepeat.repeat, fit: BoxFit.none);
      case SkinFit.stretch:
        return DecorationImage(image: image, fit: BoxFit.fill);
      case SkinFit.nineSlice:
        final l = skin.sliceLeft.clamp(0, width - 1).toDouble();
        final t = skin.sliceTop.clamp(0, height - 1).toDouble();
        final r = (width - skin.sliceRight).clamp(l + 1, width.toDouble()).toDouble();
        final b = (height - skin.sliceBottom).clamp(t + 1, height.toDouble()).toDouble();
        return DecorationImage(image: image, centerSlice: Rect.fromLTRB(l, t, r, b), fit: BoxFit.fill);
      case SkinFit.cover:
        return DecorationImage(image: image, fit: BoxFit.cover);
    }
  }
}

/// Message skins (bubble textures) and custom fonts.
class CosmeticsService {
  CosmeticsService(this.client, this.session);

  final SupabaseClient client;
  final AppSession session;
  static const _uuid = Uuid();

  static const maxSkinBytes = 5 * 1024 * 1024;
  static const maxFontBytes = 2 * 1024 * 1024;

  final _skins = <String, Future<LoadedSkin?>>{};
  final _fonts = <String, Future<String?>>{};

  String get _uid => session.userId!;

  // ---------------------------------------------------------------------------
  // Skins
  // ---------------------------------------------------------------------------

  Future<List<MessageSkin>> mySkins() async {
    final rows = await client.from('message_skins').select().eq('owner_id', _uid).order('created_at', ascending: true);
    return [for (final r in rows) MessageSkin.fromRow(r)];
  }

  static String _imageMime(String ext) => switch (ext.toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    _ => throw ArgumentError('Unsupported image type .$ext'),
  };

  Future<MessageSkin> createSkin({
    required String name,
    required Uint8List bytes,
    required String extension,
    required SkinFit fit,
    required String textColor,
    int sliceLeft = 0,
    int sliceTop = 0,
    int sliceRight = 0,
    int sliceBottom = 0,
  }) async {
    if (bytes.length > maxSkinBytes) throw ArgumentError('Skin image must be at most 5 MB');
    final path = '$_uid/${_uuid.v4()}.${extension.toLowerCase()}';
    await client.storage
        .from('skins')
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: _imageMime(extension)));
    final row = await client
        .from('message_skins')
        .insert({
          'owner_id': _uid,
          'name': name,
          'image_path': path,
          'fit': skinFitToDb(fit),
          'slice_left': sliceLeft,
          'slice_top': sliceTop,
          'slice_right': sliceRight,
          'slice_bottom': sliceBottom,
          'text_color': textColor,
        })
        .select()
        .single();
    return MessageSkin.fromRow(row);
  }

  Future<void> deleteSkin(MessageSkin skin) async {
    await client.from('message_skins').delete().eq('id', skin.id);
    await client.storage.from('skins').remove([skin.imagePath]);
    _skins.remove(skin.id);
  }

  Future<LoadedSkin?> loadSkin(String id) {
    return _skins[id] ??=
        () async {
          final row = await client.from('message_skins').select().eq('id', id).maybeSingle();
          if (row == null) return null; // deleted skin -> default look
          final skin = MessageSkin.fromRow(row);
          final bytes = await client.storage.from('skins').download(skin.imagePath);
          final size = await imageSize(bytes);
          return LoadedSkin(skin: skin, image: MemoryImage(bytes), width: size.$1, height: size.$2);
        }()..catchError((Object _) {
          _skins.remove(id);
          return null;
        });
  }

  static Future<(int, int)> imageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size = (frame.image.width, frame.image.height);
    frame.image.dispose();
    codec.dispose();
    return size;
  }

  // ---------------------------------------------------------------------------
  // Fonts
  // ---------------------------------------------------------------------------

  Future<List<UserFont>> myFonts() async {
    final rows = await client.from('user_fonts').select().eq('owner_id', _uid).order('created_at', ascending: true);
    return [for (final r in rows) UserFont.fromRow(r)];
  }

  Future<UserFont> uploadFont({required String name, required Uint8List bytes, required String extension}) async {
    final ext = extension.toLowerCase();
    if (ext != 'ttf' && ext != 'otf') throw ArgumentError('Fonts must be .ttf or .otf');
    if (bytes.length > maxFontBytes) throw ArgumentError('Font file must be at most 2 MB');
    final path = '$_uid/${_uuid.v4()}.$ext';
    await client.storage
        .from('fonts')
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: ext == 'otf' ? 'font/otf' : 'font/ttf'));
    final row = await client
        .from('user_fonts')
        .insert({'owner_id': _uid, 'name': name, 'file_path': path})
        .select()
        .single();
    final font = UserFont.fromRow(row);
    _fonts[font.id] = _register(font.family, bytes);
    return font;
  }

  Future<void> deleteFont(UserFont font) async {
    await client.from('user_fonts').delete().eq('id', font.id);
    await client.storage.from('fonts').remove([font.filePath]);
  }

  static Future<String?> _register(String family, Uint8List bytes) async {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    return family;
  }

  /// Downloads and registers the font, returning the family name to use in TextStyle.
  Future<String?> loadFont(String id) {
    return _fonts[id] ??=
        () async {
          final row = await client.from('user_fonts').select().eq('id', id).maybeSingle();
          if (row == null) return null;
          final font = UserFont.fromRow(row);
          final bytes = await client.storage.from('fonts').download(font.filePath);
          return _register(font.family, bytes);
        }()..catchError((Object _) {
          _fonts.remove(id);
          return null;
        });
  }

  // ---------------------------------------------------------------------------
  // Active selection (used for every message you send)
  // ---------------------------------------------------------------------------

  Future<void> setActive({required String? skinId, required String? fontId}) async {
    await client.from('profiles').update({'active_skin_id': skinId, 'active_font_id': fontId}).eq('id', _uid);
    await session.reloadProfile();
  }

  MessageStyle get activeStyle => MessageStyle(skinId: session.me?.activeSkinId, fontId: session.me?.activeFontId);
}
