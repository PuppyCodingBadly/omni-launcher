import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/game.dart';
import '../state/library_controller.dart';
import 'detail_panel.dart';
import 'game_tile.dart';
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
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final games = controller.visibleGames;
    // The shelf is a shortcut to what was just played. While a search is
    // running the wall already shows the matches, so it steps aside rather
    // than repeating a few of them.
    final recent = controller.query.isEmpty
        ? controller.recentlyPlayed()
        : const <Game>[];
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FocusSearchIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            const _RescanIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const _ClearIntent(),
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
          _ClearIntent: CallbackAction<_ClearIntent>(
            onInvoke: (_) {
              controller.select(null);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Sidebar(controller: controller),
                Expanded(
                  child: Column(
                    children: [
                      _header(controller),
                      if (recent.isNotEmpty) _shelf(controller, recent),
                      Expanded(child: _grid(controller, games)),
                      _statusBar(controller, games.length),
                    ],
                  ),
                ),
                if (controller.selected != null)
                  DetailPanel(controller: controller, game: controller.selected!),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(LibraryController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              onChanged: controller.setQuery,
              decoration: InputDecoration(
                hintText: 'Search ${controller.games.length} games',
                prefixIcon: Icon(Icons.search, color: context.palette.textDim),
                suffixIcon: controller.query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _search.clear();
                          controller.setQuery('');
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          IconButton.filledTonal(
            tooltip: 'Rescan (Ctrl+R)',
            onPressed: controller.rescan,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Add a game by hand',
            onPressed: () async {
              final entry = await showAddGameDialog(context);
              if (entry != null) {
                await controller.addManual(entry.name, entry.command, cwd: entry.cwd);
              }
            },
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsView(controller: controller),
              ),
            ),
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
    );
  }

  /// The recently played shelf: the last few games, newest first, as one
  /// scrolling row of small covers above the wall.
  Widget _shelf(LibraryController controller, List<Game> games) {
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
          height: GameTile.heightFor(compact: true),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 28),
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videogame_asset_off, size: 44, color: palette.textDim),
            const SizedBox(height: 14),
            Text(
              controller.query.isEmpty
                  ? 'Nothing found. Try Rescan, or add a game by hand.'
                  : 'No game matches "${controller.query}".',
              style: TextStyle(color: palette.textDim),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 18.0;
        final columns =
            ((constraints.maxWidth - 28 * 2 + spacing) / (GameTile.width + spacing))
                .floor()
                .clamp(1, 12);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(28, 6, 28, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 22,
            crossAxisSpacing: spacing,
            childAspectRatio: GameTile.width / GameTile.heightFor(compact: false),
          ),
          itemCount: games.length,
          itemBuilder: (context, index) {
            final game = games[index];
            return GameTile(
              key: ValueKey(game.id),
              game: game,
              controller: controller,
              selected: controller.selected?.id == game.id,
            );
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
              child: Text(
                notice,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 12,
                  color: controller.failure == null ? palette.textDim : palette.warning,
                ),
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
    return Container(
      width: collapsed ? railWidth : width,
      color: context.palette.sidebar,
      child: collapsed ? _rail(context) : _list(context),
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
                  color: selected ? context.palette.accentSoft : context.palette.textDim,
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
                  style: TextStyle(fontSize: 12, color: context.palette.textDim),
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
    SourceKind.desktop => Icons.desktop_windows_outlined,
  };
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _RescanIntent extends Intent {
  const _RescanIntent();
}

class _ClearIntent extends Intent {
  const _ClearIntent();
}
