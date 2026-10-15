import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import 'source.dart';
import '../paths.dart';

// Lutris games from the per-game YAML configs in the Lutris config dir.

/// `key: value` or `key:` at any indentation, values optionally quoted.
final RegExp _key = RegExp(r'^(\s*)([A-Za-z_][\w-]*)\s*:\s*(.*?)\s*$');

/// Lutris names config files `<slug>-<timestamp>.yml`.
final RegExp _timestamp = RegExp(r'-\d+$');

/// Top-level keys copied verbatim into the result.
const List<String> _topKeys = ['slug', 'name', 'id', 'directory'];

/// Keys read from inside the `game:` block.
const List<String> _blockKeys = ['name', 'id', 'slug', 'directory'];

String _unquote(String value) {
  if (value.length >= 2 &&
      value[0] == value[value.length - 1] &&
      (value[0] == '"' || value[0] == "'")) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

/// Extract `slug`/`name`/`id`/`directory` from a Lutris game YAML.
///
/// A hand-rolled reader rather than a YAML package: the launcher ships no
/// third-party dependencies. It understands the subset Lutris writes - one
/// top-level `slug:` (or `game_slug:`) plus the `name:`/`id`/`directory:`
/// keys of the `game:` block - and tolerates quoted values.
Map<String, String> parseGameYaml(String text) {
  final result = <String, String>{};
  var block = '';
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final match = _key.firstMatch(line);
    if (match == null) continue;
    final indent = match.group(1)!;
    final key = match.group(2)!;
    final value = _unquote(match.group(3)!);
    if (indent.isEmpty) {
      block = key;
      if (key == 'game_slug') {
        result.putIfAbsent('slug', () => value);
      } else if (_topKeys.contains(key) && value.isNotEmpty) {
        result[key] = value;
      }
    } else if (block == 'game' && value.isNotEmpty && _blockKeys.contains(key)) {
      result[key] = value;
    }
  }
  return result;
}

/// `my-game-1712345678.yml` -> `my-game` (Lutris appends a timestamp).
String _slugFromFilename(String name) {
  var stem = name;
  if (stem.endsWith('.yml')) stem = stem.substring(0, stem.length - 4);
  return stem.replaceFirst(_timestamp, '');
}

/// One game per `games/*.yml` file.
class LutrisSource extends GameSource {
  @override
  SourceKind get kind => SourceKind.lutris;

  static final List<String> _gameDirs = [
    '${_home()}/.config/lutris/games',
    '${_home()}/.var/app/net.lutris.Lutris/config/lutris/games',
  ];

  static String _home() => AppPaths.home;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final games = <Game>[];
    for (final dir in _gameDirs) {
      final directory = Directory(dir);
      bool isDir;
      try {
        isDir = directory.existsSync();
      } on FileSystemException {
        continue;
      }
      if (!isDir) continue;

      List<FileSystemEntity> entries;
      try {
        entries = directory.listSync();
      } on FileSystemException {
        continue;
      }
      final files = entries.whereType<File>().where((f) => f.path.endsWith('.yml')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      for (final file in files) {
        Map<String, String> data;
        try {
          data = parseGameYaml(
            utf8.decode(file.readAsBytesSync(), allowMalformed: true),
          );
        } on FileSystemException {
          continue;
        }
        final parsedSlug = data['slug'];
        final fileName = file.path.substring(file.path.lastIndexOf('/') + 1);
        final slug = (parsedSlug != null && parsedSlug.isNotEmpty)
            ? parsedSlug
            : _slugFromFilename(fileName);
        if (slug.isEmpty) continue;
        final dbId = data['id'] ?? '';
        final uri = RegExp(r'^\d+$').hasMatch(dbId)
            ? 'lutris:rungameid/$dbId'
            : 'lutris:rungame/$slug';
        final name = data['name'];
        final directory0 = data['directory'];
        games.add(
          Game(
            id: '${SourceKind.lutris.id}:$slug',
            key: slug,
            name: (name != null && name.isNotEmpty) ? name : slug,
            source: SourceKind.lutris,
            command: ['lutris', uri],
            path: (directory0 != null && directory0.isNotEmpty) ? directory0 : null,
            subtitle: 'Lutris',
            extra: {'slug': slug},
          ),
        );
      }
    }
    return games;
  }
}
