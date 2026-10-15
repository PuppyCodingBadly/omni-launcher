/// Installed flatpak apps that declare the `Game` category.
library;

import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../paths.dart';
import '../util/desktop.dart';
import '../util/files.dart';
import '../util/proc.dart';
import 'source.dart';
import '../host.dart';

/// Directories holding the exported `.desktop` files (system, then user).
final List<String> _exportDirs = [
  Host.path('/var/lib/flatpak/exports/share/applications'),
  '${AppPaths.home}/.local/share/flatpak/exports/share/applications',
];

/// The `Name` key when non-empty, otherwise [appId].
String _name(Map<String, String> entry, String appId) {
  final name = entry['Name'];
  return (name == null || name.isEmpty) ? appId : name;
}

/// `Icon` plus whether it is a theme name rather than an image file.
(String?, bool) _icon(Map<String, String> entry) {
  final raw = entry['Icon'];
  final icon = (raw == null || raw.isEmpty) ? null : raw;
  if (icon != null && icon.startsWith('/') && File(icon).existsSync()) {
    return (icon, false);
  }
  return (icon, icon != null);
}

bool _isGame(Map<String, String> entry) {
  if (entry.isEmpty) return false;
  if ((entry['NoDisplay'] ?? '').toLowerCase() == 'true') return false;
  if ((entry['Hidden'] ?? '').toLowerCase() == 'true') return false;
  return desktopCategories(entry).contains('Game');
}

/// `Path.stem`: the file name without its final `.desktop` suffix.
String _stem(String name) =>
    name.endsWith('.desktop') ? name.substring(0, name.length - '.desktop'.length) : name;

/// Marker that starts an entry line of a host dump.
const String _dumpMarker = '@@';

/// Parse the `@@<file name> <base64>` lines of a host dump.
///
/// One line per entry: desktop file contents can contain anything, including
/// the marker itself, so the body is base64 encoded rather than concatenated.
List<(String, Map<String, String>)> parseDesktopDump(String dump) {
  final entries = <(String, Map<String, String>)>[];
  for (final line in dump.split('\n')) {
    if (!line.startsWith(_dumpMarker)) continue;
    final space = line.indexOf(' ', _dumpMarker.length);
    if (space <= _dumpMarker.length) continue;
    final name = line.substring(_dumpMarker.length, space).trim();
    if (!name.endsWith('.desktop')) continue;
    final payload = line.substring(space + 1).trim();
    if (payload.isEmpty) continue;
    String text;
    try {
      text = utf8.decode(base64.decode(payload));
    } on FormatException {
      continue;
    }
    final entry = parseDesktopEntry(text);
    if (entry.isNotEmpty) entries.add((name, entry));
  }
  return entries;
}

/// The exported desktop entries, as `(file name, parsed entry)`.
///
/// Natively they are files on disk. Inside a flatpak sandbox flatpak masks
/// `~/.local/share/flatpak` and `/run/host` carries no `var`, so the host's
/// entries are read through the portal in a single call instead.
Future<List<(String, Map<String, String>)>> _desktopEntries() async {
  if (!Host.inFlatpak) {
    return [
      for (final file in iterDesktopFiles(_exportDirs))
        (file.uri.pathSegments.last, readDesktopFile(file.path)),
    ];
  }
  const script =
      r'for d in /var/lib/flatpak/exports/share/applications "$HOME/.local/share/flatpak/exports/share/applications"; do '
      r'for f in "$d"/*.desktop; do [ -f "$f" ] || continue; '
      r'printf "@@%s " "${f##*/}"; base64 -w0 "$f"; echo; done; done';
  final dump = await runCapture(
    Host.command(['sh', '-c', script]),
    timeout: const Duration(seconds: 20),
  );
  return parseDesktopDump(dump);
}

/// One game per flatpak app, preferring the entry named after the app.
class FlatpakSource extends GameSource {
  @override
  SourceKind get kind => SourceKind.flatpak;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final appIds = await flatpakAppIds();
    final best = <String, (int, Map<String, String>)>{};
    for (final (desktopName, entry) in await _desktopEntries()) {
      if (!_isGame(entry)) continue;
      final appId = flatpakAppForDesktop(desktopName, appIds);
      if (appId == null) continue;
      // `net.retrodeck.retrodeck.desktop` beats `…retrodeck.Configurator.desktop`
      final score = _stem(desktopName) == appId ? 0 : 1;
      final current = best[appId];
      if (current == null || score < current.$1) best[appId] = (score, entry);
    }
    final appIdsSorted = best.keys.toList()..sort();
    final games = <Game>[];
    for (final appId in appIdsSorted) {
      // A launcher is not a game, and this one is now a flatpak itself.
      if (appId == AppPaths.appId) continue;
      final entry = best[appId]!.$2;
      final (icon, iconIsName) = _icon(entry);
      games.add(
        Game(
          id: '${SourceKind.flatpak.id}:$appId',
          key: appId,
          name: _name(entry, appId),
          source: SourceKind.flatpak,
          command: ['flatpak', 'run', appId],
          icon: icon,
          iconIsName: iconIsName,
          path: null,
          subtitle: 'Flatpak',
        ),
      );
    }
    return games;
  }
}
