import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../crypto/e2ee.dart';
import '../data/models.dart';
import 'session.dart';

/// All conversation and message operations. Encrypts before anything leaves the device.
class ChatService {
  ChatService(this.client, this.session) {
    session.addListener(_onSession);
  }

  final SupabaseClient client;
  final AppSession session;

  static const _uuid = Uuid();
  static const maxAttachmentBytes = 8 * 1024 * 1024;

  final _profiles = <String, Profile>{};
  final _convKeys = <String, Future<SecretKey>>{};
  final _decrypted = <int, ChatMessage>{};
  final _files = <String, Future<Uint8List>>{};
  String? _cacheOwner;

  String get myId => session.userId!;
  IdentityKeys get _me => session.identity!;

  void _onSession() {
    if (session.userId != _cacheOwner) {
      _cacheOwner = session.userId;
      _profiles.clear();
      _convKeys.clear();
      _decrypted.clear();
      _files.clear();
    }
  }

  // ---------------------------------------------------------------------------
  // Profiles
  // ---------------------------------------------------------------------------

  Future<List<Profile>> profiles(Iterable<String> ids, {bool fresh = false}) async {
    final wanted = ids.toSet();
    final missing = fresh ? wanted : wanted.where((id) => !_profiles.containsKey(id)).toSet();
    if (missing.isNotEmpty) {
      final rows = await client.from('profiles').select().inFilter('id', missing.toList());
      for (final r in rows) {
        final p = Profile.fromRow(r);
        _profiles[p.id] = p;
      }
    }
    return [
      for (final id in wanted)
        if (_profiles[id] != null) _profiles[id]!,
    ];
  }

  Future<Profile> profile(String id) async {
    final list = await profiles([id]);
    if (list.isEmpty) throw StateError('Unknown user $id');
    return list.first;
  }

  Future<List<Profile>> searchUsers(String query) async {
    // Escape LIKE wildcards: '_' is a valid username character.
    final q = query.trim().toLowerCase().replaceAllMapped(RegExp(r'[%_\\]'), (m) => '\\${m[0]}');
    if (q.isEmpty) return [];
    final rows = await client
        .from('profiles')
        .select()
        .ilike('username', '$q%')
        .neq('id', myId)
        .not('x25519_public_key', 'is', null)
        .limit(20);
    return [for (final r in rows) Profile.fromRow(r)];
  }

  // ---------------------------------------------------------------------------
  // Conversations
  // ---------------------------------------------------------------------------

  Future<List<Conversation>> myConversations() async {
    final rows = await client.rpc('my_conversations') as List;
    return [for (final r in rows) Conversation.fromRow(Map<String, dynamic>.from(r as Map))];
  }

  /// Emits the conversation list and re-emits whenever something relevant changes.
  Stream<List<Conversation>> watchConversations() {
    late final StreamController<List<Conversation>> controller;
    RealtimeChannel? channel;
    Timer? debounce;

    Future<void> load() async {
      try {
        final list = await myConversations();
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    void schedule() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 300), load);
    }

