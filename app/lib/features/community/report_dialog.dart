import 'package:material_ui/material_ui.dart';

/// Asks for a report reason. Returns null if cancelled.
Future<String?> showReportDialog(BuildContext context, {required String title, String? warning}) {
  final reason = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (warning != null) ...[Text(warning), const SizedBox(height: 12)],
            TextField(
              controller: reason,
              autofocus: true,
              maxLength: 500,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'What is wrong with it?', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final r = reason.text.trim();
            Navigator.pop(context, r.isEmpty ? 'No reason given' : r);
          },
          child: const Text('Report'),
        ),
      ],
    ),
  );
}
