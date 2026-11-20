import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../data/models.dart';
import 'session.dart';

Color parseHexColor(String hex) => Color(int.parse('FF${hex.substring(1)}', radix: 16));

String toHexColor(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// A decoded skin image (background or border frame).
class SkinImage {
  SkinImage({required this.bytes, required this.image});
  final Uint8List bytes;
  final ui.Image image;
  late final ImageProvider provider = MemoryImage(bytes);
  int get width => image.width;
  int get height => image.height;

  static Future<SkinImage> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame(); // first frame is enough for skins
    codec.dispose();
    return SkinImage(bytes: bytes, image: frame.image);
  }
}

/// A skin with its images decoded, ready to paint a message bubble.
class LoadedSkin {
  LoadedSkin({required this.skin, this.background, this.border});
  final MessageSkin skin;
  final SkinImage? background;
  final SkinImage? border;

  Color get textColor => parseHexColor(skin.textColor);

  /// Space the border takes up on each side (content is inset by this).
  double get borderInset => skin.border == SkinBorder.none ? 0 : skin.borderWidth.toDouble();

  BorderRadius get radius => BorderRadius.circular(skin.borderRadius.toDouble());

  /// Background + solid border. [themeColor] is used for the "theme" background.
  BoxDecoration decoration(Color themeColor) {
    final s = skin;
    Color? color;
    Gradient? gradient;
    DecorationImage? image;
    switch (s.background) {
      case SkinBackground.theme:
        color = themeColor;
      case SkinBackground.color:
        color = parseHexColor(s.bgColor ?? '#000000');
      case SkinBackground.gradient:
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [parseHexColor(s.bgColor ?? '#000000'), parseHexColor(s.bgColor2 ?? '#000000')],
        );
      case SkinBackground.image:
        image = background == null ? null : _backgroundImage(background!);
        if (image == null) color = themeColor;
    }
    return BoxDecoration(
      color: color,
      gradient: gradient,
      image: image,
      borderRadius: radius,
      border: s.border == SkinBorder.solid
          ? Border.all(color: parseHexColor(s.borderColor ?? '#000000'), width: s.borderWidth.toDouble())
          : null,
    );
  }

  DecorationImage _backgroundImage(SkinImage img) {
    final s = skin;
    switch (s.bgFit) {
      case SkinFit.tile:
        return DecorationImage(image: img.provider, repeat: ImageRepeat.repeat, fit: BoxFit.none);
      case SkinFit.stretch:
        return DecorationImage(image: img.provider, fit: BoxFit.fill);
      case SkinFit.nineSlice:
        final w = img.width, h = img.height;
        final l = s.sliceLeft.clamp(0, w - 1).toDouble();
        final t = s.sliceTop.clamp(0, h - 1).toDouble();
        final r = (w - s.sliceRight).clamp(l + 1, w.toDouble()).toDouble();
        final b = (h - s.sliceBottom).clamp(t + 1, h.toDouble()).toDouble();
        return DecorationImage(image: img.provider, centerSlice: Rect.fromLTRB(l, t, r, b), fit: BoxFit.fill);
      case SkinFit.cover:
        return DecorationImage(image: img.provider, fit: BoxFit.cover);
    }
  }

  /// Painter for an image-frame border, or null.
  CustomPainter? framePainter() =>
      skin.border == SkinBorder.image && border != null && skin.borderSlice > 0 && skin.borderWidth > 0
      ? BorderFramePainter(border!.image, slice: skin.borderSlice, thickness: skin.borderWidth.toDouble())
      : null;
}

/// Draws a 9-slice frame image around the whole bubble. The frame's corners keep
/// their shape, edges stretch, and the centre of the image is not drawn, so the
/// background and text stay visible.
class BorderFramePainter extends CustomPainter {
  BorderFramePainter(this.image, {required this.slice, required this.thickness});
  final ui.Image image;
  final int slice; // corner/edge size in image pixels
  final double thickness; // corner/edge size on screen

  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width.toDouble(), h = image.height.toDouble();
    final s = slice.toDouble().clamp(1.0, (w < h ? w : h) / 2 - 0.5);
    final k = thickness / s; // image px -> screen px
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final dw = size.width / k, dh = size.height / k; // destination size in image px
    if (dw < 2 * s || dh < 2 * s) return;

