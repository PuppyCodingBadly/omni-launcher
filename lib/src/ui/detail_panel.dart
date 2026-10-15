import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../covers.dart';
import '../launcher.dart';
import '../model/game.dart';
import '../state/library_controller.dart';
import 'art_picker.dart';
import 'playtime.dart';
import 'rename_dialog.dart';
import 'theme.dart';

/// Right hand panel for the selected game.
class DetailPanel extends StatelessWidget {
  const DetailPanel({
    super.key,
    required this.controller,
    required this.game,
  });

  static const double width = 360;

  final LibraryController controller;
  final Game game;

  @override
  Widget build(BuildContext context) {
    final hidden = controller.config.isHidden(game.id);
    final artwork = controller.covers.resolve(game);
    return Container(
      width: width,
      color: context.palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => controller.select(null),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                _preview(context, artwork),
                const SizedBox(height: 18),
                Text(
                  game.name,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _chip(context, game.displaySubtitle),
                    const SizedBox(width: 8),
                    if (hidden) _chip(context, 'Hidden'),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => controller.launch(game),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Launch'),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => controller.openFolder(game),
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('Open folder'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: Launcher.formatCommand(game)),
                          );
                          controller.notice = 'Command copied';
                        },
                        icon: const Icon(Icons.copy_all, size: 18),
                        label: const Text('Copy'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => showArtPicker(context, controller, game),
                  icon: const Icon(Icons.image_search, size: 18),
                  label: const Text('Find art (SteamGridDB)'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => _rename(context),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Rename'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => controller.setHidden(game, hidden: !hidden),
                  icon: Icon(hidden ? Icons.visibility : Icons.visibility_off, size: 18),
                  label: Text(hidden ? 'Unhide' : 'Hide from library'),
                ),
                if (game.source == SourceKind.manual) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => controller.removeManual(game.key),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove'),
                  ),
                ],
                // The panel paints its own colour, so the switch needs a
                // Material of its own for its ink to show up.
                Material(
                  color: Colors.transparent,
                  child: SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: controller.config.closesWithGame(game.id),
                    onChanged: (value) => controller.setCloseWithGame(game.id, value),
                    title: const Text(
                      'Close the launcher with the game',
                      style: TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      'Asks the launcher window to close once the game exits',
                      style: TextStyle(fontSize: 12, color: context.palette.textDim),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _field(context, 'Played', formatPlaytime(controller.playtimeOf(game.id))),
                if (controller.lastPlayedFor(game.id) case final last?)
                  _field(context, 'Last played', formatLastPlayed(last, DateTime.now())),
                _field(context, 'Source', game.source.label),
                _field(context, 'Id', game.id),
                if (game.path != null) _field(context, 'Folder', game.path!),
                if (game.extra['size'] != null && game.extra['size'] != 0)
                  _field(context, 'Size on disk', _size(game.extra['size'])),
                if (game.extra['store'] != null) _field(context, 'Store', '${game.extra['store']}'),
                _field(context, 'Command', Launcher.formatCommand(game), mono: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final choice = await showRenameGameDialog(
      context,
      currentName: game.name,
      discoveredName: controller.discoveredNameFor(game.id),
    );
    if (choice == null) return;
    controller.setName(game.id, choice.reset ? null : choice.name);
  }

  Widget _preview(BuildContext context, Artwork artwork) {
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
        child: Container(
          color: context.palette.surface,
          child: path == null
              ? Center(
                  child: Text(
                    game.name.isEmpty ? '?' : game.name.substring(0, 1).toUpperCase(),
                    style: TextStyle(
                      fontSize: 72,
                      fontWeight: FontWeight.w800,
                      color: context.palette.previewLetter,
                    ),
                  ),
                )
              : Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                ),
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

  Widget _field(
    BuildContext context,
    String label,
    String value, {
    bool mono = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.1,
            color: context.palette.textDim,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(
          value,
          style: TextStyle(
            fontSize: 13,
            height: 1.35,
            fontFamily: mono ? 'monospace' : null,
          ),
        ),
      ],
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
