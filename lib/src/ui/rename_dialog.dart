import 'package:flutter/material.dart';

import 'theme.dart';

/// What the rename dialog decided: a new name, or a reset to the discovered one.
class RenameChoice {
  const RenameChoice.rename(this.name) : reset = false;
  const RenameChoice.reset() : name = '', reset = true;

  /// The name to store; empty for [RenameChoice.reset].
  final String name;
  final bool reset;
}

/// Ask for a new name for a game.
///
/// [currentName] is what the library shows now, [discoveredName] is what the
/// launcher found for it: when the two differ the game has been renamed, so the
/// dialog says so and offers to go back.
Future<RenameChoice?> showRenameGameDialog(
  BuildContext context, {
  required String currentName,
  String? discoveredName,
}) {
  final field = TextEditingController(text: currentName);
  final formKey = GlobalKey<FormState>();
  final renamed = discoveredName != null && discoveredName != currentName;
  return showDialog<RenameChoice>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: context.palette.surface,
      title: const Text('Rename game'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: field,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'A name is required'
                    : null,
                onFieldSubmitted: (_) => _save(context, formKey, field),
              ),
              if (renamed)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Renamed. The launcher found this game as "$discoveredName".',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: context.palette.textDim,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (renamed)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const RenameChoice.reset()),
            child: const Text('Reset'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _save(context, formKey, field),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

void _save(
  BuildContext context,
  GlobalKey<FormState> formKey,
  TextEditingController field,
) {
  if (!(formKey.currentState?.validate() ?? false)) return;
  Navigator.of(context).pop(RenameChoice.rename(field.text.trim()));
}
