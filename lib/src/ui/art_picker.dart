import 'package:flutter/material.dart';

import '../art/steamgriddb.dart';
import '../model/game.dart';
import '../state/library_controller.dart';
import 'theme.dart';

/// Pick cover art for [game] from SteamGridDB.
Future<void> showArtPicker(
  BuildContext context,
  LibraryController controller,
  Game game,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ArtPickerDialog(controller: controller, game: game),
  );
}

class _ArtPickerDialog extends StatefulWidget {
  const _ArtPickerDialog({required this.controller, required this.game});

  final LibraryController controller;
  final Game game;

  @override
  State<_ArtPickerDialog> createState() => _ArtPickerDialogState();
}

class _ArtPickerDialogState extends State<_ArtPickerDialog> {
  late Future<List<SgdbGrid>> _candidates;
  bool _applying = false;

  /// The candidate a tap is applying right now: it wears the accent ring
  /// until the download resolves.
  SgdbGrid? _applyingGrid;

  /// Why the last pick failed, shown inside the dialog: the status bar is
  /// hidden behind the modal, so a failure there would look like nothing
  /// happened at all.
  String? _failure;

  @override
  void initState() {
    super.initState();
    _candidates = widget.controller.searchArt(widget.game);
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = widget.controller.covers.settings.sgdbEnabled;
    return Dialog(
      backgroundColor: context.palette.surface,
      insetPadding: const EdgeInsets.all(40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Artwork for ${widget.game.name}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_applying)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                hasKey
                    ? 'SteamGridDB grids, best match first.'
                    : 'SteamGridDB needs an API key.',
                style: TextStyle(
                  color: context.palette.textDim,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(child: hasKey ? _results() : _noKey()),
              if (_failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: context.palette.warning,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _failure!,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: context.palette.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              if (widget.controller.covers.overrideFor(widget.game) != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      widget.controller.clearArt(widget.game);
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Reset to automatic artwork'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noKey() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Text(
      'Add your key under Settings → Artwork. You can create one at '
      'steamgriddb.com/profile/preferences/api.',
      style: TextStyle(color: context.palette.textDim),
    ),
  );

  Widget _results() => FutureBuilder<List<SgdbGrid>>(
    future: _candidates,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return Text(
          '${snapshot.error}',
          style: TextStyle(color: context.palette.warning),
        );
      }
      final grids = snapshot.data ?? const <SgdbGrid>[];
      if (grids.isEmpty) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'No artwork found on SteamGridDB for this game.',
            style: TextStyle(color: context.palette.textDim),
          ),
        );
      }
      return GridView.builder(
        // Portrait cells, the shape a cover wall shows: a square cell would
        // crop a third off the side of the grids the wall wants.
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 2 / 3,
        ),
        itemCount: grids.length,
        itemBuilder: (context, index) => _candidate(grids[index]),
      );
    },
  );

  Widget _candidate(SgdbGrid grid) {
    final palette = context.palette;
    final applying = identical(grid, _applyingGrid);
    return Tooltip(
      message: [
        if (grid.style != null) grid.style!,
        if (grid.width != null && grid.height != null)
          '${grid.width}x${grid.height}',
        if (grid.author != null) 'by ${grid.author}',
      ].join(' · '),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _applying ? null : () => _apply(grid),
        // The ring follows the tile's selected-cover treatment — same curve,
        // same speed — so picking art feels like selecting a game.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: applying ? palette.accent : Colors.transparent,
              width: 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              color: palette.surfaceHigh,
              child: LayoutBuilder(
                builder: (context, constraints) => Image.network(
                  grid.thumb,
                  fit: BoxFit.cover,
                  // Decode at the pixels the cell actually shows.
                  cacheWidth:
                      (constraints.maxWidth *
                              MediaQuery.devicePixelRatioOf(context))
                          .round(),
                  cacheHeight:
                      (constraints.maxHeight *
                              MediaQuery.devicePixelRatioOf(context))
                          .round(),
                  semanticLabel: 'Artwork candidate for ${widget.game.name}',
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                  errorBuilder: (context, error, stack) => Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: palette.textDim,
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

  Future<void> _apply(SgdbGrid grid) async {
    setState(() {
      _applying = true;
      _applyingGrid = grid;
      _failure = null;
    });
    try {
      final ok = await widget.controller.applyArt(widget.game, grid);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _failure =
            widget.controller.failure ??
            'That artwork could not be downloaded.';
      });
    } catch (error) {
      // Nothing may leave the dialog stuck on "applying": every candidate
      // would stay unclickable.
      if (!mounted) return;
      setState(() => _failure = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _applying = false;
          _applyingGrid = null;
        });
      }
    }
  }
}
