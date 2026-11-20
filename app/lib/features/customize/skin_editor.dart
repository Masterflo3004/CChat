import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../services/cosmetics_service.dart';
import '../chat/message_bubble.dart';

/// Create a skin: pick an image, choose how it fills the bubble and the text colour.
class SkinEditorScreen extends ConsumerStatefulWidget {
  const SkinEditorScreen({super.key});

  @override
  ConsumerState<SkinEditorScreen> createState() => _SkinEditorScreenState();
}

class _SkinEditorScreenState extends ConsumerState<SkinEditorScreen> {
  final _name = TextEditingController(text: 'My skin');
  Uint8List? _bytes;
  String? _ext;
  int _w = 0, _h = 0;
  SkinFit _fit = SkinFit.cover;
  Color _textColor = Colors.white;
  final _slice = [16, 16, 16, 16]; // left, top, right, bottom
  bool _busy = false;

  static const _palette = [
    Colors.white,
    Colors.black,
    Color(0xFFFFD54F),
    Color(0xFFFF8A80),
    Color(0xFF80D8FF),
    Color(0xFFB9F6CA),
    Color(0xFFEA80FC),
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _hex => '#${(_textColor.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  Future<void> _pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    );
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > CosmeticsService.maxSkinBytes) throw ArgumentError('Image must be at most 5 MB');
      final (w, h) = await CosmeticsService.imageSize(bytes);
      setState(() {
        _bytes = bytes;
        _ext = (file.extension ?? 'png').replaceFirst('.', '');
        _w = w;
        _h = h;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _save() async {
    if (_bytes == null) return;
    setState(() => _busy = true);
    try {
      final skin = await ref
          .read(cosmeticsProvider)
          .createSkin(
            name: _name.text.trim().isEmpty ? 'My skin' : _name.text.trim(),
            bytes: _bytes!,
            extension: _ext!,
            fit: _fit,
            textColor: _hex,
            sliceLeft: _slice[0],
            sliceTop: _slice[1],
            sliceRight: _slice[2],
            sliceBottom: _slice[3],
          );
      if (mounted) Navigator.pop(context, skin);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  LoadedSkin? get _previewSkin => _bytes == null
      ? null
      : LoadedSkin(
          skin: MessageSkin(
            id: 'preview',
            ownerId: '',
            name: _name.text,
            imagePath: '',
            fit: _fit,
            sliceLeft: _slice[0],
            sliceTop: _slice[1],
            sliceRight: _slice[2],
            sliceBottom: _slice[3],
            textColor: _hex,
          ),
          image: MemoryImage(_bytes!),
          width: _w,
          height: _h,
        );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('New skin'),
        actions: [TextButton(onPressed: _bytes == null || _busy ? null : _save, child: const Text('Save'))],
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      body: Narrow(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SkinnedBubble(
                    mine: true,
                    style: ResolvedStyle(skin: _previewSkin),
                    child: (t) => Text('Short one', style: t),
                  ),
                  const SizedBox(height: 8),
                  SkinnedBubble(
                    mine: true,
                    style: ResolvedStyle(skin: _previewSkin),
                    child: (t) => Text(
                      'A longer message to see how the texture behaves when the bubble grows '
                      'over several lines of text.',
                      style: t,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.image_outlined),
              label: Text(_bytes == null ? 'Choose image / texture' : 'Change image ($_w×$_h px)'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              maxLength: 40,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text('How the image fills the bubble', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<SkinFit>(
              segments: const [
                ButtonSegment(value: SkinFit.cover, label: Text('Cover')),
                ButtonSegment(value: SkinFit.tile, label: Text('Tile')),
                ButtonSegment(value: SkinFit.stretch, label: Text('Stretch')),
                ButtonSegment(value: SkinFit.nineSlice, label: Text('9-slice')),
              ],
              selected: {_fit},
              onSelectionChanged: (s) => setState(() => _fit = s.first),
            ),
            if (_fit == SkinFit.nineSlice) ...[
              const SizedBox(height: 8),
              const Text(
                '9-slice keeps the corners/borders of the image intact and only stretches '
                'the middle. Set the border sizes in image pixels.',
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final (i, label) in const ['Left', 'Top', 'Right', 'Bottom'].indexed)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: TextFormField(
                          initialValue: '${_slice[i]}',
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
                          onChanged: (v) => setState(() => _slice[i] = (int.tryParse(v) ?? 0).clamp(0, 4096)),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text('Text colour', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _palette)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _textColor = c),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == _textColor ? theme.colorScheme.primary : theme.colorScheme.outline,
                          width: c == _textColor ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
                SizedBox(
                  width: 120,
                  child: TextFormField(
                    key: ValueKey(_hex),
                    initialValue: _hex,
                    decoration: const InputDecoration(labelText: 'Hex', isDense: true, border: OutlineInputBorder()),
                    onFieldSubmitted: (v) {
                      final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(v.trim());
                      if (m != null) setState(() => _textColor = Color(int.parse('FF${m[1]}', radix: 16)));
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
