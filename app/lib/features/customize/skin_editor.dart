import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../services/cosmetics_service.dart';
import '../chat/message_bubble.dart';

/// Create a skin: message background + message border + corner radius + text colour.
class SkinEditorScreen extends ConsumerStatefulWidget {
  const SkinEditorScreen({super.key});

  @override
  ConsumerState<SkinEditorScreen> createState() => _SkinEditorScreenState();
}

class _PickedImage {
  _PickedImage(this.image, this.ext);
  final SkinImage image;
  final String ext;
}

class _SkinEditorScreenState extends ConsumerState<SkinEditorScreen> {
  final _name = TextEditingController(text: 'My skin');
  bool _busy = false;

  // Background
  SkinBackground _bg = SkinBackground.gradient;
  Color _bgColor = const Color(0xFF6A11CB);
  Color _bgColor2 = const Color(0xFF2575FC);
  _PickedImage? _bgImage;
  SkinFit _bgFit = SkinFit.cover;
  final _slice = [16, 16, 16, 16]; // background 9-slice: left, top, right, bottom

  // Border
  SkinBorder _border = SkinBorder.solid;
  Color _borderColor = const Color(0xFFFFD54F);
  double _borderWidth = 2;
  double _radius = 18;
  _PickedImage? _borderImage;
  int _borderSlice = 16;