    canvas.save();
    canvas.scale(k);
    // source rects (corners, edges) -> destination rects; centre skipped.
    void part(Rect src, Rect dst) => canvas.drawImageRect(image, src, dst, paint);
    // corners
    part(Rect.fromLTWH(0, 0, s, s), Rect.fromLTWH(0, 0, s, s));
    part(Rect.fromLTWH(w - s, 0, s, s), Rect.fromLTWH(dw - s, 0, s, s));
    part(Rect.fromLTWH(0, h - s, s, s), Rect.fromLTWH(0, dh - s, s, s));
    part(Rect.fromLTWH(w - s, h - s, s, s), Rect.fromLTWH(dw - s, dh - s, s, s));
    // edges (stretched)
    part(Rect.fromLTWH(s, 0, w - 2 * s, s), Rect.fromLTWH(s, 0, dw - 2 * s, s));
    part(Rect.fromLTWH(s, h - s, w - 2 * s, s), Rect.fromLTWH(s, dh - s, dw - 2 * s, s));
    part(Rect.fromLTWH(0, s, s, h - 2 * s), Rect.fromLTWH(0, s, s, dh - 2 * s));
    part(Rect.fromLTWH(w - s, s, s, h - 2 * s), Rect.fromLTWH(dw - s, s, s, dh - 2 * s));
    canvas.restore();
  }

  @override
  bool shouldRepaint(BorderFramePainter old) => old.image != image || old.slice != slice || old.thickness != thickness;
}

/// A new skin plus the image files to upload with it.
class SkinUpload {
  SkinUpload({required this.skin, this.backgroundBytes, this.backgroundExt, this.borderBytes, this.borderExt});
  final MessageSkin skin;
  final Uint8List? backgroundBytes;
  final String? backgroundExt;
  final Uint8List? borderBytes;
  final String? borderExt;
}

/// Message skins (background + border) and custom fonts.
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

  Future<String> _uploadImage(Uint8List bytes, String ext) async {
    if (bytes.length > maxSkinBytes) throw ArgumentError('Skin images must be at most 5 MB');
    final path = '$_uid/${_uuid.v4()}.${ext.toLowerCase()}';
    await client.storage
        .from('skins')
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: _imageMime(ext)));
    return path;
  }

  Future<MessageSkin> createSkin(SkinUpload upload) async {
    var skin = upload.skin.copyWith(ownerId: _uid);
    final uploaded = <String>[];
    try {
      if (skin.background == SkinBackground.image) {
        if (upload.backgroundBytes == null) throw ArgumentError('Choose a background image');
        final p = await _uploadImage(upload.backgroundBytes!, upload.backgroundExt ?? 'png');
        uploaded.add(p);
        skin = skin.copyWith(bgImagePath: p);
      }
      if (skin.border == SkinBorder.image) {
        if (upload.borderBytes == null) throw ArgumentError('Choose a border image');
        final p = await _uploadImage(upload.borderBytes!, upload.borderExt ?? 'png');
        uploaded.add(p);
        skin = skin.copyWith(borderImagePath: p);
      }
      final row = await client.from('message_skins').insert(skin.toRow()).select().single();
      return MessageSkin.fromRow(row);
    } catch (_) {
      if (uploaded.isNotEmpty) await client.storage.from('skins').remove(uploaded).catchError((_) => <FileObject>[]);
      rethrow;
    }
  }

  Future<void> deleteSkin(MessageSkin skin) async {
    await client.from('message_skins').delete().eq('id', skin.id);
    final paths = [?skin.bgImagePath, ?skin.borderImagePath];
    if (paths.isNotEmpty) await client.storage.from('skins').remove(paths);
    _skins.remove(skin.id);
  }

  Future<LoadedSkin?> loadSkin(String id) {
    return _skins[id] ??=
        () async {
          final row = await client.from('message_skins').select().eq('id', id).maybeSingle();
          if (row == null) return null; // deleted skin -> default look
          final skin = MessageSkin.fromRow(row);
          Future<SkinImage?> img(String? path) async =>
              path == null ? null : SkinImage.decode(await client.storage.from('skins').download(path));
          final images = await Future.wait([
            img(skin.background == SkinBackground.image ? skin.bgImagePath : null),
            img(skin.border == SkinBorder.image ? skin.borderImagePath : null),
          ]);
          return LoadedSkin(skin: skin, background: images[0], border: images[1]);
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
