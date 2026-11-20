import 'dart:convert';

class Profile {
  Profile({
    required this.id,
    required this.username,
    this.displayName,
    this.xPublicKey,
    this.edPublicKey,
    this.activeSkinId,
    this.activeFontId,
  });

  final String id;
  final String username;
  final String? displayName;
  final String? xPublicKey;
  final String? edPublicKey;
  final String? activeSkinId;
  final String? activeFontId;

  String get label => (displayName?.isNotEmpty ?? false) ? displayName! : username;
  bool get hasKeys => xPublicKey != null && edPublicKey != null;

  factory Profile.fromRow(Map<String, dynamic> r) => Profile(
    id: r['id'] as String,
    username: r['username'] as String,
    displayName: r['display_name'] as String?,
    xPublicKey: r['x25519_public_key'] as String?,
    edPublicKey: r['ed25519_public_key'] as String?,
    activeSkinId: r['active_skin_id'] as String?,
    activeFontId: r['active_font_id'] as String?,
  );
}

class Member {
  Member({required this.id, required this.username, this.displayName, required this.role});
  final String id;
  final String username;
  final String? displayName;
  final String role;

  String get label => (displayName?.isNotEmpty ?? false) ? displayName! : username;
  bool get isAdmin => role == 'admin';

  factory Member.fromJson(Map<String, dynamic> j) => Member(
    id: j['id'] as String,
    username: j['username'] as String,
    displayName: j['display_name'] as String?,
    role: j['role'] as String,
  );
}

class Conversation {
  Conversation({
    required this.id,
    required this.isGroup,
    this.name,
    required this.currentEpoch,
    required this.rotationNeeded,
    this.lastMessageAt,
    required this.createdAt,
    required this.myRole,
    required this.unreadCount,
    required this.members,
  });

  final String id;
  final bool isGroup;
  final String? name;
  final int currentEpoch;
  final bool rotationNeeded;
  final DateTime? lastMessageAt;
  final DateTime createdAt;
  final String myRole;
  final int unreadCount;
  final List<Member> members;

  bool get iAmAdmin => myRole == 'admin';

  String title(String myId) {
    if (isGroup) return name ?? 'Group';
    final other = members.where((m) => m.id != myId);
    return other.isEmpty ? 'Just you' : other.first.label;
  }

  factory Conversation.fromRow(Map<String, dynamic> r) => Conversation(
    id: r['id'] as String,
    isGroup: r['is_group'] as bool,
    name: r['name'] as String?,
    currentEpoch: r['current_epoch'] as int,
    rotationNeeded: r['rotation_needed'] as bool,
    lastMessageAt: r['last_message_at'] == null ? null : DateTime.parse(r['last_message_at'] as String).toLocal(),
    createdAt: DateTime.parse(r['created_at'] as String).toLocal(),
    myRole: r['my_role'] as String,
    unreadCount: (r['unread_count'] as num).toInt(),
    members: [
      for (final m in (r['members'] as List? ?? const [])) Member.fromJson(Map<String, dynamic>.from(m as Map)),
    ],
  );
}

/// Row from the `messages` table (still encrypted).
class RawMessage {
  RawMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.keyEpoch,
    required this.nonce,
    required this.ciphertext,
    required this.signature,
    required this.createdAt,
  });

  final int id;
  final String conversationId;
  final String senderId;
  final int keyEpoch;
  final String nonce;
  final String ciphertext;
  final String signature;
  final DateTime createdAt;

  factory RawMessage.fromRow(Map<String, dynamic> r) => RawMessage(
    id: (r['id'] as num).toInt(),
    conversationId: r['conversation_id'] as String,
    senderId: r['sender_id'] as String,
    keyEpoch: r['key_epoch'] as int,
    nonce: r['nonce'] as String,
    ciphertext: r['ciphertext'] as String,
    signature: r['signature'] as String,
    createdAt: DateTime.parse(r['created_at'] as String).toLocal(),
  );
}

/// Per-message look: which skin (bubble texture) and font the sender chose.
class MessageStyle {
  const MessageStyle({this.skinId, this.fontId});
  final String? skinId;
  final String? fontId;

  Map<String, dynamic> toJson() => {if (skinId != null) 'skin': skinId, if (fontId != null) 'font': fontId};

  factory MessageStyle.fromJson(Map<String, dynamic>? j) =>
      MessageStyle(skinId: j?['skin'] as String?, fontId: j?['font'] as String?);
}