  Color _textColor = Colors.white;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<_PickedImage?> _pickImage() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    );
    if (file == null) return null;
    try {
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.length > CosmeticsService.maxSkinBytes) throw ArgumentError('Image must be at most 5 MB');
      return _PickedImage(await SkinImage.decode(bytes), (file.extension ?? 'png').replaceFirst('.', ''));
    } catch (e) {
      if (mounted) showError(context, e);
      return null;
    }
  }

  MessageSkin _skin({String id = 'preview'}) => MessageSkin(
    id: id,
    ownerId: '',
    name: _name.text.trim().isEmpty ? 'My skin' : _name.text.trim(),
    textColor: toHexColor(_textColor),
    background: _bg,
    bgColor: toHexColor(_bgColor),
    bgColor2: toHexColor(_bgColor2),
    bgFit: _bgFit,
    sliceLeft: _slice[0],
    sliceTop: _slice[1],
    sliceRight: _slice[2],
    sliceBottom: _slice[3],
    border: _border,
    borderColor: toHexColor(_borderColor),
    borderWidth: _borderWidth.round(),
    borderRadius: _radius.round(),
    borderSlice: _borderSlice,
  );

  LoadedSkin get _preview => LoadedSkin(skin: _skin(), background: _bgImage?.image, border: _borderImage?.image);

  String? get _problem {
    if (_bg == SkinBackground.image && _bgImage == null) return 'Choose a background image';
    if (_border == SkinBorder.image && _borderImage == null) return 'Choose a border image';
    return null;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final skin = await ref
          .read(cosmeticsProvider)
          .createSkin(
            SkinUpload(
              skin: _skin(id: ''),
              backgroundBytes: _bgImage?.image.bytes,
              backgroundExt: _bgImage?.ext,
              borderBytes: _borderImage?.image.bytes,
              borderExt: _borderImage?.ext,
            ),
          );
      if (mounted) Navigator.pop(context, skin);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = _problem;
    final preview = _preview;

    return Scaffold(
      appBar: AppBar(
        title: const Text('New skin'),
        actions: [TextButton(onPressed: problem != null || _busy ? null : _save, child: const Text('Save'))],
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      body: Narrow(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Live preview ------------------------------------------------------
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SkinnedBubble(
                    mine: true,
                    style: ResolvedStyle(skin: preview),
                    child: (t) => Text('Short one', style: t),
                  ),
                  const SizedBox(height: 8),
                  SkinnedBubble(
                    mine: true,
                    style: ResolvedStyle(skin: preview),
                    child: (t) => Text(
                      'A longer message to see how the background and border behave '
                      'when the bubble grows over several lines.',
                      style: t,
                    ),
                  ),
                  if (problem != null) ...[
                    const SizedBox(height: 8),
                    Text(problem, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              maxLength: 40,
              decoration: const InputDecoration(labelText: 'Skin name', border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),

            // Background --------------------------------------------------------
            _Section(
              title: 'Message background',
              children: [
                SegmentedButton<SkinBackground>(
                  segments: const [
                    ButtonSegment(value: SkinBackground.theme, label: Text('Theme')),
                    ButtonSegment(value: SkinBackground.color, label: Text('Colour')),
                    ButtonSegment(value: SkinBackground.gradient, label: Text('Gradient')),
                    ButtonSegment(value: SkinBackground.image, label: Text('Image')),
                  ],
                  selected: {_bg},
                  onSelectionChanged: (s) => setState(() => _bg = s.first),
                ),
                if (_bg == SkinBackground.color || _bg == SkinBackground.gradient)
                  ColorField(
                    label: _bg == SkinBackground.gradient ? 'Start colour' : 'Colour',
                    value: _bgColor,
                    onChanged: (c) => setState(() => _bgColor = c),
                  ),
                if (_bg == SkinBackground.gradient)
                  ColorField(label: 'End colour', value: _bgColor2, onChanged: (c) => setState(() => _bgColor2 = c)),
                if (_bg == SkinBackground.image) ...[
                  OutlinedButton.icon(
                    onPressed: () async {
                      final img = await _pickImage();
                      if (img != null) setState(() => _bgImage = img);
                    },
                    icon: const Icon(Icons.image_outlined),
                    label: Text(
                      _bgImage == null
                          ? 'Choose background image / texture'
                          : 'Change image (${_bgImage!.image.width}×${_bgImage!.image.height} px)',
                    ),
                  ),
                  SegmentedButton<SkinFit>(
                    segments: const [
                      ButtonSegment(value: SkinFit.cover, label: Text('Cover')),
                      ButtonSegment(value: SkinFit.tile, label: Text('Tile')),
                      ButtonSegment(value: SkinFit.stretch, label: Text('Stretch')),
                      ButtonSegment(value: SkinFit.nineSlice, label: Text('9-slice')),
                    ],
                    selected: {_bgFit},
                    onSelectionChanged: (s) => setState(() => _bgFit = s.first),
                  ),
                  if (_bgFit == SkinFit.nineSlice)
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
              ],
            ),

            // Border ------------------------------------------------------------
            _Section(
              title: 'Message border',
              children: [
                SegmentedButton<SkinBorder>(
                  segments: const [
                    ButtonSegment(value: SkinBorder.none, label: Text('None')),
                    ButtonSegment(value: SkinBorder.solid, label: Text('Line')),
                    ButtonSegment(value: SkinBorder.image, label: Text('Image frame')),
                  ],
                  selected: {_border},
                  onSelectionChanged: (s) => setState(() {
                    _border = s.first;
                    // Frames need more room than a thin line.
                    if (_border == SkinBorder.image && _borderWidth < 8) _borderWidth = 10;
                    if (_border == SkinBorder.solid && _borderWidth > 8) _borderWidth = 2;
                  }),
                ),
                if (_border == SkinBorder.solid)
                  ColorField(
                    label: 'Border colour',
                    value: _borderColor,
                    onChanged: (c) => setState(() => _borderColor = c),
                  ),
                if (_border == SkinBorder.image) ...[
                  const Text(
                    'Use an image of a frame (e.g. a PNG with a transparent centre). Its corners keep '
                    'their shape and its edges stretch around the message.',
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final img = await _pickImage();
                      if (img == null) return;
                      setState(() {
                        _borderImage = img;
                        final maxSlice = (img.image.width < img.image.height ? img.image.width : img.image.height) ~/ 2;
                        _borderSlice = (maxSlice ~/ 3).clamp(1, maxSlice < 1 ? 1 : maxSlice);
                      });
                    },
                    icon: const Icon(Icons.crop_free),
                    label: Text(
                      _borderImage == null
                          ? 'Choose border frame image'
                          : 'Change frame (${_borderImage!.image.width}×${_borderImage!.image.height} px)',
                    ),
                  ),
                  if (_borderImage != null)
                    _SliderRow(
                      label: 'Frame size in image',
                      value: _borderSlice.toDouble(),
                      min: 1,
                      max:
                          ((_borderImage!.image.width < _borderImage!.image.height
                                          ? _borderImage!.image.width
                                          : _borderImage!.image.height) /
                                      2 -
                                  1)
                              .clamp(1, 1024)
                              .toDouble(),
                      suffix: 'px',
                      onChanged: (v) => setState(() => _borderSlice = v.round()),
                    ),
                ],
                if (_border != SkinBorder.none)
                  _SliderRow(
                    label: _border == SkinBorder.image ? 'Frame thickness' : 'Border width',
                    value: _borderWidth,
                    min: 1,
                    max: 24,
                    suffix: 'px',
                    onChanged: (v) => setState(() => _borderWidth = v),
                  ),
                _SliderRow(
                  label: 'Corner radius',
                  value: _radius,
                  min: 0,
                  max: 40,
                  suffix: 'px',
                  onChanged: (v) => setState(() => _radius = v),
                ),
              ],
            ),

            // Text --------------------------------------------------------------
            _Section(
              title: 'Text',
              children: [
                ColorField(label: 'Text colour', value: _textColor, onChanged: (c) => setState(() => _textColor = c)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 10), child: c),
      ],
    ),
  );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.suffix = '',
  });
  final String label;
  final double value, min, max;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 150, child: Text(label)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: (max - min).round().clamp(1, 1000),
          onChanged: onChanged,
        ),
      ),
      SizedBox(width: 56, child: Text('${value.round()} $suffix')),
    ],
  );
}

/// Colour picker: preset swatches + hex input.
class ColorField extends StatelessWidget {
  const ColorField({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final Color value;
  final ValueChanged<Color> onChanged;

  static const palette = [
    Colors.white,
    Colors.black,
    Color(0xFF6A11CB),
    Color(0xFF2575FC),
    Color(0xFF00C9A7),
    Color(0xFFFFD54F),
    Color(0xFFFF8A80),
    Color(0xFFE91E63),
    Color(0xFF795548),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hex = toHexColor(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final c in palette)
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () => onChanged(c),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: toHexColor(c) == hex ? scheme.primary : scheme.outline,
                      width: toHexColor(c) == hex ? 3 : 1,
                    ),
                  ),
                ),
              ),
            SizedBox(
              width: 120,
              child: TextFormField(
                key: ValueKey(hex),
                initialValue: hex,
                decoration: const InputDecoration(labelText: 'Hex', isDense: true, border: OutlineInputBorder()),
                onFieldSubmitted: (v) {
                  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(v.trim());
                  if (m != null) onChanged(parseHexColor('#${m[1]}'));
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
