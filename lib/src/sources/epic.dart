/// Games installed by the Epic Games Launcher (the native Linux build).
///
/// Where the data comes from, and why:
///
/// * `installations.jsonl` in the launcher's state directory is the installed
///   set. It is an append-only log - one JSON object per line, one line per
///   state change of an installation - so the last line for an
///   `installationId` is the current state. The first line is a header without
///   an id. Each record carries `namespace`, `itemId`, `artifactId`, `dir`,
///   `launchExecutable`, `platform` and `complete`.
/// * The display name is *not* in that log. It comes from the catalog cache
///   (`cache/prod/catalog-cache.json`), whose `items` map is keyed by exactly
///   the record's `itemId` and holds `item.title` ("Alan Wake 2").
/// * Nothing else on disk carries the set: `cache/manifest-summaries/*.json`
///   has only checksums and sizes, the launcher logs never mention the library,
///   `localstorage/` holds no game data, the IndexedDB store is EOS webview
///   state (and would need a SQLite dependency), and the binary
///   `<dir>/.egstore/<installationId>.manifest` is Epic's packed manifest
///   format with no readable metadata.
///
/// The launch triple is `<namespace>:<itemId>:<appName>`, where the app name is
/// the record's `artifactId` - the same value the launcher writes into
/// `recently-played.json`, and the same value the catalog calls
/// `releaseInfo[].appId`. `xdg-open` on the scheme URI hands the game to the
/// launcher, which is the only supported way to start it.
library;

import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../util/files.dart';
import 'source.dart';
import '../host.dart';

/// State directory the launcher keeps under the XDG data home.
const String epicDataDir = 'com.epicgames.eglv2';

/// Scheme the launcher registers as its `x-scheme-handler`.
const String _launchPrefix = 'com.epicgames.launcher://apps/';

/// `$XDG_DATA_HOME`, or `~/.local/share`.
String _dataHome() {
  return Host.dataHome;
}

String _text(Object? value) => value is String ? value : '';

Object? _orNull(String value) => value.isEmpty ? null : value;

/// Every installation the launcher knows about, in file order.
///
/// Lines that are not JSON (a half-written append), not objects, or part of the
/// header are skipped, so a truncated file still yields the installations it
/// does describe.
Future<List<Map<String, Object?>>> readInstallations(String path) async {
  String text;
  try {
    text = utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
  } on FileSystemException {
    return const [];
  }
  final latest = <String, Map<String, Object?>>{};
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    final entry = decoded.cast<String, Object?>();
    final id = _text(entry['installationId']);
    if (id.isEmpty) continue;
    // Re-assigning keeps the first position, so the order stays stable while
    // the newest snapshot per installation wins.
    latest[id] = entry;
  }
  return latest.values.toList();
}

/// Display titles from the catalog cache, keyed by catalog item id.
Future<Map<String, String>> _catalogTitles(String path) async {
  final data = await loadJson(path);
  if (data is! Map) return const {};
  final items = data['items'];
  if (items is! Map) return const {};
  final titles = <String, String>{};
  for (final entry in items.entries) {
    final id = entry.key;
    final cached = entry.value;
    if (id is! String || cached is! Map) continue;
    final item = cached['item'];
    if (item is! Map) continue;
    final title = _text(item['title']).trim();
    if (title.isEmpty) continue;
    titles[id] = title;
  }
  return titles;
}

/// `com.epicgames.launcher://apps/<namespace>%3A<itemId>%3A<appName>?action=launch&silent=true`,
/// or the short `apps/<appName>` form when the triple is incomplete.
///
/// Returns `null` when the record names no app at all, which leaves nothing the
/// launcher could start.
String? _launchUri(String namespace, String itemId, String appName) {
  if (appName.isEmpty) return null;
  // These values come from the launcher's log; a stray `?`, `&` or `#` would
  // corrupt the URI, so every component is encoded.
  if (namespace.isEmpty || itemId.isEmpty) {
    return '$_launchPrefix${Uri.encodeComponent(appName)}?action=launch';
  }
  final triple = [
    namespace,
    itemId,
    appName,
  ].map(Uri.encodeComponent).join('%3A');
  return '$_launchPrefix$triple?action=launch&silent=true';
}

/// The catalog title, else something readable from the record itself.
String _displayName(String title, String executable, String dir, String fallback) {
  if (title.isNotEmpty) return title;
  final stem = _stem(executable);
  if (stem.isNotEmpty) return stem;
  final base = dir.isEmpty ? '' : dir.split('/').last;
  return base.isNotEmpty ? base : fallback;
}

/// `AlanWake2.exe` -> `AlanWake2`.
String _stem(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

Future<bool> _exists(String path) async =>
    path.isNotEmpty &&
    await FileSystemEntity.type(path) != FileSystemEntityType.notFound;

/// Every game installed through the Epic Games Launcher.
class EpicSource extends GameSource {
  EpicSource({String? dataRoot})
    : dataRoot = dataRoot ?? '${_dataHome()}/$epicDataDir';

  /// The launcher's state directory:
  /// `<XDG_DATA_HOME or ~/.local/share>/com.epicgames.eglv2`, unless a caller
  /// (a test, or an unusual install) points somewhere else.
  final String dataRoot;

  @override
  SourceKind get kind => SourceKind.epic;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final root = dataRoot;
    final titles = await _catalogTitles('$root/cache/prod/catalog-cache.json');
    final games = <Game>[];
    final seen = <String>{};
    for (final entry in await readInstallations('$root/installations.jsonl')) {
      final installationId = _text(entry['installationId']);
      final namespace = _text(entry['namespace']);
      final itemId = _text(entry['itemId']);
      final appName = _text(entry['artifactId']);
      final uri = _launchUri(namespace, itemId, appName);
      if (uri == null || !seen.add(appName)) continue;
      final dir = _text(entry['dir']);
      games.add(
        Game(
          id: '${SourceKind.epic.id}:$appName',
          key: appName,
          name: _displayName(
            titles[itemId] ?? '',
            _text(entry['launchExecutable']),
            dir,
            appName,
          ),
          source: SourceKind.epic,
          command: ['xdg-open', uri],
          path: await _exists(dir) ? dir : null,
          subtitle: SourceKind.epic.label,
          extra: {
            'installationId': _orNull(installationId),
            'namespace': _orNull(namespace),
            'itemId': _orNull(itemId),
            'appName': _orNull(appName),
            'platform': _orNull(_text(entry['platform'])),
            'complete': entry['complete'] == true,
            'dir': _orNull(dir),
            // The same game can also be listed by Heroic's legendary store,
            // which knows it by the same app name, so both tag it with one
            // identity and the registry folds them (see `dedupeKey`).
            'dedupe': 'epic:$appName',
          },
        ),
      );
    }
    return games;
  }
}
