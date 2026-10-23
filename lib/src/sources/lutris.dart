import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../host.dart';
import '../model/game.dart';
import 'lutris_categories.dart';
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
    } else if (block == 'game' &&
        value.isNotEmpty &&
        _blockKeys.contains(key)) {
      result[key] = value;
    }
  }
  return result;
}

/// Cut a trailing `#` comment off [line], leaving a `#` inside quotes alone.
///
/// Lutris writes plain YAML, where `#` starts a comment at the beginning of a
/// line or after whitespace, but is a literal inside a word (`C# tactic`).
String _withoutComment(String line) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quote != null) {
      if (char == quote) quote = null;
    } else if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '#' &&
        (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t')) {
      return line.substring(0, i);
    }
  }
  return line;
}

/// Split a flow list's body on commas that are not inside quotes, so
/// `["Action, FPS", RPG]` stays two categories.
List<String> _splitOnCommas(String value) {
  final items = <String>[];
  final item = StringBuffer();
  String? quote;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (quote != null) {
      item.write(char);
      if (char == quote) quote = null;
    } else if (char == '"' || char == "'") {
      quote = char;
      item.write(char);
    } else if (char == ',') {
      items.add(item.toString());
      item.clear();
    } else {
      item.write(char);
    }
  }
  items.add(item.toString());
  return items;
}

/// The `categories:` list of a Lutris game YAML.
///
/// Lutris writes them as a block list at the top level (or inside `game:`):
///
/// ```yaml
/// categories:
/// - Action
/// - FPS
/// ```
///
/// An inline `categories: [Action, FPS]` is read too, including commas inside
/// quoted names. Trailing `#` comments are ignored. Unknown lines inside the
/// block are ignored, so a hand-edited file cannot break the scan.
List<String> parseGameCategories(String text) {
  final categories = <String>[];
  void add(String value) {
    final title = _unquote(value.trim());
    if (title.isNotEmpty && !categories.contains(title)) categories.add(title);
  }

  var blockIndent = -1;
  for (final raw in const LineSplitter().convert(text)) {
    final line = _withoutComment(raw);
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final indent = line.length - line.trimLeft().length;
    if (trimmed.startsWith('-')) {
      // Lutris writes the list at the key's own indent, not indented under it.
      if (blockIndent >= 0 && indent >= blockIndent) {
        add(trimmed.substring(1));
      }
      continue;
    }
    if (blockIndent >= 0 && indent <= blockIndent) blockIndent = -1;
    final match = _key.firstMatch(line);
    if (match == null || match.group(2) != 'categories') continue;
    final inline = match.group(3)!.trim();
    if (inline.startsWith('[') && inline.endsWith(']')) {
      for (final item in _splitOnCommas(
        inline.substring(1, inline.length - 1),
      )) {
        add(item);
      }
    } else {
      blockIndent = indent;
    }
  }
  return categories;
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
    // The YAML says what the installer was told; the database is what Lutris
    // actually shows. Both are merged, since a category added in the UI never
    // reaches the YAML. Read once: the places Lutris may keep the database are
    // fixed, not per game.
    final dbPaths = [
      '${Host.dataHome}/lutris/pga.db',
      '${Host.home}/.config/lutris/pga.db',
      '${Host.home}/.var/app/net.lutris.Lutris/data/lutris/pga.db',
      '${Host.home}/.var/app/net.lutris.Lutris/config/lutris/pga.db',
    ];
    final dbTags = await lutrisCategoryTags(dbPaths);
    for (final dir in _gameDirs) {
      final directory = Directory(dir);
      bool isDir;
      try {
        isDir = await directory.exists();
      } on FileSystemException {
        continue;
      }
      if (!isDir) continue;

      List<FileSystemEntity> entries;
      try {
        entries = await directory.list().toList();
      } on FileSystemException {
        continue;
      }
      final files =
          entries
              .whereType<File>()
              .where((f) => f.path.endsWith('.yml'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      for (final file in files) {
        Map<String, String> data;
        List<String> yamlTags;
        try {
          final text = utf8.decode(
            await file.readAsBytes(),
            allowMalformed: true,
          );
          data = parseGameYaml(text);
          yamlTags = parseGameCategories(text);
        } on FileSystemException {
          continue;
        }
        final parsedSlug = data['slug'];
        final fileName = file.path.substring(file.path.lastIndexOf('/') + 1);
        final slug = (parsedSlug != null && parsedSlug.isNotEmpty)
            ? parsedSlug
            : _slugFromFilename(fileName);
        if (slug.isEmpty) continue;
        final tags = <String>{...yamlTags, ...?dbTags[slug]}.toList()..sort();
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
            path: (directory0 != null && directory0.isNotEmpty)
                ? directory0
                : null,
            subtitle: 'Lutris',
            extra: {'slug': slug, if (tags.isNotEmpty) 'tags': tags},
          ),
        );
      }
    }
    return games;
  }
}
