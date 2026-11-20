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
import 'package:cchat/services/community_service.dart';
import 'package:cchat/services/cosmetics_service.dart';
import 'package:cchat/services/media_service.dart';
import 'package:cchat/services/moderation_service.dart';
import 'package:cchat/services/session.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _url = Platform.environment['SUPABASE_URL'];
final _key = Platform.environment['SUPABASE_PUBLISHABLE_KEY'];
// Only used to make a test user a moderator.
final _serviceKey = Platform.environment['SUPABASE_SERVICE_ROLE_KEY'];

class TestUser {
  TestUser(this.name, this.client, this.session) : chat = ChatService(client, session), media = MediaService(client) {
    cosmetics = CosmeticsService(client, session, media);
    community = CommunityService(client, session, media);
    moderation = ModerationService(client);
  }
  final String name;
  final SupabaseClient client;
  final AppSession session;
  final ChatService chat;
  final MediaService media;
  late final CosmeticsService cosmetics;
  late final CommunityService community;
  late final ModerationService moderation;
  String get id => session.userId!;
}

/// Unique fake files (the server sniffs magic bytes, it doesn't decode them).
Uint8List _fakeGif([int w = 40, int h = 30]) => Uint8List.fromList([
  ...utf8.encode('GIF89a'),
  w & 0xff,
  w >> 8,
  h & 0xff,
  h >> 8,
  ...utf8.encode('${DateTime.now().microsecondsSinceEpoch}-${_counter++}'),
]);
Uint8List _fakeFont() =>
    Uint8List.fromList([0, 1, 0, 0, ...utf8.encode('font-${DateTime.now().microsecondsSinceEpoch}-${_counter++}')]);
