import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';

/// Moderator tools. Actions go through the `moderate` Edge Function, which checks
/// that the caller is a moderator and deletes banned files from storage.
class ModerationService {
  ModerationService(this.client);
  final SupabaseClient client;

  Future<bool> isModerator() async => (await client.rpc('is_moderator')) as bool;

  Future<List<Report>> openReports() async {
    final rows = await client.from('reports').select().eq('status', 'open').order('created_at', ascending: true);
    return [for (final r in rows) Report.fromRow(r)];
  }

  Future<List<MediaAsset>> recentUploads({int limit = 60}) async {
    final rows = await client
        .from('media_assets')
        .select()
        .neq('kind', 'evidence')
        .isFilter('banned_at', null)
        .order('created_at', ascending: false)
        .limit(limit);
    return [for (final r in rows) MediaAsset.fromRow(r)];
  }

  Future<List<BannedHash>> bannedHashes() async {
    final rows = await client.from('banned_hashes').select().order('created_at', ascending: false);
    return [for (final r in rows) BannedHash.fromRow(r)];
  }

  Future<MediaAsset?> asset(String id) async {
    final row = await client.from('media_assets').select().eq('id', id).maybeSingle();
    return row == null ? null : MediaAsset.fromRow(row);
  }

  Future<List<MediaAsset>> assetsByPath(Iterable<String> paths) async {
    if (paths.isEmpty) return [];
    final rows = await client.from('media_assets').select().inFilter('path', paths.toList());
    return [for (final r in rows) MediaAsset.fromRow(r)];
  }

  Future<String> usernameOf(String userId) async {
    final row = await client.from('profiles').select('username').eq('id', userId).maybeSingle();
    return (row?['username'] as String?) ?? 'deleted user';
  }

  Future<Map<String, dynamic>> _act(Map<String, dynamic> body) async {
    final res = await client.functions.invoke('moderate', body: body);
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Bans the file's hash everywhere. Returns how many stored copies were deleted.
  Future<int> banAsset(String assetId, String reason) async =>
      ((await _act({'action': 'ban_asset', 'asset_id': assetId, 'reason': reason}))['deleted_files'] as num).toInt();

  Future<void> unban(String sha256) => _act({'action': 'unban', 'sha256': sha256});

  Future<void> unpublish(ReportTarget type, String id) =>
      _act({'action': 'unpublish', 'target_type': type.name, 'target_id': id});

  Future<void> dismiss(String reportId) => _act({'action': 'dismiss', 'report_id': reportId});
}