    controller = StreamController<List<Conversation>>(
      onListen: () {
        load();
        channel = client.channel('conversation-list-${_uuid.v4()}');
        for (final table in ['messages', 'conversations', 'conversation_members']) {
          channel!.onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            callback: (_) => schedule(),
          );
        }
        channel!.subscribe();
      },
      onCancel: () async {
        debounce?.cancel();
        if (channel != null) await client.removeChannel(channel!);
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<List<Map<String, dynamic>>> _wrapForAll({
    required String conversationId,
    required int epoch,
    required SecretKey key,
    required Iterable<String> memberIds,
  }) async {
    // Always fetch fresh public keys before wrapping.
    final members = await profiles(memberIds, fresh: true);
    if (members.length != memberIds.toSet().length || members.any((m) => !m.hasKeys)) {
      throw StateError('Some members have not set up encryption yet');
    }
    return [
      for (final m in members)
        {
          'recipient_id': m.id,
          'wrapped_key': await E2ee.wrapConversationKey(
            conversationKey: key,
            me: _me,
            senderId: myId,
            recipientId: m.id,
            recipientXPublicKey: m.xPublicKey!,
            conversationId: conversationId,
            epoch: epoch,
          ),
        },
    ];
  }

  Future<String> createDirectChat(Profile other) => _create(isGroup: false, name: null, others: [other.id]);

  Future<String> createGroup(String name, List<Profile> members) =>
      _create(isGroup: true, name: name, others: members.map((m) => m.id).toList());

  Future<String> _create({required bool isGroup, String? name, required List<String> others}) async {
    final id = _uuid.v4();
    final key = await E2ee.newConversationKey();
    final wrapped = await _wrapForAll(conversationId: id, epoch: 1, key: key, memberIds: {myId, ...others});
    final result = await client.rpc(
      'create_conversation',
      params: {
        'p_conversation_id': id,
        'p_is_group': isGroup,
        'p_name': name,
        'p_member_ids': others,
        'p_wrapped_keys': wrapped,
      },
    );
    final convId = result as String;
    if (convId == id) _convKeys['$id:1'] = Future.value(key);
    return convId;
  }

  Future<({int epoch, bool rotationNeeded})> _state(String conversationId) async {
    final row = await client
        .from('conversations')
        .select('current_epoch, rotation_needed')
        .eq('id', conversationId)
        .single();
    return (epoch: row['current_epoch'] as int, rotationNeeded: row['rotation_needed'] as bool);
  }

  Future<List<String>> _memberIds(String conversationId) async {
    final rows = await client.from('conversation_members').select('user_id').eq('conversation_id', conversationId);
    return [for (final r in rows) r['user_id'] as String];
  }

  /// Starts a new key epoch for the current members.
  Future<void> rotateKey(String conversationId) async {
    final state = await _state(conversationId);
    final epoch = state.epoch + 1;
    final key = await E2ee.newConversationKey();
    final wrapped = await _wrapForAll(
      conversationId: conversationId,
      epoch: epoch,
      key: key,
      memberIds: await _memberIds(conversationId),
    );
    await client.rpc(
      'rotate_conversation_key',
      params: {'p_conversation_id': conversationId, 'p_epoch': epoch, 'p_wrapped_keys': wrapped},
    );
    _convKeys['$conversationId:$epoch'] = Future.value(key);
  }

  /// Rotates every conversation (used after resetting your identity keys).
  Future<void> rotateAll() async {
    _convKeys.clear();
    _decrypted.clear();
    for (final c in await myConversations()) {
      try {
        await rotateKey(c.id);
      } catch (_) {
        // Best effort: the next send rotates if still needed.
      }
    }
  }

  Future<void> addMembers(String conversationId, List<Profile> newMembers) async {
    final state = await _state(conversationId);
    final epoch = state.epoch + 1;
    final key = await E2ee.newConversationKey();
    final ids = newMembers.map((m) => m.id).toList();
    final wrapped = await _wrapForAll(
      conversationId: conversationId,
      epoch: epoch,
      key: key,
      memberIds: {...await _memberIds(conversationId), ...ids},
    );
    await client.rpc(
      'add_group_members',
      params: {'p_conversation_id': conversationId, 'p_user_ids': ids, 'p_epoch': epoch, 'p_wrapped_keys': wrapped},
    );
    _convKeys['$conversationId:$epoch'] = Future.value(key);
  }

  Future<void> removeMember(String conversationId, String userId) async {
    final state = await _state(conversationId);
    final epoch = state.epoch + 1;
    final key = await E2ee.newConversationKey();
    final remaining = (await _memberIds(conversationId)).where((id) => id != userId);
    final wrapped = await _wrapForAll(conversationId: conversationId, epoch: epoch, key: key, memberIds: remaining);
    await client.rpc(
      'remove_group_member',
      params: {'p_conversation_id': conversationId, 'p_user_id': userId, 'p_epoch': epoch, 'p_wrapped_keys': wrapped},
    );
    _convKeys['$conversationId:$epoch'] = Future.value(key);
  }

  Future<void> leave(String conversationId) =>
      client.rpc('leave_conversation', params: {'p_conversation_id': conversationId});

  Future<SecretKey> _conversationKey(String conversationId, int epoch) {
    final cacheKey = '$conversationId:$epoch';
    return _convKeys[cacheKey] ??=
        () async {
          final row = await client
              .from('conversation_keys')
              .select()
              .eq('conversation_id', conversationId)
              .eq('epoch', epoch)
              .eq('recipient_id', myId)
              .maybeSingle();
          if (row == null) {
            throw DecryptionException('No key for this message (sent before you joined?)');
          }
          final senderId = row['sender_id'] as String;
          final sender = await profile(senderId);
          return E2ee.unwrapConversationKey(
            wrappedKey: row['wrapped_key'] as String,
            me: _me,
            senderId: senderId,
            senderXPublicKey: sender.xPublicKey!,
            recipientId: myId,
            conversationId: conversationId,
            epoch: epoch,
          );
        }()..catchError((Object _) {
          _convKeys.remove(cacheKey);
          return SecretKey(const []);
        });
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Stream<List<RawMessage>> watchMessages(String conversationId, {int limit = 200}) => client
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('conversation_id', conversationId)
      .order('created_at', ascending: false)
      .limit(limit)
      .map((rows) => [for (final r in rows) RawMessage.fromRow(r)]..sort((a, b) => b.id.compareTo(a.id)));

  Future<void> send(String conversationId, MessagePayload payload) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      var state = await _state(conversationId);
      if (state.rotationNeeded) {
        try {
          await rotateKey(conversationId);
        } on PostgrestException catch (e) {
          if (e.code != '40001') rethrow; // someone else rotated first
        }
        state = await _state(conversationId);
      }
      final key = await _conversationKey(conversationId, state.epoch);
      final enc = await E2ee.encryptMessage(
        plaintext: payload.encode(),
        conversationKey: key,
        me: _me,
        senderId: myId,
        conversationId: conversationId,
        epoch: state.epoch,
      );
      try {
        await client.from('messages').insert({
          'conversation_id': conversationId,
          'sender_id': myId,
          'key_epoch': state.epoch,
          'nonce': enc.nonce,
          'ciphertext': enc.ciphertext,
          'signature': enc.signature,
        });
        return;
      } on PostgrestException catch (e) {
        if (e.code != '40001' || attempt == 2) rethrow; // epoch changed meanwhile: retry
      }
    }
  }

