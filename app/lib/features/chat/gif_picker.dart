import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../services/chat_service.dart';
import '../../services/cosmetics_service.dart';
import '../../services/gif_service.dart';
import '../../services/media_service.dart';

/// Bottom sheet to pick a GIF: community library, your own GIFs, GIPHY search,
/// upload a new one to the library, or send a file privately (encrypted).
Future<GifContent?> showGifPicker(BuildContext context, String conversationId) {
  return showModalBottomSheet<GifContent>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: _GifPicker(conversationId: conversationId)),
  );
}

/// Picks a GIF/WebP file. Returns bytes, file name and size.
Future<(Uint8List, String, int, int)?> pickGifFile(BuildContext context) async {
  final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['gif', 'webp']);
  if (file == null) return null;
  final size = await file.length();
  if (size != null && size > ChatService.maxAttachmentBytes) throw ArgumentError('File is larger than 8 MB');
  final bytes = await file.readAsBytes();
  final (w, h) = await CosmeticsService.imageSize(bytes);
  return (bytes, file.name, w, h);
}

/// Dialog for title + "show in community gallery". Returns null if cancelled.
Future<(String, bool)?> askGifDetails(BuildContext context) {
  final title = TextEditingController();
  var isPublic = true;
  return showDialog<(String, bool)>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Upload GIF'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Title (helps others find it)',
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: isPublic,
                onChanged: (v) => setState(() => isPublic = v),
                title: const Text('Show in the community gallery'),
                subtitle: const Text('Off: only in your GIFs (still visible to people you send it to)'),
              ),
              const Text(
                'Uploaded GIFs are not end-to-end encrypted and are checked against '
                'the moderators’ ban list.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, (title.text, isPublic)), child: const Text('Upload')),
        ],
      ),
    ),
  );
}

class _GifPicker extends ConsumerStatefulWidget {
  const _GifPicker({required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<_GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends ConsumerState<_GifPicker> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this);
  final _query = TextEditingController();
  Timer? _debounce;
  bool _busy = false;

  List<GifItem> _community = [];
  List<GifItem> _mine = [];
  List<GifResult> _giphy = [];
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final q = _query.text.trim();
    final tab = _tabs.index;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final community = ref.read(communityProvider);
      switch (tab) {
        case 0:
          final r = await community.gifs(query: q);
          if (mounted) setState(() => _community = r);
        case 1:
          final r = await community.gifs(mine: true, query: q);
          if (mounted) setState(() => _mine = r);
        case 2:
          final r = await ref.read(gifServiceProvider).search(q);
          if (mounted) setState(() => _giphy = r);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = tab == 2 ? 'GIPHY search unavailable (${describeError(e)})' : describeError(e));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<GifContent?> Function() action) async {
    setState(() => _busy = true);
    try {
      final gif = await action();
      if (gif != null && mounted) Navigator.pop(context, gif);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Upload to the GIF library (hash-checked by the server), then send it.
  Future<GifContent?> _uploadToLibrary() async {
    final picked = await pickGifFile(context);
    if (picked == null || !mounted) return null;
    final details = await askGifDetails(context);
    if (details == null) return null;
    final (bytes, name, w, h) = picked;
    final item = await ref
        .read(communityProvider)
        .uploadGif(bytes: bytes, filename: name, title: details.$1, isPublic: details.$2, width: w, height: h);
    return item.toContent();
  }

  /// Send a file only to this chat, end-to-end encrypted. Checked against the ban
  /// list on this device, since the server can't see it.
  Future<GifContent?> _sendPrivately() async {
    final picked = await pickGifFile(context);
    if (picked == null) return null;
    final (bytes, _, w, h) = picked;
    if (await ref.read(mediaProvider).isBanned(bytes)) throw BannedFileException();
    final up = await ref.read(chatServiceProvider).uploadEncrypted(widget.conversationId, bytes);
    return GifContent.file(path: up.path, fileKey: up.key, width: w, height: h);
  }

  Widget _libraryGrid(List<GifItem> items, {required bool mine}) {
    if (items.isEmpty && !_loading) {
      return Center(child: Text(mine ? 'You haven’t uploaded any GIFs yet.' : 'No GIFs found. Upload the first one!'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final g = items[i];
        return Tooltip(
          message: [if (g.title != null) g.title!, 'by @${g.ownerUsername}', if (!g.isPublic) '(unlisted)'].join(' '),
          child: InkWell(
            onTap: () => Navigator.pop(context, g.toContent()),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LibraryImage(bucket: 'gifs', path: g.path),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            controller: _query,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search GIFs',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 350), _load);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _run(_uploadToLibrary),
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Upload GIF'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(_sendPrivately),
                icon: const Icon(Icons.lock_outline),
                label: const Text('Send privately (encrypted)'),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Community'),
            Tab(text: 'My GIFs'),
            Tab(text: 'GIPHY'),
          ],
        ),
        if (_loading || _busy) const LinearProgressIndicator(),
        if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _libraryGrid(_community, mine: false),
              _libraryGrid(_mine, mine: true),
              GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemCount: _giphy.length,
                itemBuilder: (context, i) {
                  final g = _giphy[i];
                  return InkWell(
                    onTap: () => Navigator.pop(
                      context,
                      GifContent.remote(url: g.url, width: g.width, height: g.height, title: g.title),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        g.previewUrl,
                        fit: BoxFit.cover,
                        semanticLabel: g.title,
                        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// An image from a Supabase bucket (cached).
class LibraryImage extends ConsumerWidget {
  const LibraryImage({super.key, required this.bucket, required this.path, this.fit = BoxFit.cover});
  final String bucket;
  final String path;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<Uint8List>(
    future: ref.read(mediaProvider).download(bucket, path),
    builder: (context, snap) {
      if (snap.hasError) return const Center(child: Icon(Icons.hide_image_outlined));
      if (!snap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      return Image.memory(snap.data!, fit: fit, gaplessPlayback: true);
    },
  );
}
