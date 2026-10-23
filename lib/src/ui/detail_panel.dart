import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../covers.dart';
import '../model/game.dart';
import '../state/library_controller.dart';
import 'art_picker.dart';
import 'field.dart';
import 'launch_log.dart';
import 'launch_options_dialog.dart';
import 'playtime.dart';
import 'plugin_answer.dart';
import 'rename_dialog.dart';
import 'tag_dialog.dart';
import 'theme.dart';

/// Right hand panel for the selected game.
class DetailPanel extends StatelessWidget {
  const DetailPanel({
    super.key,
    required this.controller,
    required this.game,
    this.width = defaultWidth,
  });

  /// The width the panel wants when the window has room for it.
  static const double defaultWidth = 360;

  /// The panel never takes more than this fraction of the room it is offered,
  /// so a small window keeps the wall wider than the panel.
  static const double _widthFraction = 0.42;

  final LibraryController controller;
  final Game game;

  /// The width to use when there is room for it; a narrow window shrinks the
  /// panel below this on its own, and the page may hand a smaller one in.
  final double width;

  @override
  Widget build(BuildContext context) {
    final hidden = controller.config.isHidden(game.id);
    final favorite = controller.isFavorite(game.id);
    final artwork = controller.covers.resolve(game);
    final running = controller.isRunning(game.id);
    final stopping = controller.isStopping(game.id);
    final quickExit = controller.quickExitFor(game.id);
    final tags = controller.tagsFor(game);
    final options = controller.config.launchOptionsFor(game.id);
    final storeUrl = controller.storeUrl(game);
    // The page's row lets the panel pick its own width, so the room a narrow
    // window offers is read from the MediaQuery rather than the constraints;
    // the page can also hand a smaller [width] in when it knows better.
    final resolvedWidth = math.min(
      width,
      MediaQuery.sizeOf(context).width * _widthFraction,
    );
    return Container(
      width: resolvedWidth,
      color: context.palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: favorite ? 'Unpin favorite' : 'Pin as favorite',
                icon: Icon(
                  favorite ? Icons.star_rounded : Icons.star_border_rounded,
                  size: 20,
                  color: favorite
                      ? context.palette.accent
                      : context.palette.textDim,
                ),
                onPressed: () => controller.toggleFavorite(game.id),
              ),
              _actionsMenu(context, hidden),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => controller.select(null),
                ),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                _preview(context, artwork),
                const SizedBox(height: 18),
                Text(
                  game.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _chip(context, game.displaySubtitle),
                    if (hidden) _chip(context, 'Hidden'),
                    if (running) _statusChip(context, 'Playing', accent: true),
                    if (game.missing) _statusChip(context, 'Not installed'),
                    if (game.updating) _statusChip(context, 'Updating'),
                    if (game.updateRequired)
                      _statusChip(context, 'Update required'),
                    if (game.broken) _statusChip(context, 'Files missing'),
                  ],
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in tags)
                        Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact,
                          labelStyle: const TextStyle(fontSize: 11.5),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (running)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: stopping ? null : () => controller.stop(game),
                      icon: const Icon(Icons.stop_rounded),
                      label: Text(stopping ? 'Stopping…' : 'Stop'),
                      style: FilledButton.styleFrom(
                        backgroundColor: context.palette.warning,
                      ),
                    ),
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: game.launchable
                          ? () => controller.launch(game)
                          : null,
                      icon: Icon(
                        game.missing
                            ? Icons.download_outlined
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(
                        game.missing
                            ? 'Not installed'
                            : game.broken
                            ? 'Files missing'
                            : 'Launch',
                      ),
                    ),
                  ),
                if (game.missing && storeUrl != null) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => controller.openStore(game),
                      icon: const Icon(Icons.storefront_outlined, size: 18),
                      label: const Text('Open store page'),
                    ),
                  ),
                ],
                if (quickExit != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: context.palette.warning,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Exited after ${_duration(quickExit)}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: context.palette.warning,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => showLaunchLogDialog(
                          context,
                          controller: controller,
                          game: game,
                        ),
                        child: const Text('View log'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                for (final plugin in controller.plugins)
                  if (controller.pluginHasSection(plugin)) ...[
                    PluginSection(
                      controller: controller,
                      game: game,
                      plugin: plugin,
                    ),
                    const SizedBox(height: 12),
                  ],
                LabelledValue(
                  label: 'Played',
                  value: formatPlaytime(controller.playtimeOf(game.id)),
                ),
                if (controller.lastPlayedFor(game.id) case final last?)
                  LabelledValue(
                    label: 'Last played',
                    value: formatLastPlayed(last, DateTime.now()),
                  ),
                LabelledValue(label: 'Source', value: game.source.label),
                LabelledValue(label: 'Id', value: game.id),
                if (game.path != null)
                  LabelledValue(label: 'Folder', value: game.path!),
                if (game.extra['size'] != null && game.extra['size'] != 0)
                  LabelledValue(
                    label: 'Size on disk',
                    value: _size(game.extra['size']),
                  ),
                if (game.extra['store'] != null)
                  LabelledValue(
                    label: 'Store',
                    value: '${game.extra['store']}',
                  ),
                if (game.extra['bytes_to_download'] case final total?)
                  LabelledValue(
                    label: 'Download',
                    value:
                        '${_size(game.extra['bytes_downloaded'] ?? 0)} of '
                        '${_size(total)}',
                  ),
                if (options.isNotEmpty)
                  LabelledValue(
                    label: 'Launch options',
                    value: options.summary,
                  ),
                LabelledValue(
                  label: 'Command',
                  value: controller.commandFor(game),
                  mono: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The panel's cog: every action that is not worth a permanent button.
  ///
  /// The menu keeps the panel's own context, so the dialogs it opens (rename,
  /// the art picker) still have the panel under them once the menu has closed.
  Widget _actionsMenu(BuildContext context, bool hidden) {
    return PopupMenuButton<String>(
      tooltip: 'Game actions',
      icon: Icon(Icons.settings, size: 20, color: context.palette.textDim),
      onSelected: (value) async {
        switch (value) {
          case 'folder':
            await controller.openFolder(game);
          case 'store':
            await controller.openStore(game);
          case 'copy':
            await Clipboard.setData(
              ClipboardData(text: controller.commandFor(game)),
            );
            controller.announce('Command copied');
          case 'art':
            await showArtPicker(context, controller, game);
          case 'rename':
            await _rename(context);
          case 'tags':
            await _editTags(context);
          case 'options':
            await _editOptions(context);
          case 'log':
            await showLaunchLogDialog(
              context,
              controller: controller,
              game: game,
            );
          case 'hide':
            controller.setHidden(game, hidden: !hidden);
          case 'forget':
            controller.forget(game);
          case 'remove':
            await controller.removeManual(game.key);
        }
      },
      itemBuilder: (context) => [
        if (controller.storeUrl(game) != null && game.missing)
          _action(
            context,
            'store',
            Icons.storefront_outlined,
            'Open store page',
          ),
        _action(context, 'folder', Icons.folder_open, 'Open folder'),
        _action(context, 'copy', Icons.copy_all, 'Copy command'),
        _action(context, 'options', Icons.tune, 'Launch options…'),
        _action(context, 'tags', Icons.label_outline, 'Edit tags…'),
        _action(context, 'art', Icons.image_search, 'Find art (SteamGridDB)'),
        _action(context, 'rename', Icons.edit_outlined, 'Rename'),
        _action(context, 'log', Icons.article_outlined, 'Launch log'),
        _action(
          context,
          'hide',
          hidden ? Icons.visibility : Icons.visibility_off,
          hidden ? 'Unhide' : 'Hide from library',
        ),
        if (game.missing)
          _action(
            context,
            'forget',
            Icons.delete_outline,
            'Remove from library',
          ),
        if (game.source == SourceKind.manual)
          _action(context, 'remove', Icons.delete_outline, 'Remove'),
      ],
    );
  }

  PopupMenuItem<String> _action(
    BuildContext context,
    String value,
    IconData icon,
    String label,
  ) => PopupMenuItem<String>(
    value: value,
    // A popup menu is at most 280 wide whatever the window is, so a long label
    // has to give way rather than overflow the row.
    child: Row(
      children: [
        Icon(icon, size: 18, color: context.palette.textDim),
        const SizedBox(width: 12),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    ),
  );

  Future<void> _rename(BuildContext context) async {
    final choice = await showRenameGameDialog(
      context,
      currentName: game.name,
      discoveredName: controller.discoveredNameFor(game.id),
    );
    if (choice == null) return;
    controller.setName(game.id, choice.reset ? null : choice.name);
  }

  Future<void> _editTags(BuildContext context) async {
    final tags = await showTagDialog(
      context,
      manual: controller.config.tagsFor(game.id),
      sourceTags: game.sourceTags,
    );
    if (tags == null) return;
    controller.setTags(game.id, tags);
  }

  Future<void> _editOptions(BuildContext context) async {
    final options = await showLaunchOptionsDialog(
      context,
      game: game,
      current: controller.config.launchOptionsFor(game.id),
    );
    if (options == null) return;
    controller.setLaunchOptions(game.id, options);
  }

  Widget _statusChip(
    BuildContext context,
    String label, {
    bool accent = false,
  }) {
    final palette = context.palette;
    final color = accent ? palette.accent : palette.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static String _duration(Duration duration) {
    if (duration.inSeconds < 1) return 'under a second';
    return '${duration.inSeconds}s';
  }

  Widget _preview(BuildContext context, Artwork artwork) {
    final palette = context.palette;
    final path = artwork.kind == ArtworkKind.cover
        ? artwork.value
        : (artwork.kind == ArtworkKind.icon
              ? (artwork.isName
                    ? controller.covers.themeIconPath(artwork.value!)
                    : artwork.value)
              : null);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        // The poster's own shape: a wide box would crop the art the tile shows
        // (and a square one is what this launcher just got rid of).
        aspectRatio: 2 / 3,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            return Container(
              color: palette.surface,
              child: path == null
                  // The panel's heading names the game already; the initial
                  // would only repeat it.
                  ? ExcludeSemantics(
                      child: Center(
                        child: Text(
                          game.name.isEmpty
                              ? '?'
                              : game.name.substring(0, 1).toUpperCase(),
                          style: TextStyle(
                            fontSize: 72,
                            fontWeight: FontWeight.w800,
                            color: palette.previewLetter,
                          ),
                        ),
                      ),
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          // Decode at the pixels the preview shows, like the
                          // tile does.
                          cacheWidth: (constraints.maxWidth * dpr).round(),
                          cacheHeight: (constraints.maxHeight * dpr).round(),
                          semanticLabel: 'Cover art for ${game.name}',
                          frameBuilder:
                              (context, child, frame, wasSynchronouslyLoaded) {
                                // Artwork fades in instead of popping.
                                if (wasSynchronouslyLoaded) return child;
                                return AnimatedOpacity(
                                  opacity: frame == null ? 0 : 1,
                                  duration: const Duration(milliseconds: 150),
                                  curve: Curves.easeOutCubic,
                                  child: child,
                                );
                              },
                          errorBuilder: (context, error, stack) =>
                              const SizedBox.shrink(),
                        ),
                        // The art settles into the panel's surface at the
                        // bottom, so the name and chips under a busy cover
                        // keep their footing.
                        IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  palette.surface.withValues(alpha: 0),
                                  palette.surface.withValues(alpha: 0.55),
                                ],
                                stops: const [0.55, 1],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: context.palette.surfaceHigh,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, color: context.palette.textDim),
    ),
  );

  static String _size(Object? bytes) {
    final value = bytes is int ? bytes : int.tryParse('$bytes') ?? 0;
    if (value <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = value.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}
