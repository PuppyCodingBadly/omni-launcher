import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../covers.dart';
import '../model/game.dart';
import '../state/library_controller.dart';
import 'playtime.dart';
import 'rename_dialog.dart';
import 'theme.dart';

/// The tile's one motion language: hover, focus, press and the artwork's
/// fade-in all settle on the same fast ease-out, so the pointer, the keyboard
/// and the gamepad read as the same gesture.
const _motionDuration = Duration(milliseconds: 150);
const _motionCurve = Curves.easeOutCubic;

/// The hover overlay (Play, ⋮) arrives a touch quicker than the lift itself.
const _overlayDuration = Duration(milliseconds: 120);

/// How much a hovered or focused tile grows, and how much a pressed one
/// gives: small enough that the wall never feels jumpy.
const _hoverScale = 1.03;
const _pressScale = 0.98;

/// One cover tile: the wall's, or the recently played shelf's small one.
class GameTile extends StatefulWidget {
  const GameTile({
    super.key,
    required this.game,
    required this.controller,
    required this.selected,
    this.compact = false,
    this.focusNode,
  });

  /// The wall's tile: the 2:3 poster shape the covers are.
  static const double width = 168;
  static const double coverHeight = 252;

  /// The shelf's tile: small enough that a row of them fits above the wall
  /// without taking the wall's room.
  static const double compactWidth = 116;
  static const double compactCoverHeight = 174;

