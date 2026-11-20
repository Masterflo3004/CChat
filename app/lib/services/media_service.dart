import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';

/// Thrown when a file's hash is on the moderators' ban list.
class BannedFileException implements Exception {
  @override
  String toString() => 'This file has been banned by the moderators.';
}

/// Uploads through the `upload-media` Edge Function (server-side SHA-256 + ban check)
/// and downloads with an in-memory cache.
class MediaService {
  MediaService(this.client);
  final SupabaseClient client;

  final _bytes = <String, Future<Uint8List>>{};
  final _banned = <String, (bool, DateTime)>{};
  static const _banCacheTtl = Duration(minutes: 10);

  static Future<String> sha256Hex(List<int> bytes) async {
    final hash = await Sha256().hash(bytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// [kind] is gif | image | font | evidence.
  Future<MediaAsset> upload({
    required String kind,
    required Uint8List bytes,
    required String filename,
    int? width,
    int? height,
  }) async {
    try {
      final res = await client.functions.invoke(
        'upload-media',
        body: {'kind': kind, 'width': ?width?.toString(), 'height': ?height?.toString()},
        files: [http.MultipartFile.fromBytes('file', bytes, filename: filename)],
      );
      return MediaAsset.fromRow(Map<String, dynamic>.from(res.data as Map));
    } on FunctionException catch (e) {
      final details = e.details;
      if (details is Map && details['code'] == 'banned') throw BannedFileException();
      if (details is Map && details['error'] is String) throw ArgumentError(details['error'] as String);
      rethrow;
    }
  }

  /// Which of [hashes] are banned. Used for end-to-end encrypted attachments (which
  /// the server can't check) and as a second line of defence for cached downloads.
  Future<Set<String>> bannedAmong(Iterable<String> hashes) async {
    final now = DateTime.now();
    final unknown = hashes.where((h) {
      final cached = _banned[h];
      return cached == null || now.difference(cached.$2) > _banCacheTtl;
    }).toSet();
    if (unknown.isNotEmpty) {
      final rows = await client.rpc('banned_among', params: {'p_hashes': unknown.toList()}) as List;
      final banned = {for (final r in rows) r as String};
      for (final h in unknown) {
        _banned[h] = (banned.contains(h), now);
      }
    }
    return {
      for (final h in hashes)
        if (_banned[h]?.$1 == true) h,
    };
  }

  Future<bool> isBanned(List<int> bytes) async {
    final h = await sha256Hex(bytes);
    return (await bannedAmong([h])).isNotEmpty;
  }

  /// Downloads a public media file and refuses it if its hash is banned (e.g. an
  /// HTTP-cached copy of a file the moderators have since deleted).
  Future<Uint8List> download(String bucket, String path) {
    final key = '$bucket/$path';
    return _bytes[key] ??=
        () async {
          final bytes = await client.storage.from(bucket).download(path);
          if (bucket != 'evidence' && await isBanned(bytes)) throw BannedFileException();
          return bytes;
        }()..catchError((Object _) {
          _bytes.remove(key);
          return Uint8List(0);
        });
  }

  void forget(String bucket, String path) => _bytes.remove('$bucket/$path');
}
