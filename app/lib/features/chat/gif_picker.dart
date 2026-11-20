import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../services/chat_service.dart';
import '../../services/cosmetics_service.dart';
import '../../services/gif_service.dart';

/// Bottom sheet: search GIFs or upload your own (uploaded GIFs are encrypted).
/// Returns the chosen [GifContent], or null.
Future<GifContent?> showGifPicker(BuildContext context, String conversationId) {
  return showModalBottomSheet<GifContent>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(heightFactor: 0.8, child: _GifPicker(conversationId: conversationId)),
  );
}

class _GifPicker extends ConsumerStatefulWidget {
  const _GifPicker({required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<_GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends ConsumerState<_GifPicker> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<GifResult> _results = [];
  bool _loading = false;
  bool _uploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref.read(gifServiceProvider).search(q);
      if (mounted && q == _query.text) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = 'GIF search unavailable (${describeError(e)})');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _upload() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['gif', 'webp', 'png', 'jpg', 'jpeg'],
    );
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final size = await file.length();
      if (size != null && size > ChatService.maxAttachmentBytes) {
        throw ArgumentError('File is larger than 8 MB');
      }
      final bytes = await file.readAsBytes();
      final (w, h) = await CosmeticsService.imageSize(bytes);
      final up = await ref.read(chatServiceProvider).uploadEncrypted(widget.conversationId, bytes);
      if (mounted) {
        Navigator.pop(context, GifContent.file(path: up.path, fileKey: up.key, width: w, height: h));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search GIFs',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (q) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 350), () => _search(q));
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _uploading ? null : _upload,
                icon: _uploading
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_file),
                label: const Text('Upload'),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'Uploaded GIFs are end-to-end encrypted. Search results load from the GIF provider.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: _results.length,
            itemBuilder: (context, i) {
              final g = _results[i];
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
        ),
      ],
    );
  }
}