  /// How tall a tile draws: the cover, then the name and the subtitle under it.
  ///
  /// The lines follow the platform's text scale, so [textScaler] has to as
  /// well: the shelf's strip is this number, and a strip that ignored a
  /// large-text desktop would clip its own labels. The wall follows it through
  /// the grid's aspect ratio.
  static double heightFor({
    required bool compact,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    final cover = compact ? compactCoverHeight : coverHeight;
    final name = (compact ? 12.5 : 14.0) * 1.2 * (compact ? 1 : 2);
    final subtitle = (compact ? 11.0 : 12.0) * 1.2;
    // The cover, the air above the label, the two lines, the air below them.
    return cover +
        (compact ? 8 : 10) +
        textScaler.scale(name) +
        textScaler.scale(subtitle) +
        2 +
        8;
  }

  final Game game;
  final LibraryController controller;
  final bool selected;

  /// The shelf's size: one line of name, and how much and how recently the game
  /// was played in place of its source.
  final bool compact;

  /// Focus for keyboard and gamepad traversal: the page hands each tile a
  /// node so arrow keys can walk the wall. Null leaves the tile focusable on
  /// its own, so a tile built without one still takes focus and keys.
  final FocusNode? focusNode;

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
  bool _focused = false;
  bool _pressed = false;
  bool _requested = false;

  /// Pointer hover and focus draw identically: a tile the cursor is on and a
  /// tile the gamepad is on should be indistinguishable.
  bool get _highlighted => _hovered || _focused;

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
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${game.name}, ${_subtitle(game)}',
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const {
          // Enter launches, Space selects; the gamepad's A launches, B
          // selects, matching what its buttons mean on a console dashboard.
          SingleActivator(LogicalKeyboardKey.enter): _LaunchIntent(),
          SingleActivator(LogicalKeyboardKey.space): _SelectIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): _LaunchIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonB): _SelectIntent(),
        },
        actions: {
          _SelectIntent: CallbackAction<_SelectIntent>(
            onInvoke: (_) {
              widget.controller.select(game);
              return null;
            },
          ),
          _LaunchIntent: CallbackAction<_LaunchIntent>(
            onInvoke: (_) {
              widget.controller.launch(game);
              return null;
            },
          ),
        },
        // The overlay is a pointer affordance, not a focus highlight: it must
        // follow the mouse even when the app is in touch highlight mode, so
        // hover is tracked here and not through onShowHoverHighlight.
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
          onTap: () => widget.controller.select(game),
          onDoubleTap: () => widget.controller.launch(game),
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedOpacity(
            duration: _motionDuration,
            opacity: hidden ? 0.45 : 1,
            child: AnimatedScale(
              scale: _pressed
                  ? _pressScale
                  : _highlighted
                  ? _hoverScale
                  : 1,
              duration: _motionDuration,
              curve: _motionCurve,
              // A tile's hover repaints (shadow, scrim, scale) stay inside the
              // tile: without the boundary a blur this size would drag the
              // neighbouring covers into the same repaint.
              child: RepaintBoundary(
                // The strip is a horizontal list, which hands a tile as much
                // width as it asks for: without this the labels decide the
                // tile's width, and a long name widens it past its cover
                // instead of trailing off.
                child: SizedBox(
                  width: widget.tileWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Cover(
                        artwork: _artwork,
                        name: game.name,
                        highlighted: _highlighted,
                        selected: widget.selected,
                        favorite: widget.controller.isFavorite(game.id),
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
            ),
          ),
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
          case 'favorite':
            widget.controller.toggleFavorite(game.id);
          case 'remove':
            widget.controller.removeManual(game.key);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'launch', child: Text('Launch')),
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'folder', child: Text('Open folder')),
        PopupMenuItem(value: 'hide', child: Text(hidden ? 'Unhide' : 'Hide')),
        PopupMenuItem(
          value: 'favorite',
          child: Text(
            widget.controller.isFavorite(game.id)
                ? 'Unpin favorite'
                : 'Pin as favorite',
          ),
        ),
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
    required this.highlighted,
    required this.selected,
    required this.favorite,
    required this.themeIcon,
    required this.onPlay,
    required this.menu,
    required this.width,
    required this.height,
    required this.compact,
  });

  final Artwork artwork;
  final String name;

  /// Hovered by the pointer or focused by keyboard/gamepad; both draw the
  /// same lifted cover.
  final bool highlighted;
  final bool selected;
  final bool favorite;

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
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return AnimatedContainer(
      duration: _motionDuration,
      curve: _motionCurve,
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? palette.accent : Colors.transparent,
          width: 2,
        ),
        boxShadow: [palette.coverShadow(hovered: highlighted)],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _artwork(palette, dpr),
          if (favorite)
            Positioned(
              top: 8,
              left: 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: palette.scrim.first,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.star_rounded,
                    size: 14,
                    color: palette.onScrim,
                  ),
                ),
              ),
            ),
          IgnorePointer(
            ignoring: !highlighted,
            child: AnimatedOpacity(
              duration: _overlayDuration,
              curve: _motionCurve,
              opacity: highlighted ? 1 : 0,
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
                    child: AnimatedSlide(
                      offset: highlighted ? Offset.zero : const Offset(0, -0.25),
                      duration: _overlayDuration,
                      curve: _motionCurve,
                      child: Padding(padding: const EdgeInsets.all(2), child: menu),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedSlide(
                      offset: highlighted ? Offset.zero : const Offset(0, 0.25),
                      duration: _overlayDuration,
                      curve: _motionCurve,
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
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _artwork(AppPalette palette, double dpr) {
    switch (artwork.kind) {
      case ArtworkKind.cover:
        return Image.file(
          File(artwork.value!),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          // Decode at the pixels the tile actually shows: covers are
          // screenshots or scans, and decoding them at full size is the
          // wall's one big memory cost.
          cacheWidth: (width * dpr).round(),
          cacheHeight: (height * dpr).round(),
          semanticLabel: 'Cover art for $name',
          frameBuilder: _fadeIn,
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
              cacheWidth: (width * dpr).round(),
              cacheHeight: (height * dpr).round(),
              semanticLabel: 'Icon for $name',
              frameBuilder: _fadeIn,
              errorBuilder: (context, error, stack) => _letter(palette),
            ),
          ),
        );
      case ArtworkKind.letter:
        return _letter(palette);
    }
  }

  /// Artwork fades in instead of popping: the wall resolves covers a few at a
  /// time, and hard pops all over the grid read as flicker.
  static Widget _fadeIn(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSynchronouslyLoaded,
  ) {
    if (wasSynchronouslyLoaded) return child;
    return AnimatedOpacity(
      opacity: frame == null ? 0 : 1,
      duration: _motionDuration,
      curve: _motionCurve,
      child: child,
    );
  }

  // The letter stands in for artwork; the tile's own Semantics label already
  // names the game, so reading the initial aloud would only repeat it.
  Widget _letter(AppPalette palette) => ExcludeSemantics(
    child: Center(
      child: Text(
        name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
        style: TextStyle(
          fontSize: compact ? 40 : 54,
          fontWeight: FontWeight.w800,
          color: palette.tileLetter,
        ),
      ),
    ),
  );
}

/// The tile's keyboard/gamepad vocabulary: select is what a tap does, launch
/// is what a double-tap (or the gamepad's A button) does.
class _SelectIntent extends Intent {
  const _SelectIntent();
}

class _LaunchIntent extends Intent {
  const _LaunchIntent();
}
