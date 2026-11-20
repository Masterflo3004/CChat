import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Human-readable message for errors coming from Supabase or the app.
String describeError(Object e) {
  if (e is AuthException) return e.message;
  if (e is PostgrestException) return e.message;
  if (e is StorageException) return e.message;
  if (e is FunctionException) return 'Server function failed (${e.status})';
  if (e is ArgumentError) return '${e.message}';
  if (e is StateError) return e.message;
  return e.toString();
}

void showError(BuildContext context, Object e) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(describeError(e))));
}

/// Centered, width-limited body so desktop and web layouts don't stretch.
class Narrow extends StatelessWidget {
  const Narrow({super.key, required this.child, this.maxWidth = 720});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

String formatTime(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (now.year == t.year && now.month == t.month && now.day == t.day) return hm;
  return '${two(t.day)}.${two(t.month)}. $hm';
}
