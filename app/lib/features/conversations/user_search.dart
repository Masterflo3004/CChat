import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';

/// Username search field with a result list. Only users who set up encryption appear.
class UserSearch extends ConsumerStatefulWidget {
  const UserSearch({super.key, required this.onSelected, this.selectedIds = const {}, this.excludeIds = const {}});

  final void Function(Profile) onSelected;
  final Set<String> selectedIds;
  final Set<String> excludeIds;

  @override
  ConsumerState<UserSearch> createState() => _UserSearchState();
}

class _UserSearchState extends ConsumerState<UserSearch> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<Profile> _results = [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _loading = true);
      try {
        final r = await ref.read(chatServiceProvider).searchUsers(q);
        if (mounted && q == _query.text) setState(() => _results = r);
      } catch (e) {
        if (mounted) showError(context, e);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = _results.where((p) => !widget.excludeIds.contains(p.id)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _query,
            autofocus: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search by username',
              border: const OutlineInputBorder(),
              suffixIcon: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : null,
            ),
            onChanged: _onChanged,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (context, i) {
              final p = results[i];
              final selected = widget.selectedIds.contains(p.id);
              return ListTile(
                leading: CircleAvatar(child: Text(p.label[0].toUpperCase())),
                title: Text(p.label),
                subtitle: Text('@${p.username}'),
                trailing: selected ? const Icon(Icons.check_circle) : null,
                onTap: () => widget.onSelected(p),
              );
            },
          ),
        ),
      ],
    );
  }
}
