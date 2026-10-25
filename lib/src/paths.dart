import 'dart:io';

import 'host.dart';

/// XDG paths for this launcher's own config, cache and state.
class AppPaths {
  static const String appId = 'io.github.PuppyCodingBadly.OmniLauncher';
  static const String appName = 'Omni Launcher';
  static const String version = '0.3.5';

  static String get home => Host.home;

  /// One of the XDG folders this launcher keeps its own files in.
  ///
  /// Inside a flatpak the XDG variables point at the sandbox's own folders.
  /// This launcher's config, cache and state belong with the rest of the
  /// host's — a native build and the flatpak have to see the same hidden games,
  /// the same renames and the same playtime — so the sandbox's answer is
  /// ignored and the host's own layout is used.
  static String _xdg(String variable, String fallback) {
    if (!Host.inFlatpak) {
      final value = Platform.environment[variable];
      if (value != null && value.isNotEmpty) return value;
    }
    return '$home/$fallback';
  }

  static String get configDir =>
      '${_xdg('XDG_CONFIG_HOME', '.config')}/omnilauncher-flutter';
  static String get cacheDir =>
      '${_xdg('XDG_CACHE_HOME', '.cache')}/omnilauncher-flutter';
  static String get stateDir =>
      '${_xdg('XDG_STATE_HOME', '.local/state')}/omnilauncher-flutter';

  static String get configFile => '$configDir/config.json';
  static String get cacheFile => '$cacheDir/games.json';

  /// Downloaded artwork lives with the launcher's data, not in the cache.
  ///
  /// A Steam capsule can be fetched again, but a SteamGridDB pick cannot: the
  /// grid the user chose is not guaranteed to be in the list any more. Cache
  /// folders are the first thing an update or a cleanup empties, which is
  /// exactly what must not happen to a pick, so both kinds live here.
  static String get coverDir => '${Host.dataHome}/omnilauncher-flutter/covers';

  /// Where earlier builds cached artwork, before it moved out of the cache.
  static String get legacyCoverDir => '$cacheDir/covers';

  /// Where a sandboxed build cached artwork, when that is this side's view.
  static String? get sandboxCoverDir {
    if (!Host.inFlatpak) return null;
    final cache = Platform.environment['XDG_CACHE_HOME'];
    if (cache == null || cache.isEmpty) return null;
    return '$cache/omnilauncher-flutter/covers';
  }

  static String get launchLog => '$stateDir/launch.log';
  static String get playtimeFile => '$stateDir/playtime.json';
  static String get pluginAnswerFile => '$cacheDir/plugin_answers.json';

  /// Where plugins live: the host's data directory rather than the sandbox's,
  /// so a plugin can be dropped in from outside the flatpak.
  static String get pluginDir =>
      '${Host.dataHome}/omnilauncher-flutter/plugins';

  /// `XDG_DATA_DIRS`, defaulted like the spec says.
  static List<String> get dataDirs {
    final value = Platform.environment['XDG_DATA_DIRS'];
    final raw = (value == null || value.isEmpty)
        ? '/usr/local/share:/usr/share'
        : value;
    return raw.split(':').where((p) => p.isNotEmpty).toList();
  }

  static void ensureDirs() {
    for (final dir in [configDir, cacheDir, coverDir, stateDir]) {
      Directory(dir).createSync(recursive: true);
    }
  }

  /// Take over what a sandboxed launcher stored inside the sandbox.
  ///
  /// A flatpak used to keep the config and the playtime history in
  /// `~/.var/app/<id>/`, because that is where its XDG variables pointed; a
  /// file the host does not have yet is copied to where it belongs now, so
  /// nothing an earlier version collected is lost. A file that is already on
  /// the host is left alone: that is the newer one.
  ///
  /// Returns the paths it wrote.
  static List<String> adoptSandboxFiles() {
    if (!Host.inFlatpak) return const [];
    final adopted = <String>[];
    for (final (variable, target) in [
      ('XDG_CONFIG_HOME', configDir),
      ('XDG_STATE_HOME', stateDir),
    ]) {
      final sandbox = Platform.environment[variable];
      if (sandbox == null || sandbox.isEmpty) continue;
      adopted.addAll(adoptFiles('$sandbox/omnilauncher-flutter', target));
    }
    return adopted;
  }

  /// The launcher's data location for a file that was cached under one of the
  /// old cover folders, copying it across when only the old copy exists.
  ///
  /// A path outside those folders is returned unchanged: it is not ours to
  /// move.
  static String rehomeCover(String path, {String? from, String? to}) {
    final sandbox = from == null ? sandboxCoverDir : null;
    final roots = <String>[?from, if (from == null) legacyCoverDir, ?sandbox];
    String? root;
    for (final candidate in roots) {
      if (path.startsWith('$candidate/')) {
        root = candidate;
        break;
      }
    }
    if (root == null) return path;
    final name = path.substring(root.length + 1);
    final rehomed = '${to ?? coverDir}/$name';
    if (!File(rehomed).existsSync() && File(path).existsSync()) {
      try {
        File(rehomed)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(File(path).readAsBytesSync());
      } on FileSystemException {
        // A copy that fails leaves the old path in place: the pin can still
        // be fetched again, so failing here must not lose the reference.
        return path;
      }
    }
    return rehomed;
  }

  /// Copy the files directly in [from] that [to] does not have yet; returns
  /// what it wrote. Subfolders are left out: the cover folder has its own
  /// adoption path, and anything else is not the launcher's.
  static List<String> adoptFiles(String from, String to) {
    final source = Directory(from);
    if (!source.existsSync()) return const [];
    List<FileSystemEntity> entries;
    try {
      entries = source.listSync();
    } on FileSystemException {
      return const [];
    }
    final written = <String>[];
    for (final entry in entries) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final target = File('$to/$name');
      if (target.existsSync()) continue;
      try {
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(entry.readAsBytesSync());
      } on FileSystemException {
        continue;
      }
      written.add(target.path);
    }
    return written;
  }

  /// Expands `~` and environment variables in a user supplied path.
  ///
  /// An undefined variable is left as written, like `os.path.expandvars`, so a
  /// typo cannot silently turn into a path that happens to exist.
  static String expand(String path) {
    var result = path;
    if (result == '~' || result.startsWith('~/')) {
      result = '$home${result.substring(1)}';
    }
    result = result.replaceAllMapped(
      RegExp(r'\$\{(\w+)\}|\$(\w+)'),
      (match) =>
          Platform.environment[match.group(1) ?? match.group(2)!] ??
          match.group(0)!,
    );
    return result;
  }
}
