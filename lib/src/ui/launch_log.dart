import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/game.dart';
import '../state/library_controller.dart';
import 'theme.dart';

/// The tail of the launch log for [game]: the launch line and whatever the
/// game printed after it.
Future<void> showLaunchLogDialog(
  BuildContext context, {
  required LibraryController controller,
  required Game game,
}) {
  final text = controller.launchLogFor(game);
  return showDialog<void>(
    context: context,
    builder: (context) {
      final palette = context.palette;
      final body = (text == null || text.trim().isEmpty)
          ? 'Nothing logged for this game yet.'
          : text;
      return AlertDialog(
        backgroundColor: palette.surface,
        title: Text('Launch log: ${game.name}'),
        content: SizedBox(
          width: 760,
          height: 460,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                body,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: text == null || text.trim().isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: body));
                    if (context.mounted) Navigator.of(context).pop();
                  },
            icon: const Icon(Icons.copy_all, size: 18),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
