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
    final palette = context.palette;
    final hidden = controller.config.isHidden(game.id);
    final favorite = controller.isFavorite(game.id);
    final artwork = controller.covers.resolve(game);
    final running = controller.isRunning(game.id);
    final stopping = controller.isStopping(game.id);
    final quickExit = controller.quickExitFor(game.id);
    final tags = controller.tagsFor(game);
    final options = controller.config.launchOptionsFor(game.id);
    final played = formatPlaytime(controller.playtimeOf(game.id));
    // The page's row lets the panel pick its own width, so the room a narrow
    // window offers is read from the MediaQuery rather than the constraints;
    // the page can also hand a smaller [width] in when it knows better.
    final resolvedWidth = math.min(
      width,
      MediaQuery.sizeOf(context).width * _widthFraction,
    );
    return Container(
      width: resolvedWidth,
      decoration: BoxDecoration(
        color: palette.sidebar,
        border: Border(left: BorderSide(color: palette.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 46,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      game.source.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: palette.textDim),
                    ),
                  ),
                  IconButton(
                    tooltip: favorite ? 'Unpin favorite' : 'Pin as favorite',
                    icon: Icon(
                      favorite ? Icons.star_rounded : Icons.star_border_rounded,
                      size: 18,
                      color: favorite ? palette.accent : palette.textDim,
                    ),
                    onPressed: () => controller.toggleFavorite(game.id),
                  ),
                  _actionsMenu(context, hidden),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => controller.select(null),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 20),
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final identity = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          game.name,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          game.displaySubtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.textDim),
                        ),
                        if (hidden ||
                            running ||
                            game.updating ||
                            game.updateRequired ||
                            game.broken) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 5,
                            children: [
                              if (hidden)
                                _statusChip(
                                  context,
                                  'Hidden',
                                  color: palette.textDim,
                                ),
                              if (running)
                                _statusChip(
                                  context,
                                  'Playing',
                                  color: palette.accent,
                                ),
                              if (game.updating)
                                _statusChip(context, 'Updating'),
                              if (game.updateRequired)
                                _statusChip(context, 'Update required'),
                              if (game.broken)
                                _statusChip(context, 'Files missing'),
                            ],
                          ),
                        ],
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Icon(
                              Icons.schedule,
                              size: 13,
                              color: palette.textDim,
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                '$played played',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: palette.textDim),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                    // A panel in a very narrow window has no room beside the
                    // poster: the identity block moves under it instead of
                    // squeezing the title into a sliver.
                    if (constraints.maxWidth < 300) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: 84,
                              child: _preview(context, artwork),
                            ),
                          ),
                          const SizedBox(height: 12),
                          identity,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 112, child: _preview(context, artwork)),
                        const SizedBox(width: 14),
                        Expanded(child: identity),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: running
                      ? FilledButton.icon(
                          onPressed: stopping
                              ? null
                              : () => controller.stop(game),
                          icon: const Icon(Icons.stop_rounded, size: 18),
                          label: Text(stopping ? 'Stopping…' : 'Stop'),
                          style: FilledButton.styleFrom(
                            backgroundColor: palette.warning,
                            foregroundColor: Colors.white,
                          ),
                        )
                      : FilledButton.icon(
                          onPressed: game.launchable
                              ? () => controller.launch(game)
                              : null,
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: Text(game.broken ? 'Files missing' : 'Launch'),
                        ),
                ),
                if (quickExit != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 15,
                        color: palette.warning,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          'Exited after ${_duration(quickExit)}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.warning),
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
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in tags)
                        Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact,
                          labelStyle: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(fontSize: 11, color: palette.text),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                for (final plugin in controller.plugins)
                  if (controller.pluginHasSection(plugin)) ...[
                    PluginSection(
                      controller: controller,
                      game: game,
                      plugin: plugin,
                    ),
                    const SizedBox(height: 12),
                  ],
                LabelledValue(label: 'Played', value: played),
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
      icon: Icon(Icons.more_horiz, size: 20, color: context.palette.textDim),
      onSelected: (value) async {
        switch (value) {
          case 'folder':
            await controller.openFolder(game);
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
          case 'unrecent':
            controller.setRecentlyPlayedHidden(
              game,
              hidden: !controller.config.isRecentHidden(game.id),
            );
          case 'remove':
            await controller.removeManual(game.key);
        }
      },
      itemBuilder: (context) => [
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
        if (controller.lastPlayedFor(game.id) != null ||
            controller.config.isRecentHidden(game.id))
          _action(
            context,
            'unrecent',
            Icons.history_toggle_off,
            controller.config.isRecentHidden(game.id)
                ? 'Show in recently played'
                : 'Remove from recently played',
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

  Widget _statusChip(BuildContext context, String label, {Color? color}) {
    final palette = context.palette;
    final tint = color ?? palette.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: AppRadius.smallAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: tint, fontWeight: FontWeight.w600),
          ),
        ],
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
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: AppRadius.mediumAll,
        border: Border.all(color: palette.line),
      ),
      child: AspectRatio(
        // The poster's own shape: a wide box would crop the art the tile shows.
        aspectRatio: 2 / 3,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final letter = ExcludeSemantics(
              child: Center(
                child: Text(
                  game.name.isEmpty ? '?' : game.name.substring(0, 1),
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w700,
                    color: palette.previewLetter,
                  ),
                ),
              ),
            );
            if (path == null) return letter;
            return Image.file(
              File(path),
              fit: BoxFit.cover,
              // Decode at the pixels the preview shows: the full poster is
              // several times this size and only one panel is open.
              cacheWidth: (constraints.maxWidth * dpr).round(),
              cacheHeight: (constraints.maxHeight * dpr).round(),
              semanticLabel: 'Cover art for ${game.name}',
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                // Artwork fades in instead of popping.
                if (wasSynchronouslyLoaded) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  child: child,
                );
              },
              errorBuilder: (context, error, stack) => letter,
            );
          },
        ),
      ),
    );
  }

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
