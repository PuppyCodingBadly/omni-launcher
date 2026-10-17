import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../util/proc.dart';
import '../util/vdf.dart';
import 'source.dart';
import 'steam_shortcuts.dart';

/// Steam runtime/tooling entries that are not games.
const List<String> _skipPrefixes = [
  'Steam Linux Runtime',
  'SteamVR',
  'Steamworks Common Redistributables',
  'Proton',
];

/// Fully-installed bit inside `StateFlags`.
const int _stateInstalled = 4;

final RegExp _manifestName = RegExp(r'^appmanifest_.*\.acf$');

String _basename(String path) => path.split('/').last;

String _join(String base, String part) {
  if (part.isEmpty) return base;
  return base.endsWith('/') ? '$base$part' : '$base/$part';
}

/// Resolved symlink target, or the path itself when it cannot be resolved.
Future<String> _resolved(String path) async {
  try {
    return await File(path).resolveSymbolicLinks();
  } on FileSystemException {
    return path;
  }
}

/// `int(str(value))` with Python's tolerance for surrounding whitespace.
int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is! String) return null;
  var text = value.trim();
  if (text.startsWith('+')) text = text.substring(1);
  return int.tryParse(text);
}

/// Libraries listed in `libraryfolders.vdf`, or the default one.
Future<List<String>> _libraryPaths(String steamRoot) async {
  String? text;
  try {
    text = utf8.decode(
      await File('$steamRoot/steamapps/libraryfolders.vdf').readAsBytes(),
      allowMalformed: true,
    );
  } on FileSystemException {
    text = null;
  }
  final data = text == null ? <String, Object?>{} : parseKeyValues(text);
  final folders = data['libraryfolders'] ?? data['LibraryFolders'] ?? const <String, Object?>{};
  final libraries = <String>[];
  if (folders is Map) {
    for (final value in folders.values) {
      if (value is Map && value['path'] != null && '${value['path']}'.isNotEmpty) {
        libraries.add('${value['path']}');
      }
    }
  }
  return libraries.isNotEmpty ? libraries : [steamRoot];
}

Future<List<String>> _launchPrefix() async {
  final steamBin = which('steam');
  if (steamBin != null) return [steamBin, '-applaunch'];
  final ids = await flatpakAppIds();
  if (ids.contains('com.valvesoftware.Steam')) {
    return ['flatpak', 'run', 'com.valvesoftware.Steam', '-applaunch'];
  }
  return ['steam', '-applaunch'];
}

/// argv that asks Steam to start [appid].
///
/// Works for Steam's own games and for non-Steam shortcuts, which is how a
/// game like RetroDECK gets Steam Input and the overlay.
Future<List<String>> steamLaunchCommand(String appid) async =>
    [...await _launchPrefix(), appid];

/// Cover art for [appid] in any Steam root's librarycache, or `null`.
///
/// The flatpak sandbox keeps its own appcache, so a cover downloaded by a
/// flatpak Steam never appears under the native root.
Future<String?> _coverPath(List<String> roots, String appid) async {
  for (final root in roots) {
    final cover = '$root/appcache/librarycache/$appid/library_600x900.jpg';
    if (await File(cover).exists()) return cover;
  }
  return null;
}

String _appId(Map<Object?, Object?> state, String manifestPath) {
  final appid = state['appid'];
  if (appid != null && '$appid'.isNotEmpty) return '$appid';
  var stem = _basename(manifestPath);
  if (stem.endsWith('.acf')) stem = stem.substring(0, stem.length - 4);
  return stem.startsWith('appmanifest_') ? stem.substring('appmanifest_'.length) : stem;
}

Game? _game(
  Map<Object?, Object?> state,
  String appid,
  String library,
  List<String> prefix,
  String? cover,
) {
  final rawName = state['name'];
  final name = rawName == null ? '' : '$rawName';
  if (name.isEmpty || _skipPrefixes.any(name.startsWith)) return null;
  final flags = _asInt(state.containsKey('StateFlags') ? state['StateFlags'] : '0');
  if (flags == null) return null;
  if (flags & _stateInstalled == 0) return null;
  final size =
      _asInt(state.containsKey('SizeOnDisk') ? state['SizeOnDisk'] : '0') ?? 0;
  final rawDir = state['installdir'];
  final installdir = (rawDir == null || '$rawDir'.isEmpty) ? '' : '$rawDir';
  return Game(
    id: 'steam:$appid',
    key: appid,
    name: name,
    source: SourceKind.steam,
    command: [...prefix, appid],
    cover: cover,
    path: _join(_join(_join(library, 'steamapps'), 'common'), installdir),
    subtitle: 'Steam',
    extra: {'appid': appid, 'size': size, 'library': library},
  );
}

/// Installed Steam games, read from the `appmanifest_*.acf` files.
class SteamSource extends GameSource {
  SteamSource({List<String>? roots}) : roots = roots ?? defaultSteamRoots();

  /// Steam roots to scan: the native install and the flatpak sandbox, unless
  /// a caller (a test, or an unusual layout) points somewhere else.
  final List<String> roots;

  @override
  SourceKind get kind => SourceKind.steam;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final prefix = await _launchPrefix();
    final games = <Game>[];
    final seenRoots = <String>{};
    final seenLibraries = <String>{};
    for (final root in roots) {
      if (!await Directory(root).exists()) continue;
      // `~/.steam/steam` and `~/.local/share/Steam` usually point at the same
      // directory through a symlink, so each real root is scanned once.
      if (!seenRoots.add(await _resolved(root))) continue;
      for (final library in await _libraryPaths(root)) {
        if (!await Directory(library).exists()) continue;
        if (!seenLibraries.add(await _resolved(library))) continue;
        List<String> manifests;
        try {
          manifests = await Directory('$library/steamapps')
              .list()
              .where(
                (entity) =>
                    entity is File &&
                    _manifestName.hasMatch(_basename(entity.path)),
              )
              .map((entity) => entity.path)
              .toList();
          manifests.sort();
        } on FileSystemException {
          continue;
        }
        for (final manifest in manifests) {
          Map<String, Object?> data;
          try {
            data = parseKeyValues(
              utf8.decode(
                await File(manifest).readAsBytes(),
                allowMalformed: true,
              ),
            );
          } on FileSystemException {
            continue;
          }
          final state = data['AppState'];
          if (state is! Map) continue;
          final appid = _appId(state, manifest);
          final game = _game(
            state,
            appid,
            library,
            prefix,
            await _coverPath(roots, appid),
          );
          if (game != null) games.add(game);
        }
      }
    }
    return games;
  }
}
