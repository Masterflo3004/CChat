import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../services/cosmetics_service.dart';

/// Resolved skin + font for a message style.
class ResolvedStyle {
  const ResolvedStyle({this.skin, this.fontFamily});
  final LoadedSkin? skin;
  final String? fontFamily;
}

Future<ResolvedStyle> resolveStyle(WidgetRef ref, MessageStyle style) async {
  final cosmetics = ref.read(cosmeticsProvider);
  final results = await Future.wait<Object?>([
    style.skinId == null ? Future.value(null) : cosmetics.loadSkin(style.skinId!).catchError((_) => null),
    style.fontId == null ? Future.value(null) : cosmetics.loadFont(style.fontId!).catchError((_) => null),
  ]);
  return ResolvedStyle(skin: results[0] as LoadedSkin?, fontFamily: results[1] as String?);
}

/// The bubble itself: background (theme colour or skin texture) + content.
class SkinnedBubble extends StatelessWidget {
  const SkinnedBubble({super.key, required this.mine, required this.style, required this.child});
  final bool mine;
  final ResolvedStyle style;
  final Widget Function(TextStyle textStyle) child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final skin = style.skin;
    final baseColor = mine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final textColor = skin?.textColor ?? (mine ? scheme.onPrimaryContainer : scheme.onSurface);

    final textStyle = (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      color: textColor,
      fontFamily: style.fontFamily,
      shadows: skin == null ? null : [Shadow(blurRadius: 3, color: Colors.black.withValues(alpha: 0.45))],
    );

    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: skin == null ? baseColor : null,
        image: skin?.decoration(),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 4),
          bottomRight: Radius.circular(mine ? 4 : 18),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child(textStyle),
    );
  }
}

class MessageBubble extends ConsumerStatefulWidget {
  const MessageBubble({
    super.key,
    required this.raw,
    required this.mine,
    required this.senderName,
    required this.showSender,
  });

  final RawMessage raw;
  final bool mine;
  final String senderName;
  final bool showSender;

  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble> {
  ChatMessage? _message;
  ResolvedStyle _style = const ResolvedStyle();

  @override
  void initState() {
    super.initState();
    _message = ref.read(chatServiceProvider).cachedMessage(widget.raw.id);
    _load();
  }

  Future<void> _load() async {
    final msg = _message ?? await ref.read(chatServiceProvider).decrypt(widget.raw);
    if (!mounted) return;
    setState(() => _message = msg);
    final payload = msg.payload;
    if (payload != null && (payload.style.skinId != null || payload.style.fontId != null)) {
      final style = await resolveStyle(ref, payload.style);
      if (mounted) setState(() => _style = style);
    }
  }

  Future<void> _menu() async {
    if (!widget.mine) return;
    final delete = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Delete message for everyone'),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (delete == true) {
      try {
        await ref.read(chatServiceProvider).deleteMessage(widget.raw.id);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final msg = _message;
    Widget content;

    if (msg == null) {
      content = SkinnedBubble(
        mine: widget.mine,
        style: const ResolvedStyle(),
        child: (_) => const SizedBox(
          width: 40,
          height: 16,
          child: Center(child: SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      );
    } else if (msg.error != null || msg.payload == null) {
      content = SkinnedBubble(
        mine: widget.mine,
        style: const ResolvedStyle(),
        child: (t) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_encryption_outlined, size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 6),
            Flexible(
              child: Text(msg.error ?? 'Unreadable message', style: t.copyWith(fontStyle: FontStyle.italic)),
            ),
          ],
        ),
      );
    } else {
      final payload = msg.payload!;
      switch (payload.type) {
        case PayloadType.text:
          content = SkinnedBubble(
            mine: widget.mine,
            style: _style,
            child: (t) => SelectableText(payload.text ?? '', style: t),
          );
        case PayloadType.gif:
          content = SkinnedBubble(
            mine: widget.mine,
            style: _style,
            child: (_) => GifView(gif: payload.gif!),
          );
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Column(
        crossAxisAlignment: widget.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (widget.showSender)
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 2),
              child: Text(widget.senderName, style: theme.textTheme.labelMedium),
            ),
          GestureDetector(onLongPress: _menu, onSecondaryTap: _menu, child: content),
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
            child: Text(formatTime(widget.raw.createdAt), style: theme.textTheme.labelSmall),
          ),
        ],
      ),
    );
  }
}

/// Shows a GIF from the search provider or an encrypted upload.
class GifView extends ConsumerWidget {
  const GifView({super.key, required this.gif, this.maxWidth = 260});
  final GifContent gif;
  final double maxWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final aspect = gif.width > 0 && gif.height > 0 ? gif.width / gif.height : 1.0;
    final width = maxWidth.clamp(80.0, gif.width > 0 ? gif.width.toDouble().clamp(120.0, maxWidth) : maxWidth);
    Widget image;
    if (gif.isFile) {
      image = FutureBuilder<Uint8List>(
        future: ref.read(chatServiceProvider).downloadDecrypted(gif.path!, gif.fileKey!),
        builder: (context, snap) {
          if (snap.hasError) return const Center(child: Icon(Icons.broken_image_outlined));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
          return Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true);
        },
      );
    } else {
      image = Image.network(
        gif.url!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: gif.title,
        errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined)),
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(width: width, height: width / aspect, child: image),
    );
  }
}
