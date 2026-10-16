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
    // The panel always asks about the game it is showing, so the game's id is
    // the query's id; the query itself is only built when the button is used.
    final running = controller.isLookingUp(plugin.id, game.id);
    final answer = controller.pluginAnswer(plugin.id, game.id);
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
        OutlinedButton.icon(
          onPressed: running
              ? null
              : () => controller.lookUp(plugin, PluginQuery.forGame(game)),
          icon: const Icon(Icons.travel_explore, size: 18),
          label: Text(plugin.action, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(height: 12),
        PluginAnswerView(
          answer: answer,
          running: running,
          onOpenUrl: controller.openUrl,
        ),
      ],
    );
  }
}