  ChatMessage? cachedMessage(int id) => _decrypted[id];

  Future<ChatMessage> decrypt(RawMessage raw) async {
    final cached = _decrypted[raw.id];
    if (cached != null) return cached;
    ChatMessage result;
    try {
      final key = await _conversationKey(raw.conversationId, raw.keyEpoch);
      final sender = await profile(raw.senderId);
      if (sender.edPublicKey == null) throw DecryptionException('Sender has no signing key');
      final clear = await E2ee.decryptMessage(
        nonce: raw.nonce,
        ciphertext: raw.ciphertext,
        signature: raw.signature,
        conversationKey: key,
        senderId: raw.senderId,
        senderEdPublicKey: sender.edPublicKey!,
        conversationId: raw.conversationId,
        epoch: raw.keyEpoch,
      );
      result = ChatMessage(raw: raw, payload: MessagePayload.decode(clear));
    } on DecryptionException catch (e) {
      result = ChatMessage(raw: raw, error: e.message);
    } catch (e) {
      result = ChatMessage(raw: raw, error: 'Could not decrypt message');
    }
    _decrypted[raw.id] = result;
    return result;
  }

  Future<void> deleteMessage(int id) async {
    await client.from('messages').delete().eq('id', id);
    _decrypted.remove(id);
  }

  Future<void> markRead(String conversationId) async {
    await client
        .from('conversation_members')
        .update({'last_read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('conversation_id', conversationId)
        .eq('user_id', myId);
  }

  // ---------------------------------------------------------------------------
  // Encrypted attachments
  // ---------------------------------------------------------------------------

  /// Encrypts [bytes] with a fresh key and uploads the ciphertext.
  Future<({String path, String key})> uploadEncrypted(String conversationId, Uint8List bytes) async {
    if (bytes.length > maxAttachmentBytes) {
      throw ArgumentError('File is larger than ${maxAttachmentBytes ~/ (1024 * 1024)} MB');
    }
    final enc = await E2ee.encryptFile(bytes);
    final path = '$conversationId/${_uuid.v4()}.bin';
    await client.storage
        .from('attachments')
        .uploadBinary(path, enc.data, fileOptions: const FileOptions(contentType: 'application/octet-stream'));
    _files[path] = Future.value(bytes);
    return (path: path, key: enc.key);
  }

  Future<Uint8List> downloadDecrypted(String path, String key) {
    return _files[path] ??=
        () async {
          final data = await client.storage.from('attachments').download(path);
          return E2ee.decryptFile(data, key);
        }()..catchError((Object _) {
          _files.remove(path);
          return Uint8List(0);
        });
  }
}
