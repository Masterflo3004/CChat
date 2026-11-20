import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../crypto/e2ee.dart';
import '../data/models.dart';

enum SessionStage { loading, signedOut, needsKeySetup, needsUnlock, ready, error }

/// Tracks auth state and the user's unlocked encryption identity.
class AppSession extends ChangeNotifier {
  AppSession(this.client, {FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage() {
    _authSub = client.auth.onAuthStateChange.listen((data) {
      final uid = data.session?.user.id;
      if (uid != _userId || data.event == AuthChangeEvent.initialSession) {
        _userId = uid;
        unawaited(_refresh());
      }
    });
  }

  final SupabaseClient client;
  final FlutterSecureStorage _storage;
  late final StreamSubscription<AuthState> _authSub;

  SessionStage stage = SessionStage.loading;
  String? errorMessage;
  IdentityKeys? identity;
  Profile? me;
  String? _userId;
  int _generation = 0;

  String? get userId => _userId;

  String _storageKey(String uid) => 'cchat.identity.$uid';

  void _set(SessionStage s) {
    stage = s;
    notifyListeners();
  }

  Future<void> retry() => _refresh();

  Future<void> _refresh() async {
    final gen = ++_generation;
    final uid = _userId;
    identity = null;
    me = null;
    errorMessage = null;
    if (uid == null) {
      _set(SessionStage.signedOut);
      return;
    }
    _set(SessionStage.loading);
    try {
      final profile = await _loadProfile(uid);
      if (gen != _generation) return;
      me = profile;

      final local = await _storage.read(key: _storageKey(uid));
      if (local != null) {
        final keys = await IdentityKeys.fromJson(local);
        if (keys.xPublicKey == profile.xPublicKey && keys.edPublicKey == profile.edPublicKey) {
          if (gen != _generation) return;
          identity = keys;
          _set(SessionStage.ready);
          return;
        }
        // Keys were reset on another device; the local copy is stale.
        await _storage.delete(key: _storageKey(uid));
      }

      final backup = await client.from('key_backups').select('user_id').eq('user_id', uid).maybeSingle();
      if (gen != _generation) return;
      _set(backup != null ? SessionStage.needsUnlock : SessionStage.needsKeySetup);
    } catch (e) {
      if (gen != _generation) return;
      errorMessage = e.toString();
      _set(SessionStage.error);
    }
  }

  Future<Profile> _loadProfile(String uid) async {
    final row = await client.from('profiles').select().eq('id', uid).single();
    return Profile.fromRow(row);
  }

  Future<void> reloadProfile() async {
    final uid = _userId;
    if (uid == null) return;
    me = await _loadProfile(uid);
    notifyListeners();
  }

  /// First-time setup (or reset): new identity, backed up with [passphrase].
  /// Resetting makes all previous messages unreadable for this user.
  Future<void> createKeys(String passphrase) async {
    final uid = _userId!;
    final keys = await IdentityKeys.generate();
    final backup = await E2ee.encryptBackup(keys, passphrase, userId: uid);
    await client.from('key_backups').upsert(backup.toRow(uid));
    await client
        .from('profiles')
        .update({'x25519_public_key': keys.xPublicKey, 'ed25519_public_key': keys.edPublicKey})
        .eq('id', uid);
    await _storage.write(key: _storageKey(uid), value: keys.toJson());
    identity = keys;
    me = await _loadProfile(uid);
    _set(SessionStage.ready);
  }

  /// Restores the identity on a new device. Throws [WrongPassphraseException].
  Future<void> unlock(String passphrase) async {
    final uid = _userId!;
    final row = await client.from('key_backups').select().eq('user_id', uid).single();
    final keys = await E2ee.decryptBackup(EncryptedBackup.fromRow(row), passphrase, userId: uid);
    final profile = await _loadProfile(uid);
    if (profile.xPublicKey != keys.xPublicKey || profile.edPublicKey != keys.edPublicKey) {
      // Backup and published keys disagree: re-publish the keys we can prove we own.
      await client
          .from('profiles')
          .update({'x25519_public_key': keys.xPublicKey, 'ed25519_public_key': keys.edPublicKey})
          .eq('id', uid);
    }
    await _storage.write(key: _storageKey(uid), value: keys.toJson());
    identity = keys;
    me = await _loadProfile(uid);
    _set(SessionStage.ready);
  }

  /// Re-encrypts the backup with a new passphrase (identity stays the same).
  Future<void> changePassphrase(String passphrase) async {
    final uid = _userId!;
    final backup = await E2ee.encryptBackup(identity!, passphrase, userId: uid);
    await client.from('key_backups').upsert(backup.toRow(uid));
  }

  Future<void> signOut() async {
    final uid = _userId;
    if (uid != null) await _storage.delete(key: _storageKey(uid));
    await client.auth.signOut();
  }

  @override
  void dispose() {
    _authSub.cancel();
    super.dispose();
  }
}
