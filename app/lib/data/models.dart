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

class MessageSkin {
  MessageSkin({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.imagePath,
    required this.fit,
    required this.sliceLeft,
    required this.sliceTop,
    required this.sliceRight,
    required this.sliceBottom,
    required this.textColor,
  });

  final String id;
  final String ownerId;
  final String name;
  final String imagePath;
  final SkinFit fit;
  final int sliceLeft, sliceTop, sliceRight, sliceBottom;
  final String textColor; // #RRGGBB

  factory MessageSkin.fromRow(Map<String, dynamic> r) => MessageSkin(
    id: r['id'] as String,
    ownerId: r['owner_id'] as String,
    name: r['name'] as String,
    imagePath: r['image_path'] as String,
    fit: skinFitFromDb(r['fit'] as String),
    sliceLeft: r['slice_left'] as int,
    sliceTop: r['slice_top'] as int,
    sliceRight: r['slice_right'] as int,
    sliceBottom: r['slice_bottom'] as int,
    textColor: r['text_color'] as String,
  );
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
