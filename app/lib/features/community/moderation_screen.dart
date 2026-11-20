import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../chat/gif_picker.dart';
import '../chat/message_bubble.dart';

final _reportsProvider = FutureProvider.autoDispose((ref) => ref.watch(moderationProvider).openReports());
final _recentProvider = FutureProvider.autoDispose((ref) => ref.watch(moderationProvider).recentUploads());
final _bannedProvider = FutureProvider.autoDispose((ref) => ref.watch(moderationProvider).bannedHashes());

/// Moderator tools: open reports, recent uploads, banned hashes.
class ModerationScreen extends ConsumerStatefulWidget {
  const ModerationScreen({super.key});

  @override
  ConsumerState<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends ConsumerState<ModerationScreen> {
  bool _busy = false;

  void _refresh() {
    ref.invalidate(_reportsProvider);
    ref.invalidate(_recentProvider);
    ref.invalidate(_bannedProvider);
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _busy = true);
    try {
      final msg = await action();
      _refresh();
      if (msg != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> ban(MediaAsset asset, {String reason = ''}) async {
    final controller = TextEditingController(text: reason);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ban this file?'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Its SHA-256 goes on the ban list. Every stored copy is deleted, everything using it '
                'is removed from the gallery, and nobody can upload the same file again. '
                'Encrypted chats hide it too.',
              ),
              const SizedBox(height: 8),
              SelectableText('SHA-256: ${asset.sha256}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ban'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final n = await ref.read(moderationProvider).banAsset(asset.id, controller.text.trim());
      return 'Banned. $n stored ${n == 1 ? 'copy' : 'copies'} deleted.';
    });
  }

  Future<void> unpublish(ReportTarget type, String id) => _run(() async {
    await ref.read(moderationProvider).unpublish(type, id);
    return 'Removed from the gallery';
  });

  Future<void> dismiss(Report r) => _run(() async {
    await ref.read(moderationProvider).dismiss(r.id);
    return 'Report dismissed';
  });

  Future<void> unban(BannedHash b) => _run(() async {
    await ref.read(moderationProvider).unban(b.sha256);
    return 'Unbanned';
  });

  @override
  Widget build(BuildContext context) {
    final isMod = ref.watch(isModeratorProvider);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => context.go('/customize')),
          title: const Text('Moderation'),
          actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh)],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Reports'),
              Tab(text: 'Recent uploads'),
              Tab(text: 'Banned'),
            ],
          ),
        ),
        body: isMod.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(describeError(e))),
          data: (ok) => !ok
              ? const Center(child: Text('Only moderators can see this page.'))
              : Narrow(
                  maxWidth: 900,
                  child: Column(
                    children: [
                      if (_busy) const LinearProgressIndicator(),
                      Expanded(child: TabBarView(children: [_reports(), _recent(), _banned()])),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _reports() => ref
      .watch(_reportsProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(describeError(e))),
        data: (list) => list.isEmpty
            ? const Center(child: Text('No open reports 🎉'))
            : ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: list.length,
                itemBuilder: (context, i) => _ReportCard(report: list[i], screen: this),
              ),
      );

  Widget _recent() => ref
      .watch(_recentProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(describeError(e))),
        data: (list) => list.isEmpty
            ? const Center(child: Text('No uploads yet'))
            : GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.8,
                ),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final a = list[i];
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: AssetPreview(asset: a)),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                          child: FutureBuilder(
                            future: ref.read(moderationProvider).usernameOf(a.ownerId),
                            builder: (context, snap) => Text(
                              '${a.kind} · @${snap.data ?? '…'}\n${formatTime(a.createdAt)} · ${(a.sizeBytes / 1024).ceil()} KB',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _busy ? null : () => ban(a),
                          icon: const Icon(Icons.block),
                          label: const Text('Ban'),
                        ),
                      ],
                    ),
                  );
                },
              ),
      );

  Widget _banned() => ref
      .watch(_bannedProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(describeError(e))),
        data: (list) => list.isEmpty
            ? const Center(child: Text('Nothing banned'))
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final b = list[i];
                  return ListTile(
                    leading: const Icon(Icons.block),
                    title: Text(
                      '${b.sha256.substring(0, 16)}…  (${b.kind ?? 'file'})',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: Text(
                      '${b.reason?.isNotEmpty == true ? b.reason : 'No reason'} · ${formatTime(b.createdAt)}',
                    ),
                    onLongPress: () => Clipboard.setData(ClipboardData(text: b.sha256)),
                    trailing: TextButton(onPressed: _busy ? null : () => unban(b), child: const Text('Unban')),
                  );
                },
              ),
      );
}

