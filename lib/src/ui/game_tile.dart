import 'dart:io';

import 'package:flutter/material.dart';

import '../covers.dart';
import '../model/game.dart';
import '../state/library_controller.dart';
import 'playtime.dart';
import 'rename_dialog.dart';
import 'theme.dart';

/// One cover tile: the wall's, or the recently played shelf's small one.
class GameTile extends StatefulWidget {
  const GameTile({
    super.key,
    required this.game,
    required this.controller,
    required this.selected,
    this.compact = false,
  });

  /// The wall's tile: the 2:3 poster shape the covers are.
  static const double width = 168;
  static const double coverHeight = 252;

  /// The shelf's tile: small enough that a row of them fits above the wall
  /// without taking the wall's room.
  static const double compactWidth = 116;
  static const double compactCoverHeight = 174;

  /// How tall a tile draws, cover and label included. The grid sizes its rows
  /// with this, the shelf its strip.
  static double heightFor({required bool compact}) =>
      (compact ? compactCoverHeight : coverHeight) + (compact ? 44 : 68);

  final Game game;
  final LibraryController controller;
  final bool selected;

  /// The shelf's size: one line of name, and how much and how recently the game
  /// was played in place of its source.
  final bool compact;

  double get tileWidth => compact ? compactWidth : width;

  double get tileHeight => compact ? compactCoverHeight : coverHeight;

  @override
  State<GameTile> createState() => _GameTileState();
}

class _GameTileState extends State<GameTile> {
  late Artwork _artwork;

  /// The pinned artwork [_artwork] was resolved with, so a pick made for this
  /// game is noticed even though its id has not changed.
  String? _pinned;
  bool _hovered = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _artwork = widget.controller.covers.resolve(widget.game);
    _pinned = widget.controller.covers.overrideFor(widget.game);
    _maybeFetch();
  }

  @override
  void didUpdateWidget(covariant GameTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pinned = widget.controller.covers.overrideFor(widget.game);
    // A different game, or a new pick for this game: both change what the tile
    // should draw.
    if (oldWidget.game.id != widget.game.id || pinned != _pinned) {
      _artwork = widget.controller.covers.resolve(widget.game);
      _pinned = pinned;
      _requested = false;
      _maybeFetch();
    }
  }

  void _maybeFetch() {
    if (_requested || !_artwork.pending) return;
    _requested = true;
    widget.controller.requestCoverArt(widget.game).then((artwork) {
      if (!mounted || artwork == null) return;
      setState(() => _artwork = artwork);
    });
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final hidden = widget.controller.config.isHidden(game.id);
    final palette = context.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.controller.select(game),
        onDoubleTap: () => widget.controller.launch(game),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: hidden ? 0.45 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Cover(
                artwork: _artwork,
                name: game.name,
                hovered: _hovered,
                selected: widget.selected,
                themeIcon: widget.controller.covers.themeIconPath,
                onPlay: () => widget.controller.launch(game),
                menu: _menu(context, game, hidden),
                width: widget.tileWidth,
                height: widget.tileHeight,
                compact: widget.compact,
              ),
              SizedBox(height: widget.compact ? 8 : 10),
              Text(
                game.name,
                maxLines: widget.compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: widget.compact ? 12.5 : 14,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _subtitle(game),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.textDim,
                  fontSize: widget.compact ? 11 : 12,
                  height: widget.compact ? 1.2 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The line under the name: the game's source on the wall, and on the shelf
  /// how much it was played and how recently.
  String _subtitle(Game game) {
    if (!widget.compact) return game.displaySubtitle;
    final played = formatPlaytime(widget.controller.playtimeOf(game.id));
    final last = widget.controller.lastPlayedFor(game.id);
    // A shelf entry is always a played game, but the tile itself does not have
    // to be: without a stamp the time played is all there is to say.
    if (last == null) return played;
    return '$played · ${formatLastPlayed(last, DateTime.now())}';
  }

  Widget _menu(BuildContext context, Game game, bool hidden) {
    return PopupMenuButton<String>(
      tooltip: 'Actions',
      icon: Icon(Icons.more_vert, size: 18, color: context.palette.onScrim),
      onSelected: (value) {
        switch (value) {
          case 'launch':
            widget.controller.launch(game);
          case 'rename':
            _rename(context, game);
          case 'folder':
            widget.controller.openFolder(game);
          case 'hide':
            widget.controller.setHidden(game, hidden: !hidden);
          case 'remove':
            widget.controller.removeManual(game.key);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'launch', child: Text('Launch')),
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'folder', child: Text('Open folder')),
        PopupMenuItem(value: 'hide', child: Text(hidden ? 'Unhide' : 'Hide')),
        if (game.source == SourceKind.manual)
          const PopupMenuItem(value: 'remove', child: Text('Remove')),
      ],
    );
  }

  Future<void> _rename(BuildContext context, Game game) async {
    final choice = await showRenameGameDialog(
      context,
      currentName: game.name,
      discoveredName: widget.controller.discoveredNameFor(game.id),
    );
    if (choice == null) return;
    widget.controller.setName(game.id, choice.reset ? null : choice.name);
  }
}

class _Cover extends StatelessWidget {
  const _Cover({
    required this.artwork,
    required this.name,
    required this.hovered,
    required this.selected,
    required this.themeIcon,
    required this.onPlay,
    required this.menu,
    required this.width,
    required this.height,
    required this.compact,
  });

  final Artwork artwork;
  final String name;
  final bool hovered;
  final bool selected;

  /// Resolves an icon-theme name to a raster file.
  final String? Function(String name) themeIcon;
  final VoidCallback onPlay;
  final Widget menu;
  final double width;
  final double height;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? palette.accent : Colors.transparent,
          width: 2,
        ),
        boxShadow: [palette.coverShadow(hovered: hovered)],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _artwork(palette),
          IgnorePointer(
            ignoring: !hovered,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: hovered ? 1 : 0,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The scrim must never swallow a click meant for the tile.
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: palette.scrim,
                          stops: const [0, 0.45, 1],
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(padding: const EdgeInsets.all(2), child: menu),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 10 : 12),
                      // A labelled button has no room on a shelf tile: the cover
                      // itself is the target there.
                      child: compact
                          ? IconButton.filled(
                              tooltip: 'Play',
                              onPressed: onPlay,
                              icon: const Icon(Icons.play_arrow_rounded, size: 20),
                            )
                          : SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: onPlay,
                                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                                label: const Text('Play'),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _artwork(AppPalette palette) {
    switch (artwork.kind) {
      case ArtworkKind.cover:
        return Image.file(
          File(artwork.value!),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (context, error, stack) => _letter(palette),
        );
      case ArtworkKind.icon:
        final path = artwork.isName ? themeIcon(artwork.value!) : artwork.value;
        if (path == null) return _letter(palette);
        return Center(
          child: Padding(
            padding: EdgeInsets.all(compact ? 18 : 28),
            child: Image.file(
              File(path),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              errorBuilder: (context, error, stack) => _letter(palette),
            ),
          ),
        );
      case ArtworkKind.letter:
        return _letter(palette);
    }
  }

  Widget _letter(AppPalette palette) => Center(
    child: Text(
      name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
      style: TextStyle(
        fontSize: compact ? 40 : 54,
        fontWeight: FontWeight.w800,
        color: palette.tileLetter,
      ),
    ),
  );
}
