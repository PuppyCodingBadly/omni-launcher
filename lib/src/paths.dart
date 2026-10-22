import 'dart:io';

import 'host.dart';

/// XDG paths for this launcher's own config, cache and state.
class AppPaths {
  static const String appId = 'io.github.PuppyCodingBadly.OmniLauncher';
  static const String appName = 'Omni Launcher';
  static const String version = '0.3.1';

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
  static String get coverDir => '$cacheDir/covers';
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

  /// Copy the files directly in [from] that [to] does not have yet; returns
  /// what it wrote. Subfolders, such as the cover cache, are left out: they
  /// come back on their own.
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
