import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';

class ConversationListScreen extends ConsumerWidget {
  const ConversationListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationsProvider);
    final session = ref.watch(appSessionProvider);
    final myId = session.userId!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            tooltip: 'Skins, fonts & account',
            icon: const Icon(Icons.palette_outlined),
            onPressed: () => context.go('/customize'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/new'),
        icon: const Icon(Icons.edit),
        label: const Text('New chat'),
      ),
      body: Narrow(
        child: conversations.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Could not load chats: ${describeError(e)}')),
          data: (list) {
            if (list.isEmpty) {
              return const Center(child: Text('No chats yet. Start one with “New chat”.'));
            }
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(conversationsProvider),
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                itemBuilder: (context, i) => _ConversationTile(conversation: list[i], myId: myId),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.myId});
  final Conversation conversation;
  final String myId;

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    final title = c.title(myId);
    final subtitle = c.isGroup ? '${c.members.length} members' : 'Direct chat';
    final time = c.lastMessageAt ?? c.createdAt;
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: CircleAvatar(
        child: c.isGroup ? const Icon(Icons.group) : Text(title.isEmpty ? '?' : title[0].toUpperCase()),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          const Icon(Icons.lock, size: 12),
          const SizedBox(width: 4),
          Expanded(child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(formatTime(time), style: Theme.of(context).textTheme.bodySmall),
          if (c.unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(10)),
              child: Text('${c.unreadCount}', style: TextStyle(color: scheme.onPrimary, fontSize: 12)),
            ),
        ],
      ),
      onTap: () => context.go('/chat/${c.id}'),
    );
  }
}