/// Preview of any media asset (image, GIF, evidence, font).
class AssetPreview extends ConsumerWidget {
  const AssetPreview({super.key, required this.asset});
  final MediaAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (asset.kind == 'font') {
      return FutureBuilder<String?>(
        future: () async {
          final bytes = await ref.read(mediaProvider).download('fonts', asset.path);
          final family = 'mod_${asset.sha256.substring(0, 16)}';
          final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
          return family;
        }(),
        builder: (context, snap) => Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              snap.hasError ? 'Font could not be loaded' : 'Aa Bb Cc 123',
              style: TextStyle(fontFamily: snap.data, fontSize: 26),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: LibraryImage(bucket: asset.bucket, path: asset.path, fit: BoxFit.contain),
    );
  }
}

class _ReportCard extends ConsumerWidget {
  const _ReportCard({required this.report, required this.screen});
  final Report report;
  final _ModerationScreenState screen;

  Future<(List<MediaAsset>, Widget?)> _load(WidgetRef ref) async {
    final mod = ref.read(moderationProvider);
    final client = ref.read(supabaseProvider);
    final id = report.targetId;
    switch (report.targetType) {
      case ReportTarget.attachment:
        final a = report.evidenceAssetId == null ? null : await mod.asset(report.evidenceAssetId!);
        return (<MediaAsset>[?a], null);
      case ReportTarget.gif:
        final row = await client.from('gifs').select('asset_id, title').eq('id', id!).maybeSingle();
        final a = row == null ? null : await mod.asset(row['asset_id'] as String);
        return (<MediaAsset>[?a], row == null ? null : Text('“${row['title'] ?? 'Untitled'}”'));
      case ReportTarget.skin:
        final row = await client.from('message_skins').select().eq('id', id!).maybeSingle();
        if (row == null) return (<MediaAsset>[], const Text('Skin was deleted'));
        final skin = MessageSkin.fromRow(row);
        final assets = await mod.assetsByPath([?skin.bgImagePath, ?skin.borderImagePath]);
        final loaded = await ref.read(cosmeticsProvider).loadSkin(skin.id);
        return (
          assets,
          SkinnedBubble(
            mine: true,
            style: ResolvedStyle(skin: loaded),
            child: (t) => Text('${skin.name} (${skin.summary})', style: t),
          ),
        );
      case ReportTarget.font:
        final row = await client.from('user_fonts').select().eq('id', id!).maybeSingle();
        if (row == null) return (<MediaAsset>[], const Text('Font was deleted'));
        final font = UserFont.fromRow(row);
        return (await mod.assetsByPath([font.filePath]), Text('Font “${font.name}”'));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FutureBuilder(
          future: _load(ref),
          builder: (context, snap) {
            final (assets, header) = snap.data ?? (<MediaAsset>[], null);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Chip(label: Text(report.targetType.name)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FutureBuilder(
                        future: ref.read(moderationProvider).usernameOf(report.reporterId),
                        builder: (context, s) => Text(
                          'Reported by @${s.data ?? '…'} · ${formatTime(report.createdAt)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                ),
                Text('“${report.reason}”', style: theme.textTheme.bodyLarge),
                if (report.targetType == ReportTarget.attachment)
                  Text(
                    'Decrypted copy of an end-to-end encrypted GIF, shared by the reporter.',
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                if (!snap.hasData && !snap.hasError) const LinearProgressIndicator(),
                if (snap.hasError) Text(describeError(snap.error!)),
                ?header,
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final a in assets)
                      SizedBox(
                        width: 180,
                        child: Column(
                          children: [
                            SizedBox(height: 120, child: AssetPreview(asset: a)),
                            TextButton.icon(
                              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                              onPressed: () => screen.ban(a, reason: report.reason),
                              icon: const Icon(Icons.block),
                              label: Text('Ban ${a.kind == 'font' ? 'font file' : 'image'}'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const Divider(),
                Wrap(
                  spacing: 8,
                  children: [
                    if (report.targetId != null)
                      OutlinedButton(
                        onPressed: () => screen.unpublish(report.targetType, report.targetId!),
                        child: const Text('Remove from gallery'),
                      ),
                    TextButton(onPressed: () => screen.dismiss(report), child: const Text('Dismiss')),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
