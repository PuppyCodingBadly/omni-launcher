import 'dart:io';

/// The host machine, as seen from inside a flatpak sandbox.
///
/// A sandboxed app gets its own `$HOME` (`<real home>/.var/app/<app id>`), its
/// own `/usr` (the runtime) and no `flatpak` command, so anything that has to
/// reach the real machine goes through here: the real home, the host's system
/// paths (`/run/host/...`) and `flatpak-spawn --host` for commands.
///
/// Natively every method is the identity, which keeps the plain build exactly
/// as it was.
class Host {
  static bool? _inFlatpakForTest;

  /// True inside a flatpak sandbox.
  static bool get inFlatpak =>
      _inFlatpakForTest ?? File('/.flatpak-info').existsSync();

  /// Test seam for [inFlatpak].
  static void setInFlatpakForTest(bool? value) => _inFlatpakForTest = value;

  /// The user's real home directory.
  ///
  /// Inside a sandbox flatpak sets `HOME` to `<real home>/.var/app/<app id>`,
  /// so the real home is three path components up.
  static String get home {
    final sandboxHome = Platform.environment['HOME'] ?? '/tmp';
    if (!inFlatpak) return sandboxHome;
    final parts = sandboxHome.split('/').where((part) => part.isNotEmpty).toList();
    final cut = parts.length - 3;
    if (cut > 0 && parts[cut] == '.var' && parts[cut + 1] == 'app') {
      return '/${parts.sublist(0, cut).join('/')}';
    }
    return sandboxHome;
  }

  /// The user's data directory *on the host* (`~/.local/share`).
  ///
  /// A sandbox's `XDG_DATA_HOME` points inside the sandbox, which is not where
  /// other launchers keep their data.
  static String get dataHome => inFlatpak
      ? '$home/.local/share'
      : (Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share');

  /// A host system path, as seen from inside the sandbox.
  static String path(String hostPath) =>
      inFlatpak && hostPath.startsWith('/') ? '/run/host$hostPath' : hostPath;

  /// [argv] ready to run: on the host when sandboxed.
  static List<String> command(List<String> argv) =>
      inFlatpak ? ['flatpak-spawn', '--host', ...argv] : argv;

  /// Directories that hold host binaries, nearest first.
  static List<String> get binaryDirs => [
    if (inFlatpak) ...[
      '/run/host/usr/local/bin',
      '/run/host/usr/bin',
      '/run/host/bin',
      '$home/.local/bin',
    ] else
      ...(Platform.environment['PATH'] ?? '').split(':'),
  ];
}
