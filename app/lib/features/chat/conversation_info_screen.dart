import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../crypto/e2ee.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../conversations/user_search.dart';

/// Members, safety numbers and group management.
class ConversationInfoScreen extends ConsumerStatefulWidget {
  const ConversationInfoScreen({super.key, required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<ConversationInfoScreen> createState() => _ConversationInfoScreenState();
}

class _ConversationInfoScreenState extends ConsumerState<ConversationInfoScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(conversationsProvider);
      if (done != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addMembers(Conversation conv) async {
    final picked = await showDialog<Profile>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 420,
          height: 520,
          child: UserSearch(
            excludeIds: conv.members.map((m) => m.id).toSet(),
            onSelected: (p) => Navigator.pop(context, p),
          ),
        ),
      ),
    );
    if (picked == null) return;
    await _run(
      () => ref.read(chatServiceProvider).addMembers(conv.id, [picked]),
      done: '${picked.label} added. New messages use a fresh key.',
    );
  }

  Future<void> _remove(Conversation conv, Member m) async {
    final ok = await _confirm('Remove ${m.label}?', 'They will not be able to read new messages.');
    if (!ok) return;
    await _run(() => ref.read(chatServiceProvider).removeMember(conv.id, m.id), done: '${m.label} removed.');
  }

  Future<void> _leave(Conversation conv) async {
    final ok = await _confirm('Leave ${conv.name}?', 'You will lose access to this chat.');
    if (!ok) return;
    await _run(() => ref.read(chatServiceProvider).leave(conv.id));
    if (mounted) context.go('/');
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm')),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(appSessionProvider).userId!;
    final conversations = ref.watch(conversationsProvider);
    final conv = conversations.value?.where((c) => c.id == widget.conversationId).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/chat/${widget.conversationId}')),
        title: Text(conv?.title(myId) ?? 'Chat info'),
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      body: conv == null
          ? const Center(child: CircularProgressIndicator())
          : Narrow(
              child: ListView(
                children: [
                  ListTile(
                    leading: const Icon(Icons.lock),
                    title: const Text('End-to-end encrypted'),
                    subtitle: Text(
                      'Key epoch ${conv.currentEpoch}. Compare safety numbers with your contacts '
                      '(in person or by call) to make sure nobody is in the middle.',
                    ),
                  ),
                  if (conv.isGroup && conv.iAmAdmin)
                    ListTile(
                      leading: const Icon(Icons.person_add),
                      title: const Text('Add member'),
                      onTap: _busy ? null : () => _addMembers(conv),
                    ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text('${conv.members.length} members', style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final m in conv.members)
                    _MemberTile(
                      member: m,
                      isMe: m.id == myId,
                      canRemove: conv.isGroup && conv.iAmAdmin && m.id != myId && !_busy,
                      onRemove: () => _remove(conv, m),
                    ),
                  if (conv.isGroup) ...[
                    const Divider(),
                    ListTile(
                      leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
                      title: Text('Leave group', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      onTap: _busy ? null : () => _leave(conv),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({required this.member, required this.isMe, required this.canRemove, required this.onRemove});
  final Member member;
  final bool isMe;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExpansionTile(
      leading: CircleAvatar(child: Text(member.label[0].toUpperCase())),
      title: Text(isMe ? '${member.label} (you)' : member.label),
      subtitle: Text('@${member.username}${member.isAdmin ? ' · admin' : ''}'),
      trailing: canRemove
          ? IconButton(tooltip: 'Remove', icon: const Icon(Icons.person_remove_outlined), onPressed: onRemove)
          : null,
      children: [
        FutureBuilder<String?>(
          future: ref
              .read(chatServiceProvider)
              .profile(member.id)
              .then((p) => p.hasKeys ? E2ee.fingerprint(p.xPublicKey!, p.edPublicKey!) : null),
          builder: (context, snap) => Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                snap.hasData ? 'Safety number:\n${snap.data}' : 'Loading safety number…',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
