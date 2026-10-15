import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../art/steamgriddb.dart';
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
    // The poster shape follows the window: a square-ish window gets square
    // posters, a wide one keeps the portrait covers it always had.
    final window = MediaQuery.sizeOf(context);
    final shape = GridShape.forAspect(window.width / window.height);
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
                      Expanded(child: _grid(controller, games, shape)),
                      _statusBar(controller, games.length),
                    ],
                  ),
                ),
                if (controller.selected != null)
                  DetailPanel(
                    controller: controller,
                    game: controller.selected!,
                    shape: shape,
                  ),
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

  Widget _grid(LibraryController controller, List<Game> games, GridShape shape) {
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
            childAspectRatio: GameTile.width / (GameTile.coverHeightFor(shape) + 68),
          ),
          itemCount: games.length,
          itemBuilder: (context, index) {
            final game = games[index];
            return GameTile(
              key: ValueKey(game.id),
              game: game,
              controller: controller,
              selected: controller.selected?.id == game.id,
              shape: shape,
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

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final counts = controller.countsBySource;
    final palette = context.palette;
    return Container(
      width: 232,
      color: palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
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
