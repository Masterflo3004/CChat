import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../chat/message_bubble.dart';
import 'skin_editor.dart';

/// Pick your message skin & font, manage uploads, see your safety number.
class CustomizeScreen extends ConsumerStatefulWidget {
  const CustomizeScreen({super.key});

  @override
  ConsumerState<CustomizeScreen> createState() => _CustomizeScreenState();
}

class _CustomizeScreenState extends ConsumerState<CustomizeScreen> {
  bool _busy = false;
  ResolvedStyle _preview = const ResolvedStyle();

  @override
  void initState() {
    super.initState();
    _refreshPreview();
  }

  Future<void> _refreshPreview() async {
    final style = ref.read(cosmeticsProvider).activeStyle;
    final resolved = await resolveStyle(ref, style);
    if (mounted) setState(() => _preview = resolved);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setActive({String? skinId, String? fontId, bool clearSkin = false, bool clearFont = false}) =>
      _run(() async {
        final me = ref.read(appSessionProvider).me;
        await ref
            .read(cosmeticsProvider)
            .setActive(
              skinId: clearSkin ? null : (skinId ?? me?.activeSkinId),
              fontId: clearFont ? null : (fontId ?? me?.activeFontId),
            );
        await _refreshPreview();
      });

  Future<void> _addSkin() async {
    final created = await Navigator.of(context)
        .push<MessageSkin>(MaterialPageRoute(builder: (_) => const SkinEditorScreen()));
    if (created == null) return;
    ref.invalidate(mySkinsProvider);
    await _setActive(skinId: created.id);
  }

  Future<void> _addFont() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['ttf', 'otf']);
    if (file == null) return;
    await _run(() async {
      final bytes = await file.readAsBytes();
      final ext = (file.extension ?? '').replaceFirst('.', '');
      final name = file.name.replaceAll(RegExp(r'\.(ttf|otf)$', caseSensitive: false), '');
      final font = await ref
          .read(cosmeticsProvider)
          .uploadFont(
            name: name.isEmpty ? 'My font' : (name.length > 40 ? name.substring(0, 40) : name),
            bytes: bytes,
            extension: ext,
          );
      ref.invalidate(myFontsProvider);
      final me = ref.read(appSessionProvider).me;
      await ref.read(cosmeticsProvider).setActive(skinId: me?.activeSkinId, fontId: font.id);
      await _refreshPreview();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appSessionProvider);
    final skins = ref.watch(mySkinsProvider);
    final fonts = ref.watch(myFontsProvider);
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final me = session.me;
        return Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: () => context.go('/')),
            title: const Text('Customize'),
            bottom: _busy
                ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
                : null,
          ),
          body: Narrow(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                // Preview -----------------------------------------------------------
                Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Preview', style: theme.textTheme.labelMedium),
                      const SizedBox(height: 8),
                      SkinnedBubble(
                        mine: true,
                        style: _preview,
                        child: (t) => Text('The quick brown fox jumps over the lazy dog 🦊', style: t),
                      ),
                    ],
                  ),
                ),

                // Skins --------------------------------------------------------------
                _Header(title: 'Message skins', action: 'Add skin', onAction: _busy ? null : _addSkin),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'A skin is the background and border of every message you send. '
                    'Everyone in the chat sees it.',
                  ),
                ),
                RadioGroup<String?>(
                  groupValue: me?.activeSkinId,
                  onChanged: (id) => id == null ? _setActive(clearSkin: true) : _setActive(skinId: id),
                  child: Column(
                    children: [
                      const RadioListTile<String?>(value: null, title: Text('Default (theme colour)')),
                      ...skins.when(
                        loading: () => [const LinearProgressIndicator()],
                        error: (e, _) => [ListTile(title: Text(describeError(e)))],
                        data: (list) => [
                          for (final s in list)
                            RadioListTile<String?>(
                              value: s.id,
                              title: Row(
                                children: [
                                  _SkinChip(skinId: s.id),
                                  const SizedBox(width: 12),
                                  Flexible(child: Text(s.name, overflow: TextOverflow.ellipsis)),
                                ],
                              ),
                              subtitle: Text(s.summary),
                              secondary: IconButton(
                                tooltip: 'Delete skin',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: _busy
                                    ? null
                                    : () => _run(() async {
                                        await ref.read(cosmeticsProvider).deleteSkin(s);
                                        ref.invalidate(mySkinsProvider);
                                        await session.reloadProfile();
                                        await _refreshPreview();
                                      }),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Fonts --------------------------------------------------------------
                _Header(title: 'Fonts', action: 'Upload font', onAction: _busy ? null : _addFont),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Upload a .ttf or .otf file (max 2 MB). Make sure you are allowed to share it.'),
                ),
                RadioGroup<String?>(
                  groupValue: me?.activeFontId,
                  onChanged: (id) => id == null ? _setActive(clearFont: true) : _setActive(fontId: id),
                  child: Column(
                    children: [
                      const RadioListTile<String?>(value: null, title: Text('Default font')),
                      ...fonts.when(
                        loading: () => [const LinearProgressIndicator()],
                        error: (e, _) => [ListTile(title: Text(describeError(e)))],
                        data: (list) => [
                          for (final f in list)
                            RadioListTile<String?>(
                              value: f.id,
                              title: _FontName(font: f),
                              secondary: IconButton(
                                tooltip: 'Delete font',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: _busy
                                    ? null
                                    : () => _run(() async {
                                        await ref.read(cosmeticsProvider).deleteFont(f);
                                        ref.invalidate(myFontsProvider);
                                        await session.reloadProfile();
                                        await _refreshPreview();
                                      }),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Account ------------------------------------------------------------
                const Divider(height: 32),
                FutureBuilder<String>(
                  future: session.identity?.fingerprint(),
                  builder: (context, snap) => ListTile(
                    leading: const Icon(Icons.fingerprint),
                    title: const Text('Your safety number'),
                    subtitle: SelectableText(snap.data ?? '…', style: const TextStyle(fontFamily: 'monospace')),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(me?.label ?? ''),
                  subtitle: Text('@${me?.username ?? ''}'),
                ),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Sign out'),
                  subtitle: const Text('Removes your keys from this device'),
                  onTap: session.signOut,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.action, required this.onAction});
  final String title;
  final String action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
    child: Row(
      children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
        TextButton.icon(onPressed: onAction, icon: const Icon(Icons.add), label: Text(action)),
      ],
    ),
  );
}

/// Small "Aa" bubble showing a skin's background and border.
class _SkinChip extends ConsumerWidget {
  const _SkinChip({required this.skinId});
  final String skinId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder(
    future: ref.read(cosmeticsProvider).loadSkin(skinId),
    builder: (context, snap) => SkinnedBubble(
      mine: true,
      style: ResolvedStyle(skin: snap.data),
      child: (t) => Text('Aa', style: t),
    ),
  );
}

/// Renders the font's name in the font itself once it is loaded.
class _FontName extends ConsumerWidget {
  const _FontName({required this.font});
  final UserFont font;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<String?>(
    future: ref.read(cosmeticsProvider).loadFont(font.id),
    builder: (context, snap) => Text(font.name, style: TextStyle(fontFamily: snap.data, fontSize: 18)),
  );
}
