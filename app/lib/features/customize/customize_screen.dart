import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../chat/message_bubble.dart';
import '../community/upload_flows.dart';
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
    ref.invalidate(librarySkinsProvider);
    await _setActive(skinId: created.id);
  }

  Future<void> _addFont() async {
    final font = await uploadFontFlow(context, ref);
    if (font == null) return;
    ref.invalidate(libraryFontsProvider);
    await _setActive(fontId: font.id);
  }

  void _reloadLibrary() {
    ref.invalidate(librarySkinsProvider);
    ref.invalidate(libraryFontsProvider);
  }

  /// Publish/unpublish + delete for your own items; "remove" for saved ones.
  Widget _itemActions({
    required bool own,
    required bool isPublic,
    required Future<void> Function(bool) setPublic,
    required Future<void> Function() delete,
    required Future<void> Function() unsave,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (own)
        IconButton(
          tooltip: isPublic ? 'Shared in the gallery (tap to unshare)' : 'Share in the gallery',
          icon: Icon(isPublic ? Icons.public : Icons.public_off_outlined),
          onPressed: _busy
              ? null
              : () => _run(() async {
                  await setPublic(!isPublic);
                  _reloadLibrary();
                }),
        ),
      IconButton(
        tooltip: own ? 'Delete' : 'Remove from my library',
        icon: Icon(own ? Icons.delete_outline : Icons.bookmark_remove_outlined),
        onPressed: _busy
            ? null
            : () => _run(() async {
                own ? await delete() : await unsave();
                _reloadLibrary();
                await ref.read(appSessionProvider).reloadProfile();
                await _refreshPreview();
              }),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appSessionProvider);
    final skins = ref.watch(librarySkinsProvider);
    final fonts = ref.watch(libraryFontsProvider);
    final isMod = ref.watch(isModeratorProvider).value ?? false;
    final community = ref.read(communityProvider);
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

                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  child: ListTile(
                    leading: const Icon(Icons.storefront_outlined),
                    title: const Text('Community gallery'),
                    subtitle: const Text('Browse, use and share skins, fonts and GIFs'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.go('/gallery'),
                  ),
                ),
                if (isMod)
                  Card(
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: ListTile(
                      leading: const Icon(Icons.shield_outlined),
                      title: const Text('Moderation'),
                      subtitle: const Text('Reports, recent uploads, banned files'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.go('/moderation'),
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
                              subtitle: Text(
                                s.ownerId == session.userId
                                    ? '${s.summary}${s.isPublic ? ' · shared' : ''}'
                                    : '${s.summary} · from the gallery',
                              ),
                              secondary: _itemActions(
                                own: s.ownerId == session.userId,
                                isPublic: s.isPublic,
                                setPublic: (v) => community.setSkinPublic(s.id, v),
                                delete: () => ref.read(cosmeticsProvider).deleteSkin(s),
                                unsave: () => community.unsave('skin', s.id),
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
                  child: Text('Upload a .ttf or .otf file (max 2 MB), or pick one from the gallery.'),
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
                              subtitle: Text(
                                f.ownerId == session.userId
                                    ? (f.isPublic ? 'Yours · shared' : 'Yours')
                                    : 'From the gallery',
                              ),
                              secondary: _itemActions(
                                own: f.ownerId == session.userId,
                                isPublic: f.isPublic,
                                setPublic: (v) => community.setFontPublic(f.id, v),
                                delete: () => ref.read(cosmeticsProvider).deleteFont(f),
                                unsave: () => community.unsave('font', f.id),
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
