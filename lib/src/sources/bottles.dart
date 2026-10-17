import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../paths.dart';
import '../util/proc.dart';
import 'source.dart';

// Programs on a bottle's library, launched through `bottles-cli run`.

/// Flatpak ref of Bottles.
const String bottlesFlatpakId = 'com.usebottles.bottles';

String _home() => AppPaths.home;

/// The directories that hold one subfolder per bottle, native and flatpak.
List<String> _defaultRoots() => [
  '${_home()}/.local/share/bottles/bottles',
  '${_home()}/.var/app/$bottlesFlatpakId/data/bottles/bottles',
];

/// `key: value` or `key:` at any indentation, values optionally quoted.
final RegExp _key = RegExp(r'^(\s*)([\w.-]+)\s*:\s*(.*?)\s*$');

/// A `- ` list item, carrying the item's first `key: value` when inline.
final RegExp _item = RegExp(r'^(\s*)-\s*(.*)$');

String _unquote(String value) {
  if (value.length >= 2 &&
      value[0] == value[value.length - 1] &&
      (value[0] == '"' || value[0] == "'")) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

/// The entries of a bottle's `library.yml`, each a flat key/value map.
///
/// A hand-rolled reader rather than a YAML package: the launcher ships no
/// third-party dependencies. Bottles has written the library both as a
/// top-level list of records and as a map keyed by entry id, so both shapes
/// parse; anything that does not fit either yields no entry rather than an
/// error.
List<Map<String, String>> parseLibraryYaml(String text) {
  final entries = <Map<String, String>>[];
  Map<String, String>? current;
  var currentIndent = -1;
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final item = _item.firstMatch(line);
    if (item != null) {
      current = <String, String>{};
      entries.add(current);
      currentIndent = item.group(1)!.length;
      final first = _key.firstMatch(item.group(2)!);
      if (first != null) {
        current[first.group(2)!] = _unquote(first.group(3)!);
      }
      continue;
    }
    final match = _key.firstMatch(line);
    if (match == null) continue;
    final indent = match.group(1)!.length;
    final key = match.group(2)!;
    final value = _unquote(match.group(3)!);
    if (indent == 0) {
      // A bare `key:` opens a nested record (the map shape); a top-level
      // scalar is metadata and ends the record being read.
      current = value.isEmpty ? <String, String>{} : null;
      currentIndent = 0;
      if (current != null) entries.add(current);
      continue;
    }
    if (current != null && indent > currentIndent) {
      current[key] = value;
    }
  }
  return entries;
}

/// One game per program in a bottle's `library.yml`.
class BottlesSource extends GameSource {
  BottlesSource({List<String>? roots, this.command})
    : roots = roots ?? _defaultRoots();

  /// The directories holding one subfolder per bottle; the real ones unless a
  /// caller (a test, or an unusual install) points somewhere else.
  final List<String> roots;

  /// The argv prefix to launch with; detected from the install when null.
  final List<String>? command;

  @override
  SourceKind get kind => SourceKind.bottles;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final argv =
        command ??
        (which('bottles-cli') != null
            ? <String>['bottles-cli']
            : <String>[
                'flatpak',
                'run',
                '--command=bottles-cli',
                bottlesFlatpakId,
              ]);
    final seen = <String>{};
    final games = <Game>[];
    for (final root in roots) {
      final List<FileSystemEntity> entries;
      try {
        entries = await Directory(root).list().toList();
      } on FileSystemException {
        continue;
      }
      final bottles = entries.whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final dir in bottles) {
        final bottle = dir.path.substring(dir.path.lastIndexOf('/') + 1);
        final String text;
        try {
          text = utf8.decode(
            await File('${dir.path}/library.yml').readAsBytes(),
            allowMalformed: true,
          );
        } on FileSystemException {
          continue;
        }
        for (final entry in parseLibraryYaml(text)) {
          final name = entry['name'] ?? '';
          if (name.isEmpty) continue;
          final entryId = entry['id'] ?? '';
          final key = '$bottle/${entryId.isNotEmpty ? entryId : name}';
          if (!seen.add(key)) continue;
          games.add(
            Game(
              id: '${SourceKind.bottles.id}:$key',
              key: key,
              name: name,
              source: SourceKind.bottles,
              command: [...argv, 'run', '-b', bottle, '-p', name],
              subtitle: 'Bottles',
              extra: {'bottle': bottle, 'program': name},
            ),
          );
        }
      }
    }
    return games;
  }
}
