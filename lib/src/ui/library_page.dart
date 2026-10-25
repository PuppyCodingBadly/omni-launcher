import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/game.dart';
import '../state/library_controller.dart';
import 'command_palette.dart';
import 'detail_panel.dart';
import 'filter_dialog.dart';
import 'game_tile.dart';
import 'launch_log.dart';
import 'settings_view.dart';
import 'theme.dart';

/// The library: sidebar, cover grid, detail panel.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.controller});

  final LibraryController controller;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  /// Below this much height the shelf is left out: the header, the strip and
  /// the status bar would leave the wall too little to show.
  static const double _shelfMinBody = 420;

  /// The page's one motion: the panel reveal, the sidebar fold, the
  /// selection badges and the keyboard scroll all share it.
  static const Duration _motion = Duration(milliseconds: 200);
  static const Curve _motionCurve = Curves.easeOutCubic;

  final TextEditingController _search = TextEditingController();

  /// The search field's own Esc handling lives on its node: a text field
  /// swallows Escape before the page's shortcuts see it, so the page cannot
  /// offer "Esc clears the search first" from there.
  late final FocusNode _searchFocus = FocusNode(onKeyEvent: _onSearchKey);

  /// Selection mode for hiding games in bulk: the tiles get a check overlay
  /// and taps mark a game instead of opening it.
  bool _selecting = false;
  final Set<String> _marked = <String>{};

  /// One focus node per visible game, so arrow keys can walk the wall and a
  /// re-sort keeps the focus where it was.
  final Map<String, FocusNode> _gridNodes = <String, FocusNode>{};

  /// The reverse of [_gridNodes]: which wall position a focus node belongs
  /// to, so a key press finds the focused tile in O(1) instead of scanning
  /// every node. Rebuilt alongside [_gridNodes] in the grid build, so the
  /// two never disagree.
  final Map<FocusNode, int> _gridNodeIndex = <FocusNode, int>{};

  /// The wall's scroll position: an arrow that lands on a tile past the
  /// built viewport jumps its row into view so the focus request has
  /// somewhere to land.
  final ScrollController _gridScroll = ScrollController();

  /// The wall's column count, refreshed every grid build; the up and down
  /// arrows move by one row.
  int _gridColumns = 1;

  /// The height of one grid row including its gap, refreshed every grid
  /// build; the jump for a tile past the built viewport goes by whole rows.
  double _gridRowStride = 0;

  /// The game the detail panel showed last, kept through its exit animation
  /// so the panel never animates out empty.
  Game? _lastShown;

  /// The quick exit the status bar already offered, so a rebuild does not
  /// offer it again.
  DateTime? _lastExitShown;

  void _openPalette(BuildContext context, LibraryController controller) {
    showCommandPalette(
      context,
      controller: controller,
      onSettings: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsView(controller: controller),
        ),
      ),
      onAddGame: () async {
        final entry = await showAddGameDialog(context);
        if (entry != null) {
          await controller.addManual(entry.name, entry.command, cwd: entry.cwd);
        }
      },
    );
  }

  KeyEventResult _onSearchKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _search.clear();
      widget.controller.setQuery('');
      node.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Arrow keys (and a gamepad's D-pad) walk the wall: one tile sideways, one
  /// row up or down, clamped at the edges. The tile keeps Enter to itself.
  KeyEventResult _onGridKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // A D-pad arrives as plain arrow keys on most Linux mappings; the
    // gameButton13-16 constants catch the hat-style pads.
    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.gameButton14 => -1,
      LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.gameButton15 => 1,
      LogicalKeyboardKey.arrowUp ||
      LogicalKeyboardKey.gameButton13 => -_gridColumns,
      LogicalKeyboardKey.arrowDown ||
      LogicalKeyboardKey.gameButton16 => _gridColumns,
      _ => 0,
    };
    if (delta == 0) return KeyEventResult.ignored;
    // Arrows belong to the search field while it has focus, and selection
    // mode is pointer-driven: its tiles take no focus.
    if (_searchFocus.hasFocus || _selecting) return KeyEventResult.ignored;
    // Only the wall's own focus (or no focus at all, e.g. right after Esc
    // left the search field) starts a walk; a sidebar or panel control keeps
    // its arrows for the platform's default traversal.
    final focused = FocusManager.instance.primaryFocus;
    final inGrid = focused != null && _gridNodeIndex.containsKey(focused);
    final nowhere =
        focused == null || focused == node || focused is FocusScopeNode;
    if (!inGrid && !nowhere) return KeyEventResult.ignored;
    _moveGridFocus(delta);
    return KeyEventResult.handled;
  }

  void _moveGridFocus(int delta) {
    final games = widget.controller.visibleGames;
    if (games.isEmpty) return;
    final focused = FocusManager.instance.primaryFocus;
    final index = focused == null ? -1 : (_gridNodeIndex[focused] ?? -1);
    // Nothing focused yet: the first arrow lands on the first tile.
    final next = index < 0
        ? 0
        : (index + delta).clamp(0, games.length - 1).toInt();
    if (next == index) return;
    final target = _gridNodes[games[next].id];
    if (target == null) return;
    final tileContext = target.context;
    if (tileContext == null) {
      // The destination tile is past the built viewport, so it has no
      // element to focus yet. Jump its row in first; the focus request
      // stays pending on the detached node and lands when the tile
      // attaches during the build the jump starts.
      if (_gridScroll.hasClients && _gridRowStride > 0) {
        final position = _gridScroll.position;
        final row = next ~/ _gridColumns;
        final offset = (row * _gridRowStride - position.viewportDimension / 2)
            .clamp(0.0, position.maxScrollExtent);
        _gridScroll.jumpTo(offset);
      }
      target.requestFocus();
      // The jump only lands near the row: once the tile exists, settle it
      // into view the way an already-built destination is settled.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final built = target.context;
        if (built != null) {
          Scrollable.ensureVisible(
            built,
            duration: _motion,
            curve: _motionCurve,
            alignment: 0.5,
          );
        }
      });
      return;
    }
    target.requestFocus();
    // A move off the screen scrolls the destination tile back into view.
    Scrollable.ensureVisible(
      tileContext,
      duration: _motion,
      curve: _motionCurve,
      alignment: 0.5,
    );
  }

  /// Hide every marked game and leave selection mode.
  void _hideMarked(LibraryController controller) {
    final byId = {for (final game in controller.games) game.id: game};
    for (final id in _marked) {
      final game = byId[id];
      if (game != null) controller.setHidden(game, hidden: true);
    }
    setState(() {
      _selecting = false;
      _marked.clear();
    });
  }

  void _toggleSelecting() => setState(() {
    _selecting = !_selecting;
    _marked.clear();
  });

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _gridScroll.dispose();
    for (final node in _gridNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    // The shortcuts, the actions and the wall's key handling read no library
    // state, so they sit above the subscription: a controller notification
    // rebuilds the body alone, not this shell. Every value the body shows is
    // read inside the ListenableBuilder, so the display stays live.
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FocusSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyR, control: true):
            _RescanIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _PaletteIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _ClearIntent(),
      },
      child: Actions(
        actions: {
          _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
            onInvoke: (_) {
              _searchFocus.requestFocus();
              return null;
            },
          ),
          _RescanIntent: CallbackAction<_RescanIntent>(
            onInvoke: (_) {
              controller.rescan();
              return null;
            },
          ),
          _PaletteIntent: CallbackAction<_PaletteIntent>(
            onInvoke: (_) {
              _openPalette(context, controller);
              return null;
            },
          ),
          _ClearIntent: CallbackAction<_ClearIntent>(
            onInvoke: (_) {
              // The search field's Esc is handled by its own focus node
              // (see _onSearchKey); what is left here: fold selection mode,
              // then close the detail panel.
              if (_selecting) {
                _toggleSelecting();
              } else {
                controller.select(null);
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: _onGridKey,
          child: ListenableBuilder(listenable: controller, builder: _buildBody),
        ),
      ),
    );
  }

  /// Everything that reads the controller: rebuilt on each of its
  /// notifications, while the shortcut shell above stays put.
  Widget _buildBody(BuildContext context, Widget? _) {
    final controller = widget.controller;
    final games = controller.visibleGames;
    // The shelf is a shortcut to what was just played. While a search is
    // running the wall already shows the matches, so it steps aside rather
    // than repeating a few of them.
    final recent = controller.query.isEmpty
        ? controller.recentlyPlayed(visible: games)
        : const <Game>[];
    // Remember the open game so the detail panel can animate out with its
    // content still on it.
    _lastShown = controller.selected ?? _lastShown;
    _offerQuickExit(context, controller);
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Sidebar(controller: controller),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  _header(controller),
                  if (controller.tagFilter.isNotEmpty ||
                      controller.smartFilters.isNotEmpty)
                    _filterBar(controller),
                  // A window this short has no room for a strip above the
                  // wall: the shelf steps aside rather than pushing the
                  // wall off the bottom of the page.
                  if (recent.isNotEmpty &&
                      constraints.maxHeight >= _shelfMinBody)
                    _shelf(controller, recent),
                  Expanded(child: _grid(controller, games)),
                  if (_selecting)
                    _selectionBar(controller)
                  else
                    _statusBar(controller, games.length),
                ],
              ),
            ),
          ),
          // The panel slides and fades in on selection instead of
          // popping; the last shown game stays through the exit so the
          // column never animates out empty.
          _panelReveal(controller),
        ],
      ),
    );
  }

  /// The panel's reveal: a slide-and-fade from the right edge. [Tween]'s
  /// begin follows its end, so the very first build (nothing selected) does
  /// not animate.
  Widget _panelReveal(LibraryController controller) {
    // The page decides the panel's width: the panel would ask MediaQuery for
    // the whole window, but what it really borders is the wall.
    final panelWidth = math.min(
      DetailPanel.defaultWidth,
      MediaQuery.sizeOf(context).width * 0.42,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: controller.selected != null ? 1 : 0),
      duration: _motion,
      curve: _motionCurve,
      builder: (context, t, child) => ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: t,
          child: Opacity(opacity: t, child: child),
        ),
      ),
      child: _lastShown == null
          ? SizedBox(width: panelWidth)
          : DetailPanel(
              controller: controller,
              game: _lastShown!,
              width: panelWidth,
            ),
    );
  }

  /// After a game exits right away, offer its log instead of letting the
  /// launch line scroll past unnoticed.
  void _offerQuickExit(BuildContext context, LibraryController controller) {
    final exit = controller.latestQuickExit;
    if (exit == null || exit.at == _lastExitShown) return;
    Game? match;
    for (final entry in controller.games) {
      if (entry.id == exit.gameId) {
        match = entry;
        break;
      }
    }
    if (match == null) return;
    final game = match;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Another build in the same frame queued its own callback for this
      // exit; the first one that gets here owns the bar.
      if (_lastExitShown == exit.at) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text('${game.name} exited ${_exitAfter(exit.after)}'),
          action: SnackBarAction(
            label: 'View log',
            onPressed: () => showLaunchLogDialog(
              context,
              controller: controller,
              game: game,
            ),
          ),
        ),
      );
      // Marked only once the bar is actually up: a frame with no messenger
      // leaves the offer for the next build to retry.
      _lastExitShown = exit.at;
    });
  }

  /// How long the launch lasted, phrased for the bar: a game that quit at
  /// once reads "under a second", never a bare "0s".
  static String _exitAfter(Duration after) => after < const Duration(seconds: 1)
      ? 'under a second after launch'
      : 'after ${after.inSeconds}s';

  /// The filters in effect, each removable in place.
  Widget _filterBar(LibraryController controller) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(Icons.filter_alt_outlined, size: 16, color: palette.textDim),
          for (final tag in controller.tagFilter)
            InputChip(
              label: Text(tag),
              visualDensity: VisualDensity.compact,
              onDeleted: () => controller.toggleTag(tag),
            ),
          for (final filter in controller.smartFilters)
            InputChip(
              label: Text(filter.label),
              visualDensity: VisualDensity.compact,
              onDeleted: () => controller.toggleSmartFilter(filter),
            ),
          TextButton(
            onPressed: () {
              controller.clearTags();
              controller.clearSmartFilters();
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Widget _header(LibraryController controller) {
    final search = TextField(
      controller: _search,
      focusNode: _searchFocus,
      onChanged: controller.setQuery,
      decoration: InputDecoration(
        hintText: 'Search ${controller.games.length} games (Ctrl+F)',
        prefixIcon: Tooltip(
          message: 'Search (Ctrl+F)',
          child: Icon(Icons.search, color: context.palette.textDim),
        ),
        suffixIcon: controller.query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear (Esc)',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _search.clear();
                  controller.setQuery('');
                },
              ),
      ),
    );
    final activeFilters =
        controller.tagFilter.length + controller.smartFilters.length;
    final actions = <Widget>[
      IconButton.filledTonal(
        tooltip: activeFilters == 0 ? 'Filters' : 'Filters ($activeFilters)',
        isSelected: activeFilters > 0,
        onPressed: () => showFilterDialog(context, controller: controller),
        icon: const Icon(Icons.filter_alt_outlined),
      ),
      _sortControl(controller),
      IconButton.filledTonal(
        tooltip: _selecting ? 'Cancel selection (Esc)' : 'Select games',
        isSelected: _selecting,
        onPressed: _toggleSelecting,
        icon: const Icon(Icons.checklist),
      ),
      IconButton.filledTonal(
        tooltip: 'Rescan (Ctrl+R)',
        onPressed: controller.rescan,
        icon: const Icon(Icons.refresh),
      ),
      IconButton.filledTonal(
        tooltip: 'Add a game by hand',
        onPressed: () async {
          final entry = await showAddGameDialog(context);
          if (entry != null) {
            await controller.addManual(
              entry.name,
              entry.command,
              cwd: entry.cwd,
            );
          }
        },
        icon: const Icon(Icons.add),
      ),
      IconButton.filledTonal(
        tooltip: 'Settings',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsView(controller: controller),
          ),
        ),
        icon: const Icon(Icons.settings),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 12),
      // A narrow wall (a small window with the panel open) cannot fit the
      // search field and the five buttons on one line: the buttons move under
      // the field instead of overflowing the column.
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 480) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                search,
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: 14),
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                actions[i],
              ],
            ],
          );
        },
      ),
    );
  }

  /// The wall's ordering, as a menu behind an icon that matches the header's
  /// other buttons. The check marks the mode in effect.
  Widget _sortControl(LibraryController controller) {
    const labels = {
      'name': 'Name',
      'lastPlayed': 'Recently played',
      'mostPlayed': 'Most played',
    };
    return MenuAnchor(
      menuChildren: [
        for (final entry in labels.entries)
          MenuItemButton(
            leadingIcon: controller.sortMode == entry.key
                ? const Icon(Icons.check, size: 18)
                : const SizedBox(width: 18),
            onPressed: () {
              controller.setSortMode(entry.key);
            },
            child: Text(entry.value),
          ),
      ],
      builder: (context, menu, _) => IconButton.filledTonal(
        tooltip: 'Sort: ${labels[controller.sortMode] ?? labels['name']}',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.sort),
      ),
    );
  }

  /// Selection mode's bar, in place of the status bar: how many games are
  /// marked, and the way out.
  Widget _selectionBar(LibraryController controller) {
    final palette = context.palette;
    final count = _marked.length;
    return Container(
      color: palette.surface,
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 12),
      child: Row(
        children: [
          Icon(Icons.checklist, size: 18, color: palette.accentSoft),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              count == 0
                  ? 'Tap games to mark them'
                  : '$count ${count == 1 ? 'game' : 'games'} marked',
              style: TextStyle(fontSize: 13, color: palette.textDim),
            ),
          ),
          TextButton(onPressed: _toggleSelecting, child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: count == 0 ? null : () => _hideMarked(controller),
            icon: const Icon(Icons.visibility_off_outlined, size: 18),
            label: Text('Hide $count ${count == 1 ? 'game' : 'games'}'),
          ),
        ],
      ),
    );
  }

  /// Selection mode's tile: a tap marks the game instead of opening it, so
  /// the tile's own pointer and key handling is shut off and a badge and a
  /// tint say whether the game is marked.
  Widget _selectableTile(Game game, Widget tile) {
    final palette = context.palette;
    final marked = _marked.contains(game.id);
    return GestureDetector(
      // Opaque: the AbsorbPointer below keeps the tile itself out of the hit
      // test, and the tap still has to land here.
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(
        () => marked ? _marked.remove(game.id) : _marked.add(game.id),
      ),
      child: AbsorbPointer(
        child: ExcludeFocus(
          child: Stack(
            children: [
              tile,
              // The tint covers the cover, not the labels under it.
              Positioned(
                top: 0,
                left: 0,
                width: GameTile.width,
                height: GameTile.coverHeight,
                child: IgnorePointer(
                  child: AnimatedContainer(
                    duration: _motion,
                    curve: _motionCurve,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: marked
                          ? palette.accent.withValues(alpha: 0.22)
                          : Colors.transparent,
                      border: Border.all(
                        color: marked ? palette.accent : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: IgnorePointer(
                  child: AnimatedScale(
                    scale: marked ? 1 : 0,
                    duration: _motion,
                    curve: Curves.easeOutBack,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: palette.accent,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check,
                        size: 16,
                        color: palette.onAccent,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The recently played shelf: the last few games, newest first, as one
  /// scrolling row of small covers above the wall.
  Widget _shelf(LibraryController controller, List<Game> games) {
    final strip = GameTile.heightFor(
      compact: true,
      textScaler: MediaQuery.textScalerOf(context),
    );
    // A hovered shelf tile grows by [_hoverScale], and a list exactly as tall
    // as the tile clips that growth: the top of the cover — and the selected
    // ring on it — used to disappear. The strip is that much taller, with the
    // same room as padding, so the lift stays inside the viewport.
    final room = GameTile.hoverOverflowFor(strip).ceilToDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 10),
          child: Text(
            'RECENTLY PLAYED',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.2,
              color: context.palette.textDim,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: strip + room * 2,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(28, room, 28, room),
            itemCount: games.length,
            separatorBuilder: (context, index) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              final game = games[index];
              return GameTile(
                key: ValueKey('recent:${game.id}'),
                game: game,
                controller: controller,
                selected: controller.selected?.id == game.id,
                compact: true,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _grid(LibraryController controller, List<Game> games) {
    if (controller.status == LibraryStatus.loading && games.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (games.isEmpty) {
      final palette = context.palette;
      // A tag or smart filter narrows an existing library: the empty wall
      // means "nothing passes the filter", not "there is nothing to play",
      // so it must not offer a rescan as the cure.
      final filtered =
          controller.query.isNotEmpty ||
          controller.tagFilter.isNotEmpty ||
          controller.smartFilters.isNotEmpty;
      final query = controller.query;
      final detail = !filtered
          ? 'Try Rescan, or add a game by hand.'
          : query.isNotEmpty
          ? 'No game matches "$query".'
          : 'No game matches these filters.';
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtered ? Icons.search_off : Icons.videogame_asset_off,
              size: 44,
              color: palette.textDim,
            ),
            const SizedBox(height: 14),
            Text(
              filtered ? 'No matches' : 'No games yet',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              style: TextStyle(color: palette.textDim, fontSize: 13),
            ),
          ],
        ),
      );
    }
    // A node per visible game, kept across rebuilds so focus survives a
    // re-sort; nodes of games that left the wall are let go here, before the
    // grid below forgets them.
    final ids = games.map((game) => game.id).toSet();
    _gridNodes.removeWhere((id, node) {
      if (ids.contains(id)) return false;
      node.dispose();
      return true;
    });
    _gridNodeIndex.clear();
    for (var index = 0; index < games.length; index++) {
      final node = _gridNodes.putIfAbsent(games[index].id, FocusNode.new);
      _gridNodeIndex[node] = index;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 18.0;
        const mainAxisSpacing = 22.0;
        final columns =
            ((constraints.maxWidth - 28 * 2 + spacing) /
                    (GameTile.width + spacing))
                .floor()
                .clamp(1, 12);
        _gridColumns = columns;
        final aspectRatio =
            GameTile.width /
            GameTile.heightFor(
              compact: false,
              textScaler: MediaQuery.textScalerOf(context),
            );
        // One row's height plus its gap: an arrow that lands past the built
        // viewport jumps by whole rows.
        final tileWidth =
            (constraints.maxWidth - 28 * 2 - spacing * (columns - 1)) / columns;
        _gridRowStride = tileWidth / aspectRatio + mainAxisSpacing;
        return GridView.builder(
          controller: _gridScroll,
          padding: const EdgeInsets.fromLTRB(28, 6, 28, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: mainAxisSpacing,
            crossAxisSpacing: spacing,
            childAspectRatio: aspectRatio,
          ),
          itemCount: games.length,
          itemBuilder: (context, index) {
            final game = games[index];
            final tile = GameTile(
              key: ValueKey(game.id),
              game: game,
              controller: controller,
              selected: controller.selected?.id == game.id,
              focusNode: _selecting ? null : _gridNodes[game.id],
            );
            return _selecting ? _selectableTile(game, tile) : tile;
          },
        );
      },
    );
  }

  Widget _statusBar(LibraryController controller, int shown) {
    final notice = controller.notice ?? controller.failure;
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 14),
      child: Row(
        // Both ends shrink and ellipsize, and `spaceBetween` keeps the notice
        // on the right: a long notice next to the counts used to overflow a
        // narrow column.
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              '$shown shown · ${controller.games.length} found · '
              '${controller.countsBySource.length} sources',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textDim, fontSize: 12),
            ),
          ),
          if (notice != null)
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    controller.failure == null
                        ? Icons.info_outline
                        : Icons.error_outline,
                    size: 14,
                    color: controller.failure == null
                        ? palette.textDim
                        : palette.warning,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      notice,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontSize: 12,
                        color: controller.failure == null
                            ? palette.textDim
                            : palette.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.controller});

  static const double width = 232;

  /// Width of the collapsed rail: one icon column plus its padding.
  static const double railWidth = 64;

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final collapsed = controller.config.sidebarCollapsed;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: collapsed ? railWidth : width),
      duration: _LibraryPageState._motion,
      curve: _LibraryPageState._motionCurve,
      builder: (context, w, _) {
        // The content swaps halfway through the fold: the list would
        // overflow the rail's width, and the rail looks lost in the list's.
        final showRail = w < (width + railWidth) / 2;
        return Container(
          width: w,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(color: context.palette.sidebar),
          child: showRail ? _rail(context) : _list(context),
        );
      },
    );
  }

  Widget _list(BuildContext context) {
    final counts = controller.countsBySource;
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 26, 12, 20),
          child: Row(
            children: [
              Icon(Icons.sports_esports, color: palette.accent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Omni Launcher',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              _toggle(context, collapsed: false),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _row(
                context,
                icon: Icons.apps,
                label: 'All games',
                count: controller.games.length,
                selected: controller.sourceFilter.isEmpty,
                onTap: controller.clearSources,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 16, 10, 8),
                child: Text(
                  'SOURCES',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    color: palette.textDim,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final kind in SourceKind.values)
                if ((counts[kind] ?? 0) > 0)
                  _row(
                    context,
                    icon: _iconFor(kind),
                    label: kind.label,
                    count: counts[kind]!,
                    selected: controller.sourceFilter.contains(kind),
                    onTap: () => controller.toggleSource(kind),
                  ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.surfaceHigh),
        // The rail paints its own colour, so the switch needs a Material of
        // its own for its ink and thumb to show up.
        Material(
          color: Colors.transparent,
          child: SwitchListTile(
            dense: true,
            value: controller.config.showHidden,
            onChanged: (_) => controller.toggleShowHidden(),
            title: const Text('Show hidden', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              '${controller.hiddenCount} hidden',
              style: TextStyle(fontSize: 11, color: palette.textDim),
            ),
          ),
        ),
      ],
    );
  }

  /// Collapsed: the same filters as icons, with the label and the count in the
  /// tooltip, so the cover wall gets the width back.
  Widget _rail(BuildContext context) {
    final counts = controller.countsBySource;
    final palette = context.palette;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 26, bottom: 10),
          child: _toggle(context, collapsed: true),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              _railRow(
                context,
                icon: Icons.apps,
                tooltip: 'All games · ${controller.games.length}',
                selected: controller.sourceFilter.isEmpty,
                onTap: controller.clearSources,
              ),
              const SizedBox(height: 8),
              for (final kind in SourceKind.values)
                if ((counts[kind] ?? 0) > 0)
                  _railRow(
                    context,
                    icon: _iconFor(kind),
                    tooltip: '${kind.label} · ${counts[kind]}',
                    selected: controller.sourceFilter.contains(kind),
                    onTap: () => controller.toggleSource(kind),
                  ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.surfaceHigh),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: IconButton(
            tooltip: controller.config.showHidden
                ? 'Hide the hidden games'
                : 'Show hidden games (${controller.hiddenCount})',
            isSelected: controller.config.showHidden,
            icon: Icon(
              controller.config.showHidden
                  ? Icons.visibility
                  : Icons.visibility_off_outlined,
            ),
            onPressed: controller.toggleShowHidden,
          ),
        ),
      ],
    );
  }

  /// The control that folds the sidebar, drawn on whichever side it is now.
  Widget _toggle(BuildContext context, {required bool collapsed}) {
    return IconButton(
      tooltip: collapsed ? 'Expand the sidebar' : 'Collapse the sidebar',
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      visualDensity: VisualDensity.compact,
      icon: Icon(collapsed ? Icons.chevron_right : Icons.chevron_left),
      onPressed: controller.toggleSidebar,
    );
  }

  Widget _railRow(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: selected ? palette.surfaceHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: SizedBox(
              height: 40,
              child: Center(
                child: Icon(
                  icon,
                  size: 18,
                  color: selected ? palette.accentSoft : palette.textDim,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String label,
    required int count,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? context.palette.surfaceHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: selected
                      ? context.palette.accentSoft
                      : context.palette.textDim,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.palette.textDim,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(SourceKind kind) => switch (kind) {
    SourceKind.manual => Icons.edit_note,
    SourceKind.steam => Icons.cloud,
    SourceKind.flatpak => Icons.inventory_2_outlined,
    SourceKind.appimage => Icons.terminal,
    SourceKind.heroic => Icons.auto_awesome,
    SourceKind.epic => Icons.sports_esports_outlined,
    SourceKind.lutris => Icons.wine_bar,
    SourceKind.faugus => Icons.sports_martial_arts,
    SourceKind.prism => Icons.widgets_outlined,
    SourceKind.bottles => Icons.liquor,
    SourceKind.desktop => Icons.desktop_windows_outlined,
  };
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _RescanIntent extends Intent {
  const _RescanIntent();
}

class _PaletteIntent extends Intent {
  const _PaletteIntent();
}

class _ClearIntent extends Intent {
  const _ClearIntent();
}
