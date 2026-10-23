import 'package:flutter/material.dart';

import '../model/game.dart';
import '../model/launch_options.dart';
import '../util/shell.dart';
import 'theme.dart';

/// Edit what the launcher adds to a game's own argv.
///
/// The fields are deliberately shell-shaped: a wrapper and extra arguments are
/// split like a command line, and the environment is one `KEY=VALUE` per line.
Future<LaunchOptions?> showLaunchOptionsDialog(
  BuildContext context, {
  required Game game,
  required LaunchOptions current,
}) {
  return showDialog<LaunchOptions>(
    context: context,
    builder: (_) => _LaunchOptionsDialog(game: game, current: current),
  );
}

class _LaunchOptionsDialog extends StatefulWidget {
  const _LaunchOptionsDialog({required this.game, required this.current});

  final Game game;
  final LaunchOptions current;

  @override
  State<_LaunchOptionsDialog> createState() => _LaunchOptionsDialogState();
}

class _LaunchOptionsDialogState extends State<_LaunchOptionsDialog> {
  // Quoted on the way in, so an argument that contains a space survives the
  // round trip through the shell splitter on save.
  late final TextEditingController _wrapper = TextEditingController(
    text: quoteCommand(widget.current.wrapper),
  );
  late final TextEditingController _args = TextEditingController(
    text: quoteCommand(widget.current.args),
  );
  late final TextEditingController _cwd = TextEditingController(
    text: widget.current.cwd ?? '',
  );
  late final TextEditingController _env = TextEditingController(
    text: widget.current.env.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('\n'),
  );
  String? _error;

  @override
  void dispose() {
    _wrapper.dispose();
    _args.dispose();
    _cwd.dispose();
    _env.dispose();
    super.dispose();
  }

  void _save() {
    final env = <String, String>{};
    for (final line in _env.text.split('\n')) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      final cut = text.indexOf('=');
      if (cut <= 0) {
        setState(() => _error = 'Environment lines need KEY=VALUE: "$text"');
        return;
      }
      final key = text.substring(0, cut).trim();
      if (key.isEmpty) {
        setState(() => _error = 'Environment lines need a name before "="');
        return;
      }
      env[key] = text.substring(cut + 1).trim();
    }
    final cwd = _cwd.text.trim();
    Navigator.of(context).pop(
      LaunchOptions(
        wrapper: splitShellWords(_wrapper.text.trim()),
        args: splitShellWords(_args.text.trim()),
        env: env,
        cwd: cwd.isEmpty ? null : cwd,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      backgroundColor: palette.surface,
      title: Text('Launch options: ${widget.game.name}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Applied only to this game. The wrapper runs before the game, '
                'the extra arguments after its own command.',
                style: TextStyle(fontSize: 12.5, color: palette.textDim),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _wrapper,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Wrapper (optional)',
                  hintText: 'gamemoderun mangohud',
                  helperText: 'A command line, split like a shell would',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _args,
                decoration: const InputDecoration(
                  labelText: 'Extra arguments (optional)',
                  hintText: '--fullscreen -skipintro',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _cwd,
                decoration: const InputDecoration(
                  labelText: 'Working folder (optional)',
                  hintText: '~/Games/Something',
                  helperText: 'Overrides the folder the source reports',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _env,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Environment (optional)',
                  hintText: 'DXVK_HUD=fps\nWINEFSYNC=1',
                  helperText: 'One KEY=VALUE per line',
                ),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  style: TextStyle(fontSize: 12.5, color: palette.warning),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(const LaunchOptions()),
          child: const Text('Clear'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
