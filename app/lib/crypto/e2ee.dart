// End-to-end encryption primitives for CChat.
//
// Pure Dart (package:cryptography) so it runs on Web, Android, Linux and Windows.
// See docs/E2EE.md for the protocol description.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Thrown when a backup passphrase is wrong (or the backup was tampered with).
class WrongPassphraseException implements Exception {
  @override
  String toString() => 'Wrong passphrase';
}

/// Thrown when a message or key fails authentication / signature verification.
class DecryptionException implements Exception {
  DecryptionException(this.message);
  final String message;
  @override
  String toString() => 'DecryptionException: $message';
}

String b64(List<int> bytes) => base64Encode(bytes);
Uint8List unb64(String s) => base64Decode(s);

Uint8List randomBytes(int length) {
  final rnd = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => rnd.nextInt(256)));
}

/// A user's long-term identity: X25519 for key agreement, Ed25519 for signatures.
class IdentityKeys {
  IdentityKeys._({
    required this.xSeed,
    required this.edSeed,
    required this.xKeyPair,
    required this.edKeyPair,
    required this.xPublicKey,
    required this.edPublicKey,
  });

  final Uint8List xSeed;
  final Uint8List edSeed;
  final SimpleKeyPair xKeyPair;
  final SimpleKeyPair edKeyPair;

  /// base64 public keys, as stored in `profiles`.
  final String xPublicKey;
  final String edPublicKey;

  static Future<IdentityKeys> fromSeeds(List<int> xSeed, List<int> edSeed) async {
    final x = await E2ee._x25519.newKeyPairFromSeed(xSeed);
    final ed = await E2ee._ed25519.newKeyPairFromSeed(edSeed);
    final xPub = await x.extractPublicKey();
    final edPub = await ed.extractPublicKey();
    return IdentityKeys._(
      xSeed: Uint8List.fromList(xSeed),
      edSeed: Uint8List.fromList(edSeed),
      xKeyPair: x,
      edKeyPair: ed,
      xPublicKey: b64(xPub.bytes),
      edPublicKey: b64(edPub.bytes),
    );
  }

  static Future<IdentityKeys> generate() => fromSeeds(randomBytes(32), randomBytes(32));

  String toJson() => jsonEncode({'v': 1, 'x': b64(xSeed), 'ed': b64(edSeed)});

  static Future<IdentityKeys> fromJson(String json) {
    final m = jsonDecode(json) as Map<String, dynamic>;
    return fromSeeds(unb64(m['x'] as String), unb64(m['ed'] as String));
  }

  /// Short human-comparable fingerprint of the public keys ("safety number").
  Future<String> fingerprint() => E2ee.fingerprint(xPublicKey, edPublicKey);
}

/// Private keys encrypted with a passphrase-derived key (stored in `key_backups`).
class EncryptedBackup {
  EncryptedBackup({required this.kdf, required this.salt, required this.nonce, required this.ciphertext});

  final Map<String, dynamic> kdf;
  final String salt;
  final String nonce;
  final String ciphertext;

  Map<String, dynamic> toRow(String userId) => {
    'user_id': userId,
    'kdf': kdf,
    'salt': salt,
    'nonce': nonce,
    'ciphertext': ciphertext,
  };

  factory EncryptedBackup.fromRow(Map<String, dynamic> row) => EncryptedBackup(
    kdf: Map<String, dynamic>.from(row['kdf'] as Map),
    salt: row['salt'] as String,
    nonce: row['nonce'] as String,
    ciphertext: row['ciphertext'] as String,
  );
}

/// An encrypted, signed message as stored in the `messages` table.
class EncryptedMessage {
  EncryptedMessage({required this.nonce, required this.ciphertext, required this.signature});
  final String nonce;
  final String ciphertext;
  final String signature;
}

/// An encrypted file: [data] is uploaded, [key] goes into the (encrypted) message.
class EncryptedFile {
  EncryptedFile({required this.data, required this.key});
  final Uint8List data;
  final String key;
}

class E2ee {
  static final _x25519 = X25519();
  static final _ed25519 = Ed25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// OWASP-recommended minimum Argon2id parameters (19 MiB, 2 passes).
  static const defaultKdf = {'alg': 'argon2id', 'm': 19456, 't': 2, 'p': 1};

  static const _nonceLength = 12;
  static const _macLength = 16;

  // ---------------------------------------------------------------------------
  // Identity backup
  // ---------------------------------------------------------------------------

