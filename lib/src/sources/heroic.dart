import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../paths.dart';
import '../util/files.dart';
import '../util/proc.dart';
import 'source.dart';

/// Flatpak ref of the Heroic launcher.
const String heroicFlatpakId = 'com.heroicgameslauncher.hgl';

/// Store label Epic games carry in the table below.
const String _epicStore = 'Epic';

/// Heroic's own config roots (native and flatpak installs).
List<String> get _heroicRoots => [
  '${AppPaths.home}/.config/heroic',
  '${AppPaths.home}/.var/app/$heroicFlatpakId/config/heroic',
];

/// `(store, path inside a Heroic config root, launcher CLI when Heroic is absent)`.
const List<(String, String, String?)> _stores = [
  (_epicStore, 'legendaryConfig/legendary/installed.json', 'legendary'),
  ('GOG', 'gog_store/installed.json', null),
  ('Amazon', 'nile_config/nile/installed.json', null),
];

/// One `installed.json` to read: the store it belongs to, its path, and the
/// launcher CLI that can start its games when Heroic itself is not installed.
typedef HeroicInstalledFile = (String store, String path, String? cli);

/// `(store, installed.json path, cli)` for every known location.
Iterable<HeroicInstalledFile> _defaultInstalledFiles() sync* {
  for (final root in _heroicRoots) {
    for (final store in _stores) {
      yield (store.$1, '$root/${store.$2}', store.$3);
    }
  }
  // Standalone clients keep installed.json directly in their config root.
  yield (_epicStore, '${AppPaths.home}/.config/legendary/installed.json', 'legendary');
  yield ('Amazon', '${AppPaths.home}/.config/nile/installed.json', null);
}

/// Python truthiness, used for the `or` chains below.
bool _truthy(Object? value) => switch (value) {
  null => false,
  String s => s.isNotEmpty,
  bool b => b,
  num n => n != 0,
  Iterable i => i.isNotEmpty,
  Map m => m.isNotEmpty,
  _ => true,
};

/// First truthy value, mirroring Python's `a or b or c`.
Object? _or(List<Object?> candidates) {
  for (final candidate in candidates) {
    if (_truthy(candidate)) return candidate;
  }
  return null;
}

/// Normalise an `installed.json` into `(game_key, entry)` pairs.
///
/// legendary, gogdl and nile have each shipped both a mapping keyed by app
/// name and a plain list of records, so accept either shape.
Iterable<(String, Map<String, Object?>)> _entries(Object? data) sync* {
  if (data is Map) {
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is Map) yield (entry.key.toString(), value.cast<String, Object?>());
    }
  } else if (data is List) {
    for (final value in data) {
      if (value is! Map) continue;
      final entry = value.cast<String, Object?>();
      final key = _or([entry['app_name'], entry['appName'], entry['id']]);
      if (key != null) yield (key.toString(), entry);
    }
  }
}

/// Epic, GOG and Amazon games known to Heroic, legendary or nile.
class HeroicSource extends GameSource {
  HeroicSource({Iterable<HeroicInstalledFile>? installedFiles})
    : installedFiles = installedFiles ?? _defaultInstalledFiles();

  /// The `installed.json` files to read; Heroic's own unless a caller (a test,
  /// or an unusual install) points somewhere else.
  final Iterable<HeroicInstalledFile> installedFiles;

  @override
  SourceKind get kind => SourceKind.heroic;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final heroic = which('heroic') != null || (await flatpakAppIds()).contains(heroicFlatpakId);
    final seen = <String>{};
    final games = <Game>[];
    for (final (store, path, cli) in installedFiles) {
      for (final (key, entry) in _entries(loadJson(path))) {
        if (seen.contains(key)) continue;
        final List<String> command;
        if (heroic) {
          command = ['xdg-open', 'heroic://launch/$key'];
        } else if (cli != null) {
          command = [cli, 'launch', key];
        } else {
          continue;
        }
        seen.add(key);
        final installPath = _or([entry['install_path'], entry['path']])?.toString() ?? '';
        final exists =
            installPath.isNotEmpty &&
            FileSystemEntity.typeSync(installPath) != FileSystemEntityType.notFound;
        final name = _or([entry['title'], entry['app_title']])?.toString() ?? key;
        final extra = <String, Object?>{
          'store': store,
          'install_path': installPath.isEmpty ? null : installPath,
        };
        // The native Epic launcher knows the same game under the same app name,
        // so both sources tag it with one identity and the registry folds the
        // two into a single entry (see `dedupeKey`).
        if (store == _epicStore) extra['dedupe'] = 'epic:$key';
        games.add(
          Game(
            id: '${kind.id}:$key',
            key: key,
            name: name,
            source: kind,
            command: command,
            path: exists ? installPath : null,
            subtitle: store,
            extra: extra,
          ),
        );
      }
    }
    return games;
  }
}
