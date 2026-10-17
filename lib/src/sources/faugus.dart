import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../util/files.dart';
import '../util/proc.dart';
import 'source.dart';
import '../host.dart';
import '../paths.dart';

/// Windows games managed by the Faugus launcher.

/// Flatpak ref of the Faugus launcher.
const String faugusFlatpakId = 'io.github.Faugus.faugus-launcher';

String _home() => AppPaths.home;

/// `~/.var/app/<ref>/data/faugus-launcher/games.json` (the flatpak sandbox).
String _flatpakGames() =>
    '${_home()}/.var/app/$faugusFlatpakId/data/faugus-launcher/games.json';

/// `<XDG_DATA_HOME or ~/.local/share>/faugus-launcher/games.json`.
String _nativeGames() {
  return '${Host.dataHome}/faugus-launcher/games.json';
}

/// Python's `str(value or "")` over the JSON value types.
String _textOrEmpty(Object? value) {
  if (value == null || value == false) return '';
  if (value is String) return value;
  if (value is num) return value == 0 ? '' : value.toString();
  if (value is List) return value.isEmpty ? '' : value.toString();
  if (value is Map) return value.isEmpty ? '' : value.toString();
  return value.toString();
}

/// Parse a Faugus `games.json`: a JSON list of records (`gameid`, `title`,
/// `path`, `prefix`, `icon`, `cover`, ...); anything else yields no records.
Future<List<Map<String, Object?>>> readGames(String path) async {
  final data = await loadJson(path);
  if (data is! List) return const [];
  return data.whereType<Map<String, Object?>>().toList();
}

/// `Path(str(path)).parent`, dropping trailing and repeated separators.
String _parentOf(String path) {
  final absolute = path.startsWith('/');
  final parts = path
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList();
  if (parts.isNotEmpty) parts.removeLast();
  if (parts.isEmpty) return absolute ? '/' : '.';
  final joined = parts.join('/');
  return absolute ? '/$joined' : joined;
}

/// The Wine prefix, or the directory holding the game executable.
String? _gamePath(Map<String, Object?> entry) {
  final prefix = _textOrEmpty(entry['prefix']);
  if (prefix.isNotEmpty) return prefix;
  final exe = _textOrEmpty(entry['path']);
  return exe.isEmpty ? null : _parentOf(exe);
}

Future<bool> _isFile(String path) async {
  try {
    return await FileSystemEntity.isFile(path);
  } on FileSystemException {
    return false;
  }
}

/// Every game Faugus knows about, launched through its `--game` flag.
class FaugusSource extends GameSource {
  @override
  SourceKind get kind => SourceKind.faugus;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final command = which('faugus-launcher') != null
        ? <String>['faugus-launcher']
        : <String>['flatpak', 'run', faugusFlatpakId];
    final seen = <String>{};
    final games = <Game>[];
    for (final path in [_flatpakGames(), _nativeGames()]) {
      for (final entry in await readGames(path)) {
        final title = _textOrEmpty(entry['title']).trim();
        if (title.isEmpty || !seen.add(title)) continue;
        final icon = _textOrEmpty(entry['icon']);
        games.add(
          Game(
            id: '${SourceKind.faugus.id}:$title',
            key: title,
            name: title,
            source: SourceKind.faugus,
            command: [...command, '--game', title],
            icon: icon.isNotEmpty && await _isFile(icon) ? icon : null,
            iconIsName: false,
            path: _gamePath(entry),
            subtitle: 'Faugus',
          ),
        );
      }
    }
    return games;
  }
}
