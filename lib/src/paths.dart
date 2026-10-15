import 'dart:io';
import 'host.dart';

/// XDG paths for this launcher's own config, cache and state.
class AppPaths {
  static const String appId = 'io.github.PuppyCodingBadly.OmniLauncher';
  static const String appName = 'Omni Launcher';
  static const String version = '0.1.2';

  static String get home => Host.home;

  static String _xdg(String variable, String fallback) {
    final value = Platform.environment[variable];
    if (value != null && value.isNotEmpty) return value;
    return '$home/$fallback';
  }

  static String get configDir => '${_xdg('XDG_CONFIG_HOME', '.config')}/omnilauncher-flutter';
  static String get cacheDir => '${_xdg('XDG_CACHE_HOME', '.cache')}/omnilauncher-flutter';
  static String get stateDir => '${_xdg('XDG_STATE_HOME', '.local/state')}/omnilauncher-flutter';

  static String get configFile => '$configDir/config.json';
  static String get cacheFile => '$cacheDir/games.json';
  static String get coverDir => '$cacheDir/covers';
  static String get launchLog => '$stateDir/launch.log';
  static String get playtimeFile => '$stateDir/playtime.json';

  /// `XDG_DATA_DIRS`, defaulted like the spec says.
  static List<String> get dataDirs {
    final value = Platform.environment['XDG_DATA_DIRS'];
    final raw = (value == null || value.isEmpty) ? '/usr/local/share:/usr/share' : value;
    return raw.split(':').where((p) => p.isNotEmpty).toList();
  }

  static void ensureDirs() {
    for (final dir in [configDir, cacheDir, coverDir, stateDir]) {
      Directory(dir).createSync(recursive: true);
    }
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
