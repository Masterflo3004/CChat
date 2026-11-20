import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../data/models.dart';
import '../../providers.dart';

/// Pick a .ttf/.otf, ask for a name and whether to publish it, upload it.
Future<UserFont?> uploadFontFlow(BuildContext context, WidgetRef ref, {bool publishByDefault = false}) async {
  final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['ttf', 'otf']);
  if (file == null || !context.mounted) return null;
  final base = file.name.replaceAll(RegExp(r'\.(ttf|otf)$', caseSensitive: false), '');
  final name = TextEditingController(text: base.length > 40 ? base.substring(0, 40) : base);
  var isPublic = publishByDefault;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Upload font'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 40,
                decoration: const InputDecoration(labelText: 'Font name', border: OutlineInputBorder()),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: isPublic,
                onChanged: (v) => setState(() => isPublic = v),
                title: const Text('Share in the community gallery'),
              ),
              const Text(
                'Only upload fonts whose licence allows sharing. Files are checked against the ban list.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Upload')),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  try {
    final bytes = await file.readAsBytes();
    return await ref
        .read(cosmeticsProvider)
        .uploadFont(
          name: name.text.trim().isEmpty ? 'My font' : name.text.trim(),
          bytes: bytes,
          extension: (file.extension ?? '').replaceFirst('.', ''),
          isPublic: isPublic,
        );
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
}
