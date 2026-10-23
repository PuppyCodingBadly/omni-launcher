import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/game.dart';
import '../state/library_controller.dart';
import 'theme.dart';

/// Launch, select or jump: a keyboard-first way around the launcher.
///
/// Ctrl+Enter launches the selected game; Enter opens it (or runs the selected
/// command). The palette has its own query, so the wall's search stays as it
/// was.
Future<void> showCommandPalette(
  BuildContext context, {
  required LibraryController controller,
  required VoidCallback onSettings,
  required Future<void> Function() onAddGame,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _CommandPalette(
      controller: controller,
      onSettings: onSettings,
      onAddGame: onAddGame,
    ),
  );
}

class _Entry {
  const _Entry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.activate,
    this.launch,
    this.game,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback activate;
  final VoidCallback? launch;
  final Game? game;
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({
    required this.controller,
    required this.onSettings,
    required this.onAddGame,
  });

  final LibraryController controller;
  final VoidCallback onSettings;
  final Future<void> Function() onAddGame;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final TextEditingController _query = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  int _index = 0;

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<_Entry> _entries() {
    final controller = widget.controller;
    final query = _query.text.trim();
    final needle = query.toLowerCase();
    final entries = <_Entry>[
      for (final game in controller.searchGames(query, limit: 8))
        _Entry(
          icon: Icons.sports_esports_outlined,
          title: game.name,
          subtitle: game.displaySubtitle,
          game: game,
          activate: () {
            Navigator.of(context).pop();
            controller.select(game);
          },
          launch: () {
            Navigator.of(context).pop();
            controller.launch(game);
          },
        ),
    ];
    void command(
      IconData icon,
      String title,
      String subtitle,
      VoidCallback action,
    ) {
      if (needle.isNotEmpty &&
          !title.toLowerCase().contains(needle) &&
          !subtitle.toLowerCase().contains(needle)) {
        return;
      }
      entries.add(
        _Entry(
          icon: icon,
          title: title,
          subtitle: subtitle,
          activate: () {
            Navigator.of(context).pop();
            action();
          },
        ),
      );
    }

    command(
      Icons.settings,
      'Open settings',
      'Appearance, library, plugins',
      widget.onSettings,
    );
    command(
      Icons.refresh,
      'Rescan library',
      'Find newly installed games',
      controller.rescan,
    );
    command(Icons.add, 'Add a game by hand', 'A name and a launch command', () {
      widget.onAddGame();
    });
    command(
      Icons.visibility_outlined,
      controller.config.showHidden ? 'Hide hidden games' : 'Show hidden games',
      '${controller.hiddenCount} hidden',
      controller.toggleShowHidden,
    );
    command(
      Icons.filter_alt_off_outlined,
      'Clear filters',
      'Sources, tags and status',
      () {
        controller.clearSources();
        controller.clearTags();
        controller.clearSmartFilters();
      },
    );
    return entries;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final entries = _entries();
    if (entries.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _index = (_index + 1) % entries.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _index = (_index - 1 + entries.length) % entries.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final entry = entries[_index.clamp(0, entries.length - 1)];
      if (HardwareKeyboard.instance.isControlPressed && entry.launch != null) {
        entry.launch!();
      } else {
        entry.activate();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final entries = _entries();
    if (_index >= entries.length) _index = 0;
    return Dialog(
      backgroundColor: palette.surface,
      child: SizedBox(
        width: 580,
        height: 540,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: TextField(
                controller: _query,
                focusNode: _focus,
                autofocus: true,
                onChanged: (_) => setState(() => _index = 0),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search games and commands',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        'Nothing matches',
                        style: TextStyle(color: palette.textDim),
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final selected = index == _index;
                        return ListTile(
                          selected: selected,
                          selectedTileColor: palette.accent.withValues(
                            alpha: 0.14,
                          ),
                          leading: Icon(entry.icon, color: palette.textDim),
                          title: Text(entry.title),
                          subtitle: Text(
                            entry.subtitle,
                            style: TextStyle(color: palette.textDim),
                          ),
                          trailing: entry.launch == null
                              ? null
                              : IconButton(
                                  tooltip: 'Launch',
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 20,
                                  ),
                                  onPressed: entry.launch,
                                ),
                          onTap: () {
                            setState(() => _index = index);
                            entry.activate();
                          },
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '↑↓ choose · Enter open · Ctrl+Enter launch',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: palette.textDim),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