  static Future<SecretKey> _passphraseKey(String passphrase, List<int> salt, Map<String, dynamic> kdf) {
    if (kdf['alg'] != 'argon2id') {
      throw ArgumentError('Unsupported KDF ${kdf['alg']}');
    }
    final argon = Argon2id(
      memory: kdf['m'] as int,
      iterations: kdf['t'] as int,
      parallelism: kdf['p'] as int,
      hashLength: 32,
    );
    return argon.deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
  }

  static Future<EncryptedBackup> encryptBackup(
    IdentityKeys keys,
    String passphrase, {
    required String userId,
    Map<String, dynamic> kdf = defaultKdf,
  }) async {
    final salt = randomBytes(16);
    final key = await _passphraseKey(passphrase, salt, kdf);
    final box = await _aes.encrypt(
      utf8.encode(keys.toJson()),
      secretKey: key,
      nonce: randomBytes(_nonceLength),
      aad: utf8.encode('cchat-backup-v1|$userId'),
    );
    return EncryptedBackup(
      kdf: Map<String, dynamic>.from(kdf),
      salt: b64(salt),
      nonce: b64(box.nonce),
      ciphertext: b64([...box.cipherText, ...box.mac.bytes]),
    );
  }

  static Future<IdentityKeys> decryptBackup(EncryptedBackup backup, String passphrase, {required String userId}) async {
    final key = await _passphraseKey(passphrase, unb64(backup.salt), backup.kdf);
    final data = unb64(backup.ciphertext);
    if (data.length < _macLength) throw WrongPassphraseException();
    final box = SecretBox(
      data.sublist(0, data.length - _macLength),
      nonce: unb64(backup.nonce),
      mac: Mac(data.sublist(data.length - _macLength)),
    );
    try {
      final clear = await _aes.decrypt(box, secretKey: key, aad: utf8.encode('cchat-backup-v1|$userId'));
      return await IdentityKeys.fromJson(utf8.decode(clear));
    } on SecretBoxAuthenticationError {
      throw WrongPassphraseException();
    }
  }

  // ---------------------------------------------------------------------------
  // Conversation keys
  // ---------------------------------------------------------------------------

  static Future<SecretKey> newConversationKey() async => SecretKey(randomBytes(32));