var _counter = 0;

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

    // Bob listens via Realtime. Wait for the initial snapshot so the subscription is
    // set up before alice sends (Realtime can take a moment right after a DB reset).
    final received = <RawMessage>[];
    var snapshots = 0;
    final sub = bob.chat.watchMessages(conv).listen((list) {
      snapshots++;
      received
        ..clear()
        ..addAll(list);
    });
    await _until(() => snapshots > 0);
    await Future<void>.delayed(const Duration(seconds: 2));

    await alice.chat.send(conv, MessagePayload.text('hi bob 👋', style: const MessageStyle(skinId: null)));
    await _until(() => received.isNotEmpty, timeout: const Duration(seconds: 60));
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
    // Image background (tiled) + image frame border.
    final skin = await alice.cosmetics.createSkin(
      SkinUpload(
        skin: MessageSkin(
          id: '',
          ownerId: '',
          name: 'Pixel',
          textColor: '#FFCC00',
          background: SkinBackground.image,
          bgFit: SkinFit.tile,
          border: SkinBorder.image,
          borderWidth: 6,
          borderSlice: 1,
          borderRadius: 4,
        ),
        backgroundBytes: png,
        backgroundExt: 'png',
        borderBytes: png,
        borderExt: 'png',
      ),
    );
    expect(skin.bgImagePath, isNotNull);
    expect(skin.borderImagePath, isNotNull);
    expect(skin.border, SkinBorder.image);

    // Gradient background + solid line border, no images.
    final gradient = await alice.cosmetics.createSkin(
      SkinUpload(
        skin: MessageSkin(
          id: '',
          ownerId: '',
          name: 'Sunset',
          textColor: '#FFFFFF',
          background: SkinBackground.gradient,
          bgColor: '#FF5F6D',
          bgColor2: '#FFC371',
          border: SkinBorder.solid,
          borderColor: '#000000',
          borderWidth: 3,
          borderRadius: 24,
        ),
      ),
    );
    expect(gradient.bgImagePath, isNull);
    expect(gradient.summary, 'Gradient · 3px border');

    // The database rejects incomplete skins (e.g. image frame without an image)
    // and image paths outside the owner's folder.
    await expectLater(
      alice.client.from('message_skins').insert({
        'owner_id': alice.id,
        'name': 'broken',
        'bg_type': 'theme',
        'border_type': 'image',
        'border_width': 4,
        'border_slice': 4,
      }),
      throwsA(isA<PostgrestException>()),
    );
    await expectLater(
      alice.client.from('message_skins').insert({
        'owner_id': alice.id,
        'name': 'stolen',
        'bg_type': 'image',
        'bg_image_path': '${bob.id}/x.png',
      }),
      throwsA(isA<PostgrestException>()),
    );
    final uploadedFont = await alice.cosmetics.uploadFont(name: 'Fake', bytes: _fakeFont(), extension: 'ttf');
    final font = {'id': uploadedFont.id};
    // Font rows must point at a hash-checked upload of the owner.
    await expectLater(
      alice.client.from('user_fonts').insert({'owner_id': alice.id, 'name': 'x', 'file_path': '${alice.id}/x.ttf'}),
      throwsA(isA<PostgrestException>()),
    );
    await alice.cosmetics.setActive(skinId: skin.id, fontId: font['id']);
    expect(alice.cosmetics.activeStyle.skinId, skin.id);

    // Bob can read the skin row and its image (needed to render alice's messages).
    final row = await bob.client.from('message_skins').select().eq('id', skin.id).single();
    expect(row['text_color'], '#FFCC00');
    expect(row['bg_type'], 'image');
    expect(row['border_type'], 'image');
    expect(await bob.client.storage.from('skins').download(skin.bgImagePath!), png);
    expect(await bob.client.storage.from('skins').download(skin.borderImagePath!), png);

    // Nobody can write to the public buckets directly (bypassing the hash check).
    await expectLater(
      bob.client.storage.from('skins').uploadBinary('${alice.id}/evil.png', png),
      throwsA(isA<StorageException>()),
    );
    await expectLater(
      alice.client.storage.from('skins').uploadBinary('${alice.id}/direct.png', png),
      throwsA(isA<StorageException>()),
    );
    final updated = await bob.client.from('message_skins').update({'name': 'pwned'}).eq('id', skin.id).select();
    expect(updated, isEmpty);
    // Owners can rename, but not change the look of a skin already used in messages.
    await expectLater(
      alice.client.from('message_skins').update({'bg_type': 'theme'}).eq('id', skin.id),
      throwsA(isA<PostgrestException>()),
    );

    // Style travels inside the encrypted payload.
    final conv = await alice.chat.createDirectChat(await alice.chat.profile(bob.id));
    await alice.chat.send(conv, MessagePayload.text('styled', style: alice.cosmetics.activeStyle));
    final rows = await _rows(bob, conv);
    final msg = await bob.chat.decrypt(rows.last);
    expect(msg.payload!.style.skinId, skin.id);
    expect(msg.payload!.style.fontId, font['id']);

    await alice.cosmetics.deleteSkin(skin);
    await alice.cosmetics.deleteSkin(gradient);
    await alice.session.reloadProfile();
    expect(alice.session.me!.activeSkinId, isNull);
    // Both images were removed from storage.
    await expectLater(
      alice.client.storage.from('skins').download(skin.borderImagePath!),
      throwsA(isA<StorageException>()),
    );
  });

  test('GIF library: upload, gallery, privacy of unlisted GIFs, direct writes blocked', () async {
    final gif = await alice.community.uploadGif(bytes: _fakeGif(), filename: 'cat.gif', title: 'Dancing cat');
    expect(gif.width, 40); // read from the GIF header on the server
    expect(gif.height, 30);

    final community = await bob.community.gifs();
    expect(community.map((g) => g.id), contains(gif.id));
    expect(await bob.media.download('gifs', gif.path), isNotEmpty);

    final hidden = await alice.community.uploadGif(bytes: _fakeGif(), filename: 'x.gif', isPublic: false);
    expect((await bob.community.gifs()).map((g) => g.id), isNot(contains(hidden.id)));
    expect((await alice.community.gifs(mine: true)).map((g) => g.id), containsAll([gif.id, hidden.id]));

    // Search by title.
    expect((await bob.community.gifs(query: 'dancing')).map((g) => g.id), contains(gif.id));

    // Bob can't claim alice's file, and nobody uploads to the bucket directly.
    await expectLater(
      bob.client.from('gifs').insert({'owner_id': bob.id, 'asset_id': gif.assetId}),
      throwsA(isA<PostgrestException>()),
    );
    await expectLater(
      bob.client.storage.from('gifs').uploadBinary('${bob.id}/x.gif', _fakeGif()),
      throwsA(isA<StorageException>()),
    );

    // Wrong file type is rejected by content, not by name.
    await expectLater(
      alice.media.upload(kind: 'gif', bytes: Uint8List.fromList(utf8.encode('not a gif')), filename: 'a.gif'),
      throwsA(isA<ArgumentError>()),
    );

    // Library GIFs can be sent in (encrypted) messages.
    final conv = await alice.chat.createDirectChat(await alice.chat.profile(bob.id));
    await alice.chat.send(conv, MessagePayload.gif(gif.toContent()));
    final msg = await bob.chat.decrypt((await _rows(bob, conv)).last);
    expect(msg.payload!.gif!.source, GifSource.library);
    expect(msg.payload!.gif!.gifId, gif.id);
  });

  test('gallery: publish skins and fonts, others can save and use them', () async {
    final skin = await alice.cosmetics.createSkin(
      SkinUpload(
        skin: MessageSkin(
          id: '',
          ownerId: '',
          name: 'Public sunset',
          textColor: '#FFFFFF',
          background: SkinBackground.gradient,
          bgColor: '#FF5F6D',
          bgColor2: '#FFC371',
          isPublic: true,
        ),
      ),
    );
    final private = await alice.cosmetics.createSkin(
      SkinUpload(
        skin: MessageSkin(id: '', ownerId: '', name: 'Secret', textColor: '#FFFFFF', bgColor: '#000000'),
      ),
    );
    final font = await alice.cosmetics.uploadFont(name: 'Shared', bytes: _fakeFont(), extension: 'ttf', isPublic: true);

    final skins = await bob.community.gallerySkins();
    expect(skins.map((e) => e.item.id), contains(skin.id));
    expect(skins.map((e) => e.item.id), isNot(contains(private.id)));
    expect(skins.firstWhere((e) => e.item.id == skin.id).ownerUsername, alice.session.me!.username);
    expect((await bob.community.galleryFonts()).map((e) => e.item.id), contains(font.id));

    await bob.community.save('skin', skin.id);
    await bob.community.save('font', font.id);
    expect((await bob.community.savedSkins()).map((s) => s.id), [skin.id]);
    expect((await bob.community.savedFonts()).map((f) => f.id), [font.id]);
    await bob.cosmetics.setActive(skinId: skin.id, fontId: font.id); // using someone else's skin is allowed

    // Alice unpublishes: gone from the gallery.
    await alice.community.setSkinPublic(skin.id, false);
    expect((await bob.community.gallerySkins()).map((e) => e.item.id), isNot(contains(skin.id)));
    // Bob can't publish alice's skin.
    final changed = await bob.client.from('message_skins').update({'is_public': true}).eq('id', skin.id).select();
    expect(changed, isEmpty);
    await bob.cosmetics.setActive(skinId: null, fontId: null);
  });

  test('moderation: report, hash ban deletes all copies and blocks re-uploads', () async {
    if (_serviceKey == null) {
      markTestSkipped('SUPABASE_SERVICE_ROLE_KEY not set (needed to create a moderator)');
      return;
    }
    final service = SupabaseClient(_url!, _serviceKey!);
    await service.from('moderators').upsert({'user_id': carol.id});
    expect(await carol.moderation.isModerator(), isTrue);
    expect(await bob.moderation.isModerator(), isFalse);

    final bytes = _fakeGif();
    final gif = await bob.community.uploadGif(bytes: bytes, filename: 'bad.gif', title: 'bad');
    // Same file as a skin image by another user (different bucket): also banned later.
    final copy = await alice.media.upload(kind: 'gif', bytes: bytes, filename: 'copy.gif');

    await alice.community.report(ReportTarget.gif, gif.id, 'offensive');
    await alice.community.report(ReportTarget.gif, gif.id, 'again'); // duplicate open report is ignored
    expect(await bob.client.from('reports').select(), isEmpty); // reports are private

    final reports = await carol.moderation.openReports();
    final report = reports.firstWhere((r) => r.targetId == gif.id);
    expect(report.reason, 'offensive');
    expect(reports.where((r) => r.targetId == gif.id).length, 1);

    // Only moderators can act.
    await expectLater(bob.moderation.banAsset(gif.assetId, 'nope'), throwsA(isA<FunctionException>()));

    final deleted = await carol.moderation.banAsset(gif.assetId, 'offensive GIF');
    expect(deleted, 2); // bob's and alice's copy

    // Files are gone, GIF is out of the gallery, report closed.
    await expectLater(alice.client.storage.from('gifs').download(gif.path), throwsA(isA<StorageException>()));
    await expectLater(alice.client.storage.from('gifs').download(copy.path), throwsA(isA<StorageException>()));
    expect((await alice.community.gifs()).map((g) => g.id), isNot(contains(gif.id)));
    expect((await carol.moderation.openReports()).where((r) => r.id == report.id), isEmpty);

    // Re-uploading the same file is refused for everyone.
    await expectLater(
      bob.community.uploadGif(bytes: bytes, filename: 'again.gif'),
      throwsA(isA<BannedFileException>()),
    );
    await expectLater(
      alice.media.upload(kind: 'image', bytes: bytes, filename: 'sneaky.gif'),
      throwsA(isA<BannedFileException>()),
    );

    // End-to-end encrypted attachments are checked by the clients.
    expect(await alice.media.isBanned(bytes), isTrue);
    expect(await alice.media.isBanned(_fakeGif()), isFalse);

    final banned = await carol.moderation.bannedHashes();
    final hash = await MediaService.sha256Hex(bytes);
    expect(banned.map((b) => b.sha256), contains(hash));
    expect(await bob.client.from('banned_hashes').select(), isEmpty); // list is moderators-only

    // Unban: uploads work again.
    await carol.moderation.unban(hash);
    final again = await bob.media.upload(kind: 'gif', bytes: bytes, filename: 'ok.gif');
    expect(again.sha256, hash);

    // Reporting an encrypted attachment shares a decrypted copy with moderators only.
    final evidence = _fakeGif();
    await alice.community.reportAttachment(evidence, 'evidence.gif', 'sent to me in a chat');
    final attReport = (await carol.moderation.openReports()).firstWhere((r) => r.targetType == ReportTarget.attachment);
    final evAsset = (await carol.moderation.asset(attReport.evidenceAssetId!))!;
    expect(await carol.client.storage.from('evidence').download(evAsset.path), evidence);
    await expectLater(bob.client.storage.from('evidence').download(evAsset.path), throwsA(isA<StorageException>()));

    // Dismiss.
    await carol.moderation.dismiss(attReport.id);
    expect((await carol.moderation.openReports()).where((r) => r.id == attReport.id), isEmpty);
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
