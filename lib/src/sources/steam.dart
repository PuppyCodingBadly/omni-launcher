import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../util/proc.dart';
import '../util/vdf.dart';
import 'source.dart';
import '../paths.dart';

/// Steam runtime/tooling entries that are not games.
const List<String> _skipPrefixes = ['Steam Linux Runtime', 'Proton'];

/// Fully-installed bit inside `StateFlags`.
const int _stateInstalled = 4;

final RegExp _manifestName = RegExp(r'^appmanifest_.*\.acf$');

String get _home => AppPaths.home;

String get _defaultSteam => '$_home/.local/share/Steam';

String _basename(String path) => path.split('/').last;

String _join(String base, String part) {
  if (part.isEmpty) return base;
  return base.endsWith('/') ? '$base$part' : '$base/$part';
}

String _resolved(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
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
List<String> _libraryPaths(String steamRoot) {
  String? text;
  try {
    text = utf8.decode(
      File('$steamRoot/steamapps/libraryfolders.vdf').readAsBytesSync(),
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

String? _coverPath(String appid) {
  final cover = '$_home/.local/share/Steam/appcache/librarycache/$appid/library_600x900.jpg';
  return File(cover).existsSync() ? cover : null;
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
    cover: _coverPath(appid),
    path: _join(_join(_join(library, 'steamapps'), 'common'), installdir),
    subtitle: 'Steam',
    extra: {'appid': appid, 'size': size, 'library': library},
  );
}

/// Installed Steam games, read from the `appmanifest_*.acf` files.
class SteamSource extends GameSource {
  @override
  SourceKind get kind => SourceKind.steam;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final prefix = await _launchPrefix();
    final games = <Game>[];
    final seen = <String>{};
    for (final library in _libraryPaths(_defaultSteam)) {
      if (!Directory(library).existsSync()) continue;
      if (!seen.add(_resolved(library))) continue;
      List<String> manifests;
      try {
        manifests =
            Directory('$library/steamapps')
                .listSync()
                .whereType<File>()
                .map((file) => file.path)
                .where((path) => _manifestName.hasMatch(_basename(path)))
                .toList()
              ..sort();
      } on FileSystemException {
        continue;
      }
      for (final manifest in manifests) {
        Map<String, Object?> data;
        try {
          data = parseKeyValues(
            utf8.decode(File(manifest).readAsBytesSync(), allowMalformed: true),
          );
        } on FileSystemException {
          continue;
        }
        final state = data['AppState'];
        if (state is! Map) continue;
        final appid = _appId(state, manifest);
        final game = _game(state, appid, library, prefix);
        if (game != null) games.add(game);
      }
    }
    return games;
  }
}
