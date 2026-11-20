import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import 'user_search.dart';

class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  bool _group = false;
  final _name = TextEditingController();
  final _selected = <String, Profile>{};
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() create) async {
    setState(() => _busy = true);
    try {
      final id = await create();
      if (mounted) context.go('/chat/$id');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onSelected(Profile p) {
    final chat = ref.read(chatServiceProvider);
    if (!_group) {
      _run(() => chat.createDirectChat(p));
      return;
    }
    setState(() => _selected.containsKey(p.id) ? _selected.remove(p.id) : _selected[p.id] = p);
  }

  @override
  Widget build(BuildContext context) {
    final canCreateGroup = _name.text.trim().isNotEmpty && _selected.isNotEmpty && !_busy;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New chat'),
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      floatingActionButton: _group
          ? FloatingActionButton.extended(
              onPressed: canCreateGroup
                  ? () => _run(
                      () => ref.read(chatServiceProvider).createGroup(_name.text.trim(), _selected.values.toList()),
                    )
                  : null,
              icon: const Icon(Icons.group_add),
              label: const Text('Create group'),
            )
          : null,
      body: Narrow(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Direct'), icon: Icon(Icons.person)),
                  ButtonSegment(value: true, label: Text('Group'), icon: Icon(Icons.group)),
                ],
                selected: {_group},
                onSelectionChanged: (s) => setState(() => _group = s.first),
              ),
            ),
            if (_group) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: TextField(
                  controller: _name,
                  maxLength: 64,
                  decoration: const InputDecoration(labelText: 'Group name', border: OutlineInputBorder()),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (_selected.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in _selected.values)
                        InputChip(label: Text(p.label), onDeleted: () => setState(() => _selected.remove(p.id))),
                    ],
                  ),
                ),
            ],
            Expanded(
              child: UserSearch(onSelected: _onSelected, selectedIds: _selected.keys.toSet()),
            ),
          ],
        ),
      ),
    );
  }
}