  static Future<SecretKey> _wrapKey({
    required IdentityKeys me,
    required String otherXPublicKey,
    required String conversationId,
    required int epoch,
    required String senderId,
    required String recipientId,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: me.xKeyPair,
      remotePublicKey: SimplePublicKey(unb64(otherXPublicKey), type: KeyPairType.x25519),
    );
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('$conversationId|$epoch'),
      info: utf8.encode('cchat-wrap-v1|$senderId|$recipientId'),
    );
  }

  static String _wrapAad(String conversationId, int epoch, String senderId, String recipientId) =>
      'cchat-wrap-v1|$conversationId|$epoch|$senderId|$recipientId';

  /// Encrypts [conversationKey] for one recipient. Returns base64(nonce||ct||mac).
  static Future<String> wrapConversationKey({
    required SecretKey conversationKey,
    required IdentityKeys me,
    required String senderId,
    required String recipientId,
    required String recipientXPublicKey,
    required String conversationId,
    required int epoch,
  }) async {
    final kek = await _wrapKey(
      me: me,
      otherXPublicKey: recipientXPublicKey,
      conversationId: conversationId,
      epoch: epoch,
      senderId: senderId,
      recipientId: recipientId,
    );
    final box = await _aes.encrypt(
      await conversationKey.extractBytes(),
      secretKey: kek,
      nonce: randomBytes(_nonceLength),
      aad: utf8.encode(_wrapAad(conversationId, epoch, senderId, recipientId)),
    );
    return b64(box.concatenation());
  }

  /// Decrypts a conversation key wrapped for [me] by [senderId].
  static Future<SecretKey> unwrapConversationKey({
    required String wrappedKey,
    required IdentityKeys me,
    required String senderId,
    required String senderXPublicKey,
    required String recipientId,
    required String conversationId,
    required int epoch,
  }) async {
    final kek = await _wrapKey(
      me: me,
      otherXPublicKey: senderXPublicKey,
      conversationId: conversationId,
      epoch: epoch,
      senderId: senderId,
      recipientId: recipientId,
    );
    try {
      final box = SecretBox.fromConcatenation(unb64(wrappedKey), nonceLength: _nonceLength, macLength: _macLength);
      final clear = await _aes.decrypt(
        box,
        secretKey: kek,
        aad: utf8.encode(_wrapAad(conversationId, epoch, senderId, recipientId)),
      );
      return SecretKey(clear);
    } on SecretBoxAuthenticationError {
      throw DecryptionException('Conversation key could not be unwrapped');
    }
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  static List<int> _messageAad(String conversationId, int epoch, String senderId) =>
      utf8.encode('cchat-msg-v1|$conversationId|$epoch|$senderId');

  static List<int> _signedBytes(
    String conversationId,
    int epoch,
    String senderId,
    List<int> nonce,
    List<int> ciphertext,
  ) => [...utf8.encode('cchat-sig-v1|$conversationId|$epoch|$senderId|'), ...nonce, ...ciphertext];

  /// Encrypts [plaintext] with the conversation key and signs the result.
  static Future<EncryptedMessage> encryptMessage({
    required List<int> plaintext,
    required SecretKey conversationKey,
    required IdentityKeys me,
    required String senderId,
    required String conversationId,
    required int epoch,
  }) async {
    final nonce = randomBytes(_nonceLength);
    final box = await _aes.encrypt(
      plaintext,
      secretKey: conversationKey,
      nonce: nonce,
      aad: _messageAad(conversationId, epoch, senderId),
    );
    final ciphertext = [...box.cipherText, ...box.mac.bytes];
    final signature = await _ed25519.sign(
      _signedBytes(conversationId, epoch, senderId, nonce, ciphertext),
      keyPair: me.edKeyPair,
    );
    return EncryptedMessage(nonce: b64(nonce), ciphertext: b64(ciphertext), signature: b64(signature.bytes));
  }

  /// Verifies the sender's signature and decrypts the message.
  static Future<List<int>> decryptMessage({
    required String nonce,
    required String ciphertext,
    required String signature,
    required SecretKey conversationKey,
    required String senderId,
    required String senderEdPublicKey,
    required String conversationId,
    required int epoch,
  }) async {
    final nonceBytes = unb64(nonce);
    final data = unb64(ciphertext);
    final ok = await _ed25519.verify(
      _signedBytes(conversationId, epoch, senderId, nonceBytes, data),
      signature: Signature(
        unb64(signature),
        publicKey: SimplePublicKey(unb64(senderEdPublicKey), type: KeyPairType.ed25519),
      ),
    );
    if (!ok) throw DecryptionException('Invalid signature');
    if (data.length < _macLength) throw DecryptionException('Truncated ciphertext');
    try {
      return await _aes.decrypt(
        SecretBox(
          data.sublist(0, data.length - _macLength),
          nonce: nonceBytes,
          mac: Mac(data.sublist(data.length - _macLength)),
        ),
        secretKey: conversationKey,
        aad: _messageAad(conversationId, epoch, senderId),
      );
    } on SecretBoxAuthenticationError {
      throw DecryptionException('Message authentication failed');
    }
  }

  // ---------------------------------------------------------------------------
  // Files (GIF uploads etc.) – each file gets its own random key.
  // ---------------------------------------------------------------------------

  static Future<EncryptedFile> encryptFile(List<int> bytes) async {
    final key = randomBytes(32);
    final box = await _aes.encrypt(bytes, secretKey: SecretKey(key), nonce: randomBytes(_nonceLength));
    return EncryptedFile(data: box.concatenation(), key: b64(key));
  }

  static Future<Uint8List> decryptFile(List<int> data, String key) async {
    try {
      final clear = await _aes.decrypt(
        SecretBox.fromConcatenation(data, nonceLength: _nonceLength, macLength: _macLength),
        secretKey: SecretKey(unb64(key)),
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw DecryptionException('Attachment authentication failed');
    }
  }

  // ---------------------------------------------------------------------------
  // Fingerprints
  // ---------------------------------------------------------------------------

  /// 60-digit safety number derived from both public keys, grouped in blocks of 5.
  static Future<String> fingerprint(String xPublicKey, String edPublicKey) async {
    final hash = await Sha256().hash([...unb64(xPublicKey), ...unb64(edPublicKey)]);
    final digits = StringBuffer();
    for (var i = 0; i < 30; i += 5) {
      // 5 bytes -> 40 bits -> 10 decimal digits (mod 10^10)
      var v = 0;
      for (var j = 0; j < 5; j++) {
        v = (v << 8) | hash.bytes[i + j];
      }
      digits.write((v % 10000000000).toString().padLeft(10, '0'));
    }
    final s = digits.toString();
    return [for (var i = 0; i < s.length; i += 5) s.substring(i, i + 5)].join(' ');
  }
}
