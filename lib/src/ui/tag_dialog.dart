import 'package:flutter/material.dart';

import 'theme.dart';

/// Ask for the user's tags on a game. The source's own tags are shown above
/// the field, so it is clear which ones cannot be removed here.
Future<List<String>?> showTagDialog(
  BuildContext context, {
  required List<String> manual,
  required List<String> sourceTags,
}) {
  final controller = TextEditingController(text: manual.join(', '));
  return showDialog<List<String>>(
    context: context,
    builder: (context) {
      final palette = context.palette;
      return AlertDialog(
        backgroundColor: palette.surface,
        title: const Text('Tags'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sourceTags.isNotEmpty) ...[
                Text(
                  'From the launcher',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.1,
                    color: palette.textDim,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in sourceTags)
                      Chip(
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                const SizedBox(height: 18),
              ],
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Your tags',
                  hintText: 'Backlog, Co-op, Finished',
                  helperText: 'Separate tags with commas',
                ),
                onSubmitted: (_) => _save(context, controller.text),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => _save(context, ''),
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () => _save(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

void _save(BuildContext context, String text) {
  final tags = [
    for (final part in text.split(','))
      if (part.trim().isNotEmpty) part.trim(),
  ];
  Navigator.of(context).pop(tags);
}
