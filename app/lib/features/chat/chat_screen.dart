import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import 'gif_picker.dart';
import 'message_bubble.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;
  int? _lastReadId;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send(MessagePayload Function() build) async {
    setState(() => _sending = true);
    try {
      await ref.read(chatServiceProvider).send(widget.conversationId, build());
    } catch (e) {
      if (mounted) showError(context, e);
      rethrow;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    final style = ref.read(cosmeticsProvider).activeStyle;
    try {
      await _send(() => MessagePayload.text(text, style: style));
      _text.clear();
    } catch (_) {
      // keep the text so the user can retry
    }
    _focus.requestFocus();
  }

  Future<void> _pickGif() async {
    final gif = await showGifPicker(context, widget.conversationId);
    if (gif == null) return;
    final style = ref.read(cosmeticsProvider).activeStyle;
    try {
      await _send(() => MessagePayload.gif(gif, style: style));
    } catch (_) {}
  }

  void _markRead(List<RawMessage> messages) {
    if (messages.isEmpty || messages.first.id == _lastReadId) return;
    _lastReadId = messages.first.id;
    ref.read(chatServiceProvider).markRead(widget.conversationId).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(appSessionProvider).userId!;
    final conversations = ref.watch(conversationsProvider).value ?? const <Conversation>[];
    final conv = conversations.where((c) => c.id == widget.conversationId).firstOrNull;
    final messages = ref.watch(messagesProvider(widget.conversationId));
    final names = {for (final m in conv?.members ?? const <Member>[]) m.id: m.label};

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/')),
        title: Row(
          children: [
            const Icon(Icons.lock, size: 16),
            const SizedBox(width: 6),
            Flexible(child: Text(conv?.title(myId) ?? 'Chat', overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Chat info',
            icon: const Icon(Icons.info_outline),
            onPressed: () => context.go('/chat/${widget.conversationId}/info'),
          ),
        ],
      ),
      body: Narrow(
        maxWidth: 900,
        child: Column(
          children: [
            Expanded(
              child: messages.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Could not load messages: ${describeError(e)}')),
                data: (list) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _markRead(list));
                  if (list.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Messages in this chat are end-to-end encrypted.\nSay hi!',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final m = list[i];
                      final mine = m.senderId == myId;
                      final older = i + 1 < list.length ? list[i + 1] : null;
                      final showSender = (conv?.isGroup ?? false) && !mine && older?.senderId != m.senderId;
                      return MessageBubble(
                        key: ValueKey(m.id),
                        raw: m,
                        mine: mine,
                        senderName: names[m.senderId] ?? 'Former member',
                        showSender: showSender,
                      );
                    },
                  );
                },
              ),
            ),
            if (_sending) const LinearProgressIndicator(minHeight: 2),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Send a GIF',
                      icon: const Icon(Icons.gif_box_outlined),
                      onPressed: _sending ? null : _pickGif,
                    ),
                    Expanded(
                      child: CallbackShortcuts(
                        // Enter sends, Shift+Enter adds a new line (desktop & web).
                        bindings: {const SingleActivator(LogicalKeyboardKey.enter): _sendText},
                        child: TextField(
                          controller: _text,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 6,
                          maxLength: 4000,
                          textInputAction: TextInputAction.newline,
                          decoration: const InputDecoration(
                            hintText: 'Encrypted message',
                            counterText: '',
                            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filled(
                      tooltip: 'Send',
                      icon: const Icon(Icons.send),
                      onPressed: _sending ? null : _sendText,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
