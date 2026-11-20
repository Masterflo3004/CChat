import 'dart:convert';

import 'package:cchat/crypto/e2ee.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const conv = '7f1b0c2e-1111-4222-8333-944455556666';

  late IdentityKeys alice;
  late IdentityKeys bob;
  late IdentityKeys eve;

  setUpAll(() async {
    alice = await IdentityKeys.generate();
    bob = await IdentityKeys.generate();
    eve = await IdentityKeys.generate();
  });

  test('identity round-trips through JSON', () async {
    final restored = await IdentityKeys.fromJson(alice.toJson());
    expect(restored.xPublicKey, alice.xPublicKey);
    expect(restored.edPublicKey, alice.edPublicKey);
  });

  test('backup decrypts only with the right passphrase and user id', () async {
    // Small KDF params keep the test fast.
    const kdf = {'alg': 'argon2id', 'm': 1024, 't': 1, 'p': 1};
    final backup = await E2ee.encryptBackup(alice, 'correct horse', userId: 'u1', kdf: kdf);

    final restored = await E2ee.decryptBackup(backup, 'correct horse', userId: 'u1');
    expect(restored.xPublicKey, alice.xPublicKey);

    expect(() => E2ee.decryptBackup(backup, 'wrong', userId: 'u1'), throwsA(isA<WrongPassphraseException>()));
    expect(() => E2ee.decryptBackup(backup, 'correct horse', userId: 'u2'), throwsA(isA<WrongPassphraseException>()));
  });

  test('conversation key wrapped by alice can be unwrapped by bob only', () async {
    final key = await E2ee.newConversationKey();
    final wrapped = await E2ee.wrapConversationKey(
      conversationKey: key,
      me: alice,
      senderId: 'alice',
      recipientId: 'bob',
      recipientXPublicKey: bob.xPublicKey,
      conversationId: conv,
      epoch: 1,
    );

    final unwrapped = await E2ee.unwrapConversationKey(
      wrappedKey: wrapped,
      me: bob,
      senderId: 'alice',
      senderXPublicKey: alice.xPublicKey,
      recipientId: 'bob',
      conversationId: conv,
      epoch: 1,
    );
    expect(await unwrapped.extractBytes(), await key.extractBytes());

    expect(
      () => E2ee.unwrapConversationKey(
        wrappedKey: wrapped,
        me: eve,
        senderId: 'alice',
        senderXPublicKey: alice.xPublicKey,
        recipientId: 'bob',
        conversationId: conv,
        epoch: 1,
      ),
      throwsA(isA<DecryptionException>()),
    );

    // Wrong epoch (replayed key) must fail too.
    expect(
      () => E2ee.unwrapConversationKey(
        wrappedKey: wrapped,
        me: bob,
        senderId: 'alice',
        senderXPublicKey: alice.xPublicKey,
        recipientId: 'bob',
        conversationId: conv,
        epoch: 2,
      ),
      throwsA(isA<DecryptionException>()),
    );
  });

  test('messages decrypt, and tampering / forged senders are rejected', () async {
    final key = await E2ee.newConversationKey();
    final msg = await E2ee.encryptMessage(
      plaintext: utf8.encode('hello bob'),
      conversationKey: key,
      me: alice,
      senderId: 'alice',
      conversationId: conv,
      epoch: 3,
    );

    final clear = await E2ee.decryptMessage(
      nonce: msg.nonce,
      ciphertext: msg.ciphertext,
      signature: msg.signature,
      conversationKey: key,
      senderId: 'alice',
      senderEdPublicKey: alice.edPublicKey,
      conversationId: conv,
      epoch: 3,
    );
    expect(utf8.decode(clear), 'hello bob');

    // Claiming the message came from eve fails the signature check.
    expect(
      () => E2ee.decryptMessage(
        nonce: msg.nonce,
        ciphertext: msg.ciphertext,
        signature: msg.signature,
        conversationKey: key,
        senderId: 'alice',
        senderEdPublicKey: eve.edPublicKey,
        conversationId: conv,
        epoch: 3,
      ),
      throwsA(isA<DecryptionException>()),
    );

    // Flip one ciphertext byte.
    final bytes = unb64(msg.ciphertext);
    bytes[0] ^= 1;
    expect(
      () => E2ee.decryptMessage(
        nonce: msg.nonce,
        ciphertext: b64(bytes),
        signature: msg.signature,
        conversationKey: key,
        senderId: 'alice',
        senderEdPublicKey: alice.edPublicKey,
        conversationId: conv,
        epoch: 3,
      ),
      throwsA(isA<DecryptionException>()),
    );
  });

  test('files round-trip with their own key', () async {
    final data = List<int>.generate(5000, (i) => i % 256);
    final enc = await E2ee.encryptFile(data);
    expect(enc.data, isNot(equals(data)));
    expect(await E2ee.decryptFile(enc.data, enc.key), data);
  });

  test('fingerprint is stable and formatted', () async {
    final a = await alice.fingerprint();
    expect(a, await E2ee.fingerprint(alice.xPublicKey, alice.edPublicKey));
    expect(a.split(' ').length, 12);
    expect(a, isNot(await bob.fingerprint()));
  });
}