/// A GIF either from the GIF search (remote URL) or uploaded and encrypted by the sender.
class GifContent {
  GifContent.remote({required this.url, required this.width, required this.height, this.title})
    : path = null,
      fileKey = null;

  GifContent.file({required String this.path, required String this.fileKey, required this.width, required this.height})
    : url = null,
      title = null;

  final String? url;
  final String? title;
  final String? path;
  final String? fileKey;
  final int width;
  final int height;

  bool get isFile => path != null;

  Map<String, dynamic> toJson() => isFile
      ? {'src': 'file', 'path': path, 'key': fileKey, 'w': width, 'h': height}
      : {'src': 'remote', 'url': url, 'title': title, 'w': width, 'h': height};

  factory GifContent.fromJson(Map<String, dynamic> j) => j['src'] == 'file'
      ? GifContent.file(
          path: j['path'] as String,
          fileKey: j['key'] as String,
          width: (j['w'] as num).toInt(),
          height: (j['h'] as num).toInt(),
        )
      : GifContent.remote(
          url: j['url'] as String,
          title: j['title'] as String?,
          width: (j['w'] as num).toInt(),
          height: (j['h'] as num).toInt(),
        );
}

enum PayloadType { text, gif }

/// The plaintext that gets encrypted into a message.
class MessagePayload {
  MessagePayload.text(String this.text, {this.style = const MessageStyle()}) : type = PayloadType.text, gif = null;

  MessagePayload.gif(GifContent this.gif, {this.style = const MessageStyle()}) : type = PayloadType.gif, text = null;

  final PayloadType type;
  final String? text;
  final GifContent? gif;
  final MessageStyle style;

  List<int> encode() => utf8.encode(
    jsonEncode({
      'v': 1,
      't': type.name,
      if (text != null) 'text': text,
      if (gif != null) 'gif': gif!.toJson(),
      'style': style.toJson(),
    }),
  );

  factory MessagePayload.decode(List<int> bytes) {
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final style = MessageStyle.fromJson(j['style'] == null ? null : Map<String, dynamic>.from(j['style'] as Map));
    switch (j['t']) {
      case 'gif':
        return MessagePayload.gif(GifContent.fromJson(Map<String, dynamic>.from(j['gif'] as Map)), style: style);
      case 'text':
      default:
        return MessagePayload.text((j['text'] as String?) ?? '', style: style);
    }
  }
}

/// A message after decryption. [error] is set when it could not be decrypted/verified.
class ChatMessage {
  ChatMessage({required this.raw, this.payload, this.error});
  final RawMessage raw;
  final MessagePayload? payload;
  final String? error;
}

/// How a background image fills the bubble.
enum SkinFit { cover, tile, stretch, nineSlice }

SkinFit skinFitFromDb(String s) => switch (s) {
  'tile' => SkinFit.tile,
  'stretch' => SkinFit.stretch,
  'nine_slice' => SkinFit.nineSlice,
  _ => SkinFit.cover,
};

String skinFitToDb(SkinFit f) => switch (f) {
  SkinFit.cover => 'cover',
  SkinFit.tile => 'tile',
  SkinFit.stretch => 'stretch',
  SkinFit.nineSlice => 'nine_slice',
};

/// What fills the message bubble.
enum SkinBackground { theme, color, gradient, image }

/// What is drawn around the message bubble.
enum SkinBorder { none, solid, image }

/// A message skin: background + border + shape + text colour.
class MessageSkin {
  MessageSkin({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.textColor,
    this.background = SkinBackground.color,
    this.bgColor,
    this.bgColor2,
    this.bgImagePath,
    this.bgFit = SkinFit.cover,
    this.sliceLeft = 0,
    this.sliceTop = 0,
    this.sliceRight = 0,
    this.sliceBottom = 0,
    this.border = SkinBorder.none,
    this.borderColor,
    this.borderWidth = 0,
    this.borderRadius = 18,
    this.borderImagePath,
    this.borderSlice = 0,
  });

  final String id;
  final String ownerId;
  final String name;
  final String textColor; // #RRGGBB

  // Background
  final SkinBackground background;
  final String? bgColor; // #RRGGBB (color, gradient start)
  final String? bgColor2; // #RRGGBB (gradient end)
  final String? bgImagePath;
  final SkinFit bgFit;
  final int sliceLeft, sliceTop, sliceRight, sliceBottom; // background 9-slice insets (image px)

