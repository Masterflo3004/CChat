import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../services/cosmetics_service.dart';
import '../../services/media_service.dart';
import '../community/report_dialog.dart';

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
      // Keep text readable on top of picture backgrounds.
      shadows: skin?.skin.background == SkinBackground.image
          ? [Shadow(blurRadius: 3, color: Colors.black.withValues(alpha: 0.45))]
          : null,
    );

    const padding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);
    const constraints = BoxConstraints(maxWidth: 420);

    if (skin == null) {
      return Container(
        constraints: constraints,
        padding: padding,
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
        ),
        child: child(textStyle),
      );
    }

    // Skin: background (+ solid border) inside, image frame painted on top.
    final bubble = Container(
      constraints: constraints,
      padding: padding + EdgeInsets.all(skin.borderInset),
      decoration: skin.decoration(baseColor),
      clipBehavior: Clip.antiAlias,
      child: child(textStyle),
    );
    final frame = skin.framePainter();
    return frame == null ? bubble : CustomPaint(foregroundPainter: frame, child: bubble);
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
    final payload = _message?.payload;
    final gif = payload?.gif;
    final style = payload?.style;
    final actions = <(IconData, String, Future<void> Function())>[
      if (widget.mine) (Icons.delete_outline, 'Delete message for everyone', _delete),
      if (!widget.mine && gif != null && gif.source != GifSource.remote)
        (Icons.flag_outlined, 'Report GIF', _reportGif),
      if (!widget.mine && style?.skinId != null)
        (Icons.flag_outlined, 'Report skin', () => _reportCosmetic(ReportTarget.skin, style!.skinId!)),
      if (!widget.mine && style?.fontId != null)
        (Icons.flag_outlined, 'Report font', () => _reportCosmetic(ReportTarget.font, style!.fontId!)),
    ];
    if (actions.isEmpty) return;
    final chosen = await showModalBottomSheet<Future<void> Function()>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (icon, label, action) in actions)
              ListTile(leading: Icon(icon), title: Text(label), onTap: () => Navigator.pop(context, action)),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    try {
      await chosen();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _thanks() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Thanks, the moderators will look at it.')));
  }

  Future<void> _delete() => ref.read(chatServiceProvider).deleteMessage(widget.raw.id);

  Future<void> _reportCosmetic(ReportTarget type, String id) async {
    final reason = await showReportDialog(context, title: 'Report ${type.name}');
    if (reason == null) return;
    await ref.read(communityProvider).report(type, id, reason);
    _thanks();
  }

  Future<void> _reportGif() async {
    final gif = _message!.payload!.gif!;
    if (gif.source == GifSource.library) {
      final reason = await showReportDialog(context, title: 'Report GIF');
      if (reason == null) return;
      await ref.read(communityProvider).report(ReportTarget.gif, gif.gifId!, reason);
    } else {
      final reason = await showReportDialog(
        context,
        title: 'Report GIF',
        warning:
            'This GIF is end-to-end encrypted, so the moderators can’t see it. Reporting it '
            'uploads a decrypted copy of this GIF (only the GIF) for the moderators to review.',
      );
      if (reason == null) return;
      final bytes = await ref.read(chatServiceProvider).downloadDecrypted(gif.path!, gif.fileKey!);
      await ref.read(communityProvider).reportAttachment(bytes, 'reported.gif', reason);
    }
    _thanks();
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

/// Shows a GIF from the library, GIPHY, or an encrypted upload. Banned GIFs are hidden.
class GifView extends ConsumerStatefulWidget {
  const GifView({super.key, required this.gif, this.maxWidth = 260});
  final GifContent gif;
  final double maxWidth;

  @override
  ConsumerState<GifView> createState() => _GifViewState();
}

class _GifViewState extends ConsumerState<GifView> {
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    final gif = widget.gif;
    switch (gif.source) {
      case GifSource.file:
        // The server can't see encrypted files, so the client checks the hash.
        _bytes = () async {
          final bytes = await ref.read(chatServiceProvider).downloadDecrypted(gif.path!, gif.fileKey!);
          if (await ref.read(mediaProvider).isBanned(bytes)) throw BannedFileException();
          return bytes;
        }();
      case GifSource.library:
        _bytes = ref.read(mediaProvider).download('gifs', gif.path!);
      case GifSource.remote:
        _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final gif = widget.gif;
    final maxWidth = widget.maxWidth;
    final aspect = gif.width > 0 && gif.height > 0 ? gif.width / gif.height : 1.0;
    final width = maxWidth.clamp(80.0, gif.width > 0 ? gif.width.toDouble().clamp(120.0, maxWidth) : maxWidth);
    Widget image;
    if (_bytes != null) {
      image = FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (context, snap) {
          if (snap.hasError) return const _Unavailable();
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
        errorBuilder: (_, _, _) => const _Unavailable(),
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

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => Container(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    alignment: Alignment.center,
    padding: const EdgeInsets.all(8),
    child: const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hide_image_outlined),
        SizedBox(height: 4),
        Text('GIF unavailable or removed by moderators', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
      ],
    ),
  );
}
