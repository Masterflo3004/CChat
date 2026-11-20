// End-to-end test of the services against a local Supabase stack.
//
//   supabase start            (from the repo root)
//   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_PUBLISHABLE_KEY=<key from `supabase status`> \
//     flutter test test/integration
//
// Skipped automatically when the variables are not set.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cchat/data/models.dart';
import 'package:cchat/services/chat_service.dart';
import 'package:cchat/services/cosmetics_service.dart';
import 'package:cchat/services/session.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _url = Platform.environment['SUPABASE_URL'];
final _key = Platform.environment['SUPABASE_PUBLISHABLE_KEY'];

class TestUser {
  TestUser(this.name, this.client, this.session)
    : chat = ChatService(client, session),
      cosmetics = CosmeticsService(client, session);
  final String name;
  final SupabaseClient client;
  final AppSession session;
  final ChatService chat;
  final CosmeticsService cosmetics;
  String get id => session.userId!;
}

Future<void> _until(bool Function() cond, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<TestUser> _newUser(String name) async {
  final client = SupabaseClient(
    _url!,
    _key!,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  final session = AppSession(client);
  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final username = '${name}_$suffix';
  await client.auth.signUp(email: '$username@example.test', password: 'password-$suffix', data: {'username': username});
  await _until(() => session.stage == SessionStage.needsKeySetup);
  await session.createKeys('passphrase for $name');
  expect(session.stage, SessionStage.ready);
  return TestUser(name, client, session);
}

Future<String?> _text(TestUser u, RawMessage m) async {
  final msg = await u.chat.decrypt(m);
  return msg.payload?.text;
}

Future<List<RawMessage>> _rows(TestUser u, String conv) async {
  final rows = await u.client.from('messages').select().eq('conversation_id', conv).order('id', ascending: true);
  return [for (final r in rows) RawMessage.fromRow(r)];
}

void main() {
  final skip = _url == null || _key == null ? 'SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY not set' : null;

  late TestUser alice, bob, carol;

  setUpAll(() async {
    if (skip != null) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null; // allow real network calls to the local stack
    FlutterSecureStorage.setMockInitialValues({});
    alice = await _newUser('alice');
    bob = await _newUser('bob');
    carol = await _newUser('carol');
  });

  test('direct chat: encrypted on the server, readable by the partner only', () async {
    final bobProfile = await alice.chat.profile(bob.id);
    final conv = await alice.chat.createDirectChat(bobProfile);

    // A second DM between the same people returns the same conversation.
    expect(await bob.chat.createDirectChat(await bob.chat.profile(alice.id)), conv);

    // Bob listens via Realtime.
    final received = <RawMessage>[];
    final sub = bob.chat.watchMessages(conv).listen((list) {
      received
        ..clear()
        ..addAll(list);
    });

    await alice.chat.send(conv, MessagePayload.text('hi bob 👋', style: const MessageStyle(skinId: null)));
    await _until(() => received.isNotEmpty);
    await sub.cancel();

    final raw = received.first;
    expect(raw.ciphertext.contains('hi bob'), isFalse);
    expect(utf8.decode(base64Decode(raw.ciphertext), allowMalformed: true).contains('hi bob'), isFalse);
    expect(await _text(bob, raw), 'hi bob 👋');

    // Carol is not a member: RLS hides the messages and blocks sending.
    expect(await _rows(carol, conv), isEmpty);
    await expectLater(
      carol.client.from('messages').insert({
        'conversation_id': conv,
        'sender_id': carol.id,
        'key_epoch': 1,
        'nonce': 'x',
        'ciphertext': 'x',
        'signature': 'x',
      }),
      throwsA(isA<PostgrestException>()),
    );

    // Nobody can read someone else's key backup or wrapped keys.
    expect(await bob.client.from('key_backups').select().eq('user_id', alice.id), isEmpty);
    expect(await carol.client.from('conversation_keys').select().eq('conversation_id', conv), isEmpty);

    // Bob cannot forge a message "from alice": the server enforces sender_id.
    await expectLater(
      bob.client.from('messages').insert({
        'conversation_id': conv,
        'sender_id': alice.id,
        'key_epoch': 1,
        'nonce': raw.nonce,
        'ciphertext': raw.ciphertext,
        'signature': raw.signature,
      }),
      throwsA(isA<PostgrestException>()),
    );
  });

  test('encrypted GIF upload is readable by members only', () async {
    final conv = await alice.chat.createDirectChat(await alice.chat.profile(bob.id));
    final gifBytes = Uint8List.fromList(utf8.encode('GIF89a-pretend-this-is-a-gif'));
    final up = await alice.chat.uploadEncrypted(conv, gifBytes);
    await alice.chat.send(
      conv,
      MessagePayload.gif(GifContent.file(path: up.path, fileKey: up.key, width: 1, height: 1)),
    );

    final rows = await _rows(bob, conv);
    final msg = await bob.chat.decrypt(rows.last);
    expect(msg.payload!.type, PayloadType.gif);
    final gif = msg.payload!.gif!;
    expect(await bob.chat.downloadDecrypted(gif.path!, gif.fileKey!), gifBytes);

    // The stored object is ciphertext, and outsiders cannot download it at all.
    final stored = await bob.client.storage.from('attachments').download(up.path);
    expect(stored, isNot(equals(gifBytes)));
    await expectLater(carol.client.storage.from('attachments').download(up.path), throwsA(isA<StorageException>()));
  });

  test('group chat: key rotation on add, remove and leave', () async {
    final group = await alice.chat.createGroup('Test group', [await alice.chat.profile(bob.id)]);
    await alice.chat.send(group, MessagePayload.text('before carol'));

    // Carol joins -> new epoch. She can read new messages but not old ones.
    await alice.chat.addMembers(group, [await alice.chat.profile(carol.id)]);
    await bob.chat.send(group, MessagePayload.text('welcome carol'));
    var rows = await _rows(carol, group);
    expect(rows.length, 2);
    expect((await carol.chat.decrypt(rows[0])).error, isNotNull);
    expect(await _text(carol, rows[1]), 'welcome carol');
    expect(await _text(alice, rows[1]), 'welcome carol');

    // Only admins can remove members.
    await expectLater(bob.chat.removeMember(group, carol.id), throwsA(isA<PostgrestException>()));

    // Alice removes bob -> bob gets no key for new messages and no longer sees them.
    await alice.chat.removeMember(group, bob.id);
    await carol.chat.send(group, MessagePayload.text('bob is gone'));
    expect(await _rows(bob, group), isEmpty);
    rows = await _rows(alice, group);
    expect(await _text(alice, rows.last), 'bob is gone');

    // Carol leaves -> conversation flagged; Alice's next send rotates automatically.
    await carol.chat.leave(group);
    final before = await alice.client.from('conversations').select().eq('id', group).single();
    expect(before['rotation_needed'], isTrue);
    await alice.chat.send(group, MessagePayload.text('just me now'));
    final after = await alice.client.from('conversations').select().eq('id', group).single();
    expect(after['rotation_needed'], isFalse);
    expect(after['current_epoch'], (before['current_epoch'] as int) + 1);
    rows = await _rows(alice, group);
    expect(await _text(alice, rows.last), 'just me now');

    // Wrapped keys must cover exactly the members: the server rejects partial sets.
    await expectLater(
      alice.client.rpc(
        'rotate_conversation_key',
        params: {'p_conversation_id': group, 'p_epoch': after['current_epoch'] + 1, 'p_wrapped_keys': []},
      ),
      throwsA(isA<PostgrestException>()),
    );
  });

  test('conversation list shows members and unread counts', () async {
    final list = await bob.chat.myConversations();
    final dm = list.firstWhere((c) => !c.isGroup);
    expect(dm.members.map((m) => m.id), containsAll([alice.id, bob.id]));
    expect(dm.unreadCount, greaterThan(0));
    await bob.chat.markRead(dm.id);
    final after = (await bob.chat.myConversations()).firstWhere((c) => c.id == dm.id);
    expect(after.unreadCount, 0);
  });

  test('skins and fonts: upload, set active, visible to others', () async {
    // 1x1 PNG
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final skin = await alice.cosmetics.createSkin(
      name: 'Pixel',
      bytes: png,
      extension: 'png',
      fit: SkinFit.tile,
      textColor: '#FFCC00',
    );
    final font = await alice.client
        .from('user_fonts')
        .insert({'owner_id': alice.id, 'name': 'Fake', 'file_path': '${alice.id}/fake.ttf'})
        .select()
        .single();
    await alice.cosmetics.setActive(skinId: skin.id, fontId: font['id'] as String);
    expect(alice.cosmetics.activeStyle.skinId, skin.id);

    // Bob can read the skin row and its image (needed to render alice's messages).
    final row = await bob.client.from('message_skins').select().eq('id', skin.id).single();
    expect(row['text_color'], '#FFCC00');
    expect(await bob.client.storage.from('skins').download(skin.imagePath), png);

    // Bob cannot upload into alice's folder or change her skin.
    await expectLater(
      bob.client.storage.from('skins').uploadBinary('${alice.id}/evil.png', png),
      throwsA(isA<StorageException>()),
    );
    final updated = await bob.client.from('message_skins').update({'name': 'pwned'}).eq('id', skin.id).select();
    expect(updated, isEmpty);

    // Style travels inside the encrypted payload.
    final conv = await alice.chat.createDirectChat(await alice.chat.profile(bob.id));
    await alice.chat.send(conv, MessagePayload.text('styled', style: alice.cosmetics.activeStyle));
    final rows = await _rows(bob, conv);
    final msg = await bob.chat.decrypt(rows.last);
    expect(msg.payload!.style.skinId, skin.id);
    expect(msg.payload!.style.fontId, font['id']);

    await alice.cosmetics.deleteSkin(skin);
    await alice.session.reloadProfile();
    expect(alice.session.me!.activeSkinId, isNull);
  });

  test('unlock on a second device with the passphrase', () async {
    final client = SupabaseClient(
      _url!,
      _key!,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    final email = alice.client.auth.currentUser!.email!;
    final password = 'password-${email.split('@').first.split('_').last}';
    FlutterSecureStorage.setMockInitialValues({}); // new device: no local keys
    final session = AppSession(client);
    await client.auth.signInWithPassword(email: email, password: password);
    await _until(() => session.stage == SessionStage.needsUnlock);
    await expectLater(session.unlock('wrong'), throwsA(anything));
    await session.unlock('passphrase for alice');
    expect(session.identity!.xPublicKey, alice.session.identity!.xPublicKey);

    final device2 = ChatService(client, session);
    final conv = (await device2.myConversations()).firstWhere((c) => !c.isGroup).id;
    final rows = await _rows(alice, conv);
    expect(await _text(TestUser('alice2', client, session), rows.first), isNotNull);
    expect((await device2.decrypt(rows.first)).error, isNull);
  });
}
