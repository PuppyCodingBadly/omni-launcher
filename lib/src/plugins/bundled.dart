import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../paths.dart';
import 'plugin.dart';

/// A plugin that ships with the launcher.
class BundledPlugin {
  const BundledPlugin({required this.id, required this.files});

  /// The folder it installs to, under the plugins directory.
  final String id;

  /// Its files, as assets under `assets/plugins/<id>/`.
  final List<String> files;
}

/// The plugins that ship with the launcher, from `plugins/<id>/` in the
/// repository.
const List<BundledPlugin> bundledPlugins = [
  BundledPlugin(id: 'howlongtobeat', files: ['plugin.json', 'hltb.py']),
];

/// Whether [id] is one of the plugins that ship with the launcher.
///
/// Those are installed again at every start, so the store does not offer to
/// remove them: it would only come back.
bool isBundledPlugin(String id) =>
    bundledPlugins.any((plugin) => plugin.id == id);

/// Reads one of the launcher's own assets.
typedef AssetReader = Future<String> Function(String asset);

/// The reader the app uses: the shipped plugins live in the Flutter bundle.
Future<String> bundledAsset(String asset) => rootBundle.loadString(asset);

/// Install the shipped plugins into [dir] (the plugins directory by default)
/// and return the ids that were written.
///
/// A plugin that is already installed is left alone unless the shipped copy has
/// a higher version in its manifest, so a local fix survives: the version in a
/// plugin's own manifest is how its author takes the shipped copy back.
Future<List<String>> installBundledPlugins({
  String? dir,
  AssetReader? read,
}) async {
  final assets = read ?? bundledAsset;
  final target = dir ?? AppPaths.pluginDir;
  final written = <String>[];
  for (final bundled in bundledPlugins) {
    final folder = '$target/${bundled.id}';
    final shipped = _manifest(await assets(_assetPath(bundled, 'plugin.json')));
    final installed = _manifest(_readFile('$folder/plugin.json'));
    // An unreadable installed copy counts as no copy at all.
    if (installed != null &&
        Plugin.versionOf(installed) >= Plugin.versionOf(shipped)) {
      continue;
    }
    Directory(folder).createSync(recursive: true);
    for (final file in bundled.files) {
      File('$folder/$file')
          .writeAsStringSync(await assets(_assetPath(bundled, file)));
    }
    written.add(bundled.id);
  }
  return written;
}

String _assetPath(BundledPlugin plugin, String file) =>
    'plugins/${plugin.id}/$file';

/// The manifest in [text], or `null` when there is nothing to read.
Object? _manifest(String? text) {
  if (text == null) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

String? _readFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    return file.readAsStringSync();
  } on FileSystemException {
    return null;
  }
}
