import 'package:flutter/material.dart';

import '../model/game.dart';
import '../plugins/plugin.dart';
import '../plugins/plugin_runner.dart';
import '../state/library_controller.dart';
import 'field.dart';
import 'theme.dart';

/// What one plugin answered: the fields it gave, or why it could not.
class PluginAnswerView extends StatelessWidget {
  const PluginAnswerView({
    super.key,
    required this.answer,
    required this.running,
    this.onOpenUrl,
  });

  /// The answer to show; `null` means the plugin has not been asked yet.
  final PluginAnswer? answer;

  /// True while the plugin is being asked.
  final bool running;

  /// Opens the page the answer came from, when it names one.
  final ValueChanged<String>? onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (running) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Looking up…',
            style: TextStyle(fontSize: 12.5, color: palette.textDim),
          ),
        ],
      );
    }
    final answer = this.answer;
    if (answer == null) return const SizedBox.shrink();
    if (!answer.ok) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: palette.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              answer.error!,
              style: TextStyle(fontSize: 12.5, color: palette.warning),
            ),
          ),
        ],
      );
    }
    final url = answer.url;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final field in answer.fields)
          LabelledValue(label: field.label, value: field.value),
        if (url != null && onOpenUrl != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onOpenUrl!(url),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open the page'),
            ),
          ),
      ],
    );
  }
}

/// One plugin's corner of the detail panel: what it says about this game, and
/// the button that asks it.
///
/// The lookup is per game and costs a round trip to somebody else's site, so it
/// is started by hand rather than every time a game is selected.
class PluginSection extends StatelessWidget {
  const PluginSection({
    super.key,
    required this.controller,
    required this.game,
    required this.plugin,
  });

  final LibraryController controller;
  final Game game;
  final Plugin plugin;

  @override
  Widget build(BuildContext context) {
    final canLookUp = controller.pluginGranted(plugin, PluginCapability.lookup);
    final canAct = controller.pluginGranted(plugin, PluginCapability.actions);
    final actions = canAct ? plugin.actions : const <PluginAction>[];
    if (!canLookUp && actions.isEmpty) return const SizedBox.shrink();

    // The panel always asks about the game it is showing, so the game's id is
    // the query's id; the query itself is only built when the button is used.
    final running = controller.isLookingUp(plugin.id, game.id);
    final answer = controller.pluginAnswer(plugin.id, game.id);
    // Once the plugin has answered, the answer is the section: the button
    // only stays for a lookup that failed, where it is the way to retry.
    final answered = answer != null && answer.ok;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            plugin.name.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.2,
              color: context.palette.textDim,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (canLookUp) ...[
          if (!answered) ...[
            OutlinedButton.icon(
              onPressed: running
                  ? null
                  : () => controller.lookUp(plugin, PluginQuery.forGame(game)),
              icon: const Icon(Icons.travel_explore, size: 18),
              label: Text(plugin.action, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: 12),
          ],
          PluginAnswerView(
            answer: answer,
            running: running,
            onOpenUrl: controller.openUrl,
          ),
        ],
        if (actions.isNotEmpty) ...[
          if (canLookUp && !answered) const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final action in actions)
                _ActionButton(
                  controller: controller,
                  plugin: plugin,
                  action: action,
                  game: game,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// One action a plugin offers, with its own running spinner.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.controller,
    required this.plugin,
    required this.action,
    required this.game,
  });

  final LibraryController controller;
  final Plugin plugin;
  final PluginAction action;
  final Game game;

  @override
  Widget build(BuildContext context) {
    final running = controller.isPluginActionRunning(plugin, action, game);
    return OutlinedButton.icon(
      onPressed: running
          ? null
          : () async {
              final answer = await controller.runPluginAction(
                plugin,
                action,
                game,
              );
              if (answer == null || !context.mounted) return;
              await showPluginResultDialog(
                context,
                plugin: plugin,
                action: action,
                answer: answer,
                onOpenUrl: controller.openUrl,
              );
            },
      icon: running
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_circle_outline, size: 18),
      label: Text(action.name, overflow: TextOverflow.ellipsis),
    );
  }
}

/// What an action answered, in the same shape as a lookup.
Future<void> showPluginResultDialog(
  BuildContext context, {
  required Plugin plugin,
  required PluginAction action,
  required PluginAnswer answer,
  ValueChanged<String>? onOpenUrl,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: context.palette.surface,
      title: Text('${plugin.name}: ${action.name}'),
      // A plugin may answer with many fields: the dialog keeps a bounded
      // height and scrolls instead of overflowing the screen.
      content: SizedBox(
        width: 500,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: PluginAnswerView(
              answer: answer,
              running: false,
              onOpenUrl: onOpenUrl,
            ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
