import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../chat/gif_picker.dart';
import '../chat/message_bubble.dart';
import '../customize/skin_editor.dart';
import 'report_dialog.dart';
import 'upload_flows.dart';

final _gallerySkinsProvider = FutureProvider.autoDispose((ref) => ref.watch(communityProvider).gallerySkins());
final _galleryFontsProvider = FutureProvider.autoDispose((ref) => ref.watch(communityProvider).galleryFonts());
final _galleryGifsProvider = FutureProvider.autoDispose((ref) => ref.watch(communityProvider).gifs());
final _savedProvider = FutureProvider.autoDispose.family<Set<String>, String>(
  (ref, kind) => ref.watch(communityProvider).savedIds(kind),
);

/// Community gallery: everyone can publish and use skins, fonts and GIFs.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this)..addListener(() => setState(() {}));
  bool _busy = false;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (done != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish() async {
    switch (_tabs.index) {
      case 0:
        final skin = await Navigator.of(context)
            .push<MessageSkin>(MaterialPageRoute(builder: (_) => const SkinEditorScreen(publishByDefault: true)));
        if (skin != null) ref.invalidate(_gallerySkinsProvider);
      case 1:
        final font = await uploadFontFlow(context, ref, publishByDefault: true);
        if (font != null) ref.invalidate(_galleryFontsProvider);
      case 2:
        await _run(() async {
          final picked = await pickGifFile(context);
          if (picked == null || !mounted) return;
          final details = await askGifDetails(context);
          if (details == null) return;
          final (bytes, name, w, h) = picked;
          await ref
              .read(communityProvider)
              .uploadGif(bytes: bytes, filename: name, title: details.$1, isPublic: details.$2, width: w, height: h);
          ref.invalidate(_galleryGifsProvider);
        }, done: 'GIF uploaded');
    }
  }

  Future<void> _report(ReportTarget type, String id) async {
    final reason = await showReportDialog(context, title: 'Report ${type.name}');
    if (reason == null) return;
    await _run(() => ref.read(communityProvider).report(type, id, reason), done: 'Reported. Thanks!');
  }

  Future<void> _toggleSave(String kind, String id, bool saved) => _run(() async {
    final community = ref.read(communityProvider);
    saved ? await community.unsave(kind, id) : await community.save(kind, id);
    ref.invalidate(_savedProvider(kind));
    ref.invalidate(librarySkinsProvider);
    ref.invalidate(libraryFontsProvider);
  });

  Future<void> _use({String? skinId, String? fontId}) => _run(() async {
    final me = ref.read(appSessionProvider).me;
    final kind = skinId != null ? 'skin' : 'font';
    await ref.read(communityProvider).save(kind, (skinId ?? fontId)!);
    await ref.read(cosmeticsProvider).setActive(skinId: skinId ?? me?.activeSkinId, fontId: fontId ?? me?.activeFontId);
    ref.invalidate(_savedProvider(kind));
    ref.invalidate(librarySkinsProvider);
    ref.invalidate(libraryFontsProvider);
  }, done: 'Now used for your messages');

  Widget _skins() {
    final skins = ref.watch(_gallerySkinsProvider);
    final saved = ref.watch(_savedProvider('skin')).value ?? const {};
    final myId = ref.watch(appSessionProvider).userId;
    return skins.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(describeError(e))),
      data: (list) => list.isEmpty
          ? const Center(child: Text('No skins yet. Create the first one!'))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final e = list[i];
                final s = e.item;
                final isSaved = saved.contains(s.id);
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SkinPreview(skinId: s.id),
                        const SizedBox(height: 8),
                        Text(s.name, style: Theme.of(context).textTheme.titleMedium),
                        Text('by @${e.ownerUsername} · ${s.summary}', style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 4),
                        _Actions(
                          onUse: () => _use(skinId: s.id),
                          saved: isSaved,
                          onSave: s.ownerId == myId ? null : () => _toggleSave('skin', s.id, isSaved),
                          onReport: s.ownerId == myId ? null : () => _report(ReportTarget.skin, s.id),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _fonts() {
    final fonts = ref.watch(_galleryFontsProvider);
    final saved = ref.watch(_savedProvider('font')).value ?? const {};
    final myId = ref.watch(appSessionProvider).userId;
    return fonts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(describeError(e))),
      data: (list) => list.isEmpty
          ? const Center(child: Text('No fonts yet. Upload the first one!'))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final e = list[i];
                final f = e.item;
                final isSaved = saved.contains(f.id);
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FutureBuilder<String?>(
                          future: ref.read(cosmeticsProvider).loadFont(f.id),
                          builder: (context, snap) => Text(
                            'The quick brown fox jumps over the lazy dog',
                            style: TextStyle(fontFamily: snap.data, fontSize: 22),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(f.name, style: Theme.of(context).textTheme.titleMedium),
                        Text('by @${e.ownerUsername}', style: Theme.of(context).textTheme.bodySmall),
                        _Actions(
                          onUse: () => _use(fontId: f.id),
                          saved: isSaved,
                          onSave: f.ownerId == myId ? null : () => _toggleSave('font', f.id, isSaved),
                          onReport: f.ownerId == myId ? null : () => _report(ReportTarget.font, f.id),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _gifs() {
    final gifs = ref.watch(_galleryGifsProvider);
    final myId = ref.watch(appSessionProvider).userId;
    return gifs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(describeError(e))),
      data: (list) => list.isEmpty
          ? const Center(child: Text('No GIFs yet. Upload the first one!'))
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.85,
              ),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final g = list[i];
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: LibraryImage(bucket: 'gifs', path: g.path),
                      ),
                      ListTile(
                        dense: true,
                        title: Text(g.title ?? 'Untitled', maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('@${g.ownerUsername}', maxLines: 1),
                        trailing: g.ownerId == myId
                            ? null
                            : IconButton(
                                tooltip: 'Report',
                                icon: const Icon(Icons.flag_outlined),
                                onPressed: () => _report(ReportTarget.gif, g.id),
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = ['Create skin', 'Upload font', 'Upload GIF'];
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/customize')),
        title: const Text('Community gallery'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.format_paint_outlined), text: 'Skins'),
            Tab(icon: Icon(Icons.font_download_outlined), text: 'Fonts'),
            Tab(icon: Icon(Icons.gif_box_outlined), text: 'GIFs'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _publish,
        icon: const Icon(Icons.add),
        label: Text(labels[_tabs.index]),
      ),
      body: Narrow(
        child: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: TabBarView(controller: _tabs, children: [_skins(), _fonts(), _gifs()]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.onUse, required this.saved, this.onSave, this.onReport});
  final VoidCallback onUse;
  final bool saved;
  final VoidCallback? onSave;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      FilledButton.tonal(onPressed: onUse, child: const Text('Use')),
      if (onSave != null)
        TextButton.icon(
          onPressed: onSave,
          icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
          label: Text(saved ? 'Saved' : 'Save'),
        ),
      if (onReport != null) IconButton(tooltip: 'Report', icon: const Icon(Icons.flag_outlined), onPressed: onReport),
    ],
  );
}

class _SkinPreview extends ConsumerWidget {
  const _SkinPreview({required this.skinId});
  final String skinId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder(
    future: ref.read(cosmeticsProvider).loadSkin(skinId),
    builder: (context, snap) => Align(
      alignment: Alignment.centerLeft,
      child: SkinnedBubble(
        mine: true,
        style: ResolvedStyle(skin: snap.data),
        child: (t) => Text('Hey! This is how my messages look ✨', style: t),
      ),
    ),
  );
}
