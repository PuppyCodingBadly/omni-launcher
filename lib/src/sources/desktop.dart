/// Desktop entries that advertise themselves as games but no source owns.
library;

import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../paths.dart';
import '../util/desktop.dart';
import '../util/files.dart';
import 'source.dart';
import '../host.dart';

/// Where the freedesktop spec puts `.desktop` entries.
final List<String> _desktopDirs = [
  Host.path('/usr/share/applications'),
  Host.path('/usr/local/share/applications'),
  '${AppPaths.home}/.local/share/applications',
];

final RegExp _steamRunGame = RegExp(r'steam://rungameid/(\d+)');

/// A launcher is not a game: this app's own desktop entry, and any entry left
/// by an earlier build of it, are skipped by name.
bool _isLauncherEntry(String name) =>
    name.toLowerCase().contains('omnilauncher');

bool _isTrue(Map<String, String> entry, String key) =>
    (entry[key] ?? '').trim().toLowerCase() == 'true';

String _stem(String name) => name.endsWith('.desktop')
    ? name.substring(0, name.length - '.desktop'.length)
    : name;

/// Identity of the game behind the entry, so other sources can win.
Future<String?> _dedupeKey(Map<String, String> entry) async {
  final execLine = entry['Exec'] ?? '';
  final match = _steamRunGame.firstMatch(execLine);
  if (match != null) return 'steam:${match.group(1)}';
  for (final token in desktopExecArgv(execLine)) {
    if (!token.startsWith('/')) continue;
    final file = File(token);
    if (!await file.exists()) continue;
    try {
      return 'path:${await file.resolveSymbolicLinks()}';
    } on FileSystemException {
      return 'path:$token';
    }
  }
  return null;
}

/// Every non-flatpak desktop entry that is categorised as a Game.
class DesktopSource extends GameSource {
  @override
  SourceKind get kind => SourceKind.desktop;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final games = <Game>[];
    for (final file in await iterDesktopFiles(_desktopDirs)) {
      final name = file.path.split('/').last;
      if (_isLauncherEntry(name) || isFlatpakExport(file.path)) continue;
      final entry = await readDesktopFile(file.path);
      if (entry.isEmpty || !desktopCategories(entry).contains('Game')) continue;
      if (_isTrue(entry, 'NoDisplay') ||
          _isTrue(entry, 'Hidden') ||
          _isTrue(entry, 'Terminal')) {
        continue;
      }
      final command = await desktopLaunchCommand(file.path, entry);
      if (command.isEmpty) continue;
      final icon = (entry['Icon'] ?? '').isEmpty ? null : entry['Icon'];
      var iconIsName = true;
      if (icon != null &&
          icon.startsWith('/') &&
          await File(icon).exists()) {
        iconIsName = false;
      }
      final extra = <String, Object?>{};
      final dedupe = await _dedupeKey(entry);
      if (dedupe != null) extra['dedupe'] = dedupe;
      games.add(
        Game(
          id: 'desktop:$name',
          key: name,
          name: (entry['Name'] ?? '').isEmpty ? _stem(name) : entry['Name']!,
          source: SourceKind.desktop,
          command: command,
          icon: icon,
          iconIsName: iconIsName,
          subtitle: 'Desktop entry',
          extra: extra,
        ),
      );
    }
    return games;
  }
}