  // Border
  final SkinBorder border;
  final String? borderColor;
  final int borderWidth; // line width, or frame thickness on screen
  final int borderRadius; // bubble corner radius
  final String? borderImagePath;
  final int borderSlice; // frame corner/edge size in the border image (image px)

  factory MessageSkin.fromRow(Map<String, dynamic> r) => MessageSkin(
    id: r['id'] as String,
    ownerId: r['owner_id'] as String,
    name: r['name'] as String,
    textColor: r['text_color'] as String,
    background: SkinBackground.values.byName(r['bg_type'] as String),
    bgColor: r['bg_color'] as String?,
    bgColor2: r['bg_color2'] as String?,
    bgImagePath: r['bg_image_path'] as String?,
    bgFit: skinFitFromDb(r['bg_fit'] as String),
    sliceLeft: r['slice_left'] as int,
    sliceTop: r['slice_top'] as int,
    sliceRight: r['slice_right'] as int,
    sliceBottom: r['slice_bottom'] as int,
    border: SkinBorder.values.byName(r['border_type'] as String),
    borderColor: r['border_color'] as String?,
    borderWidth: r['border_width'] as int,
    borderRadius: r['border_radius'] as int,
    borderImagePath: r['border_image_path'] as String?,
    borderSlice: r['border_slice'] as int,
  );

  /// Columns for an insert (image paths are filled in after upload).
  Map<String, dynamic> toRow() => {
    'owner_id': ownerId,
    'name': name,
    'text_color': textColor,
    'bg_type': background.name,
    'bg_color': background == SkinBackground.color || background == SkinBackground.gradient ? bgColor : null,
    'bg_color2': background == SkinBackground.gradient ? bgColor2 : null,
    'bg_image_path': background == SkinBackground.image ? bgImagePath : null,
    'bg_fit': skinFitToDb(bgFit),
    'slice_left': sliceLeft,
    'slice_top': sliceTop,
    'slice_right': sliceRight,
    'slice_bottom': sliceBottom,
    'border_type': border.name,
    'border_color': border == SkinBorder.solid ? borderColor : null,
    'border_width': border == SkinBorder.none ? 0 : borderWidth,
    'border_radius': borderRadius,
    'border_image_path': border == SkinBorder.image ? borderImagePath : null,
    'border_slice': border == SkinBorder.image ? borderSlice : 0,
  };

  MessageSkin copyWith({String? id, String? ownerId, String? bgImagePath, String? borderImagePath}) => MessageSkin(
    id: id ?? this.id,
    ownerId: ownerId ?? this.ownerId,
    name: name,
    textColor: textColor,
    background: background,
    bgColor: bgColor,
    bgColor2: bgColor2,
    bgImagePath: bgImagePath ?? this.bgImagePath,
    bgFit: bgFit,
    sliceLeft: sliceLeft,
    sliceTop: sliceTop,
    sliceRight: sliceRight,
    sliceBottom: sliceBottom,
    border: border,
    borderColor: borderColor,
    borderWidth: borderWidth,
    borderRadius: borderRadius,
    borderImagePath: borderImagePath ?? this.borderImagePath,
    borderSlice: borderSlice,
  );

  /// Short human description, e.g. "Gradient · image frame".
  String get summary {
    final bg = switch (background) {
      SkinBackground.theme => 'Theme colour',
      SkinBackground.color => 'Colour $bgColor',
      SkinBackground.gradient => 'Gradient',
      SkinBackground.image => 'Image (${bgFit.name})',
    };
    final b = switch (border) {
      SkinBorder.none => 'no border',
      SkinBorder.solid => '${borderWidth}px border',
      SkinBorder.image => 'image frame',
    };
    return '$bg · $b';
  }
}

class UserFont {
  UserFont({required this.id, required this.ownerId, required this.name, required this.filePath});
  final String id;
  final String ownerId;
  final String name;
  final String filePath;

  /// Family name the font is registered under via FontLoader.
  String get family => 'cchat_font_$id';

  factory UserFont.fromRow(Map<String, dynamic> r) => UserFont(
    id: r['id'] as String,
    ownerId: r['owner_id'] as String,
    name: r['name'] as String,
    filePath: r['file_path'] as String,
  );
}
