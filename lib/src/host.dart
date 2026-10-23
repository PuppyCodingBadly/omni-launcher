import 'dart:io';

/// Where the host's own filesystem is mounted inside the sandbox.
const String _hostMount = '/run/host';

/// Any of the three POSIX execute bits (`0111`).
const int _execBits = 0x49;

/// How many links to follow before calling a path unreachable.
const int _linkHops = 8;

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
  static String? _mountForTest;
  static String _spawnForTest = 'flatpak-spawn';

  /// True inside a flatpak sandbox.
  static bool get inFlatpak =>
      _inFlatpakForTest ?? File('/.flatpak-info').existsSync();

  /// Test seam for [inFlatpak].
  static void setInFlatpakForTest(bool? value) => _inFlatpakForTest = value;

  /// Test seam for the host mount, so a test can point at a stand-in tree.
  static void setMountForTest(String? value) => _mountForTest = value;

  /// Test seam for the flatpak-spawn executable, so a test can record the
  /// host command without a sandbox.
  static void setHostSpawnForTest(String? value) =>
      _spawnForTest = value ?? 'flatpak-spawn';

  /// The host mount, as this side knows it.
  static String get _mount => _mountForTest ?? _hostMount;

  /// The user's real home directory.
  ///
  /// Inside a sandbox flatpak sets `HOME` to `<real home>/.var/app/<app id>`,
  /// so the real home is three path components up.
  static String get home {
    final sandboxHome = Platform.environment['HOME'] ?? '/tmp';
    if (!inFlatpak) return sandboxHome;
    final parts = sandboxHome
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
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
      inFlatpak && hostPath.startsWith('/') ? '$_mount$hostPath' : hostPath;

  /// Where [hostPath] is on this side: at its own path when the sandbox carries
  /// it — a granted folder such as `~/Games`, a mounted drive — and through the
  /// host mount otherwise.
  ///
  /// The mount holds the host's own `/usr`, `/etc` and the like. Both places
  /// have to be tried: a granted folder is mounted where it lives on the host,
  /// not under the mount.
  static String reachable(String hostPath) {
    if (!inFlatpak) return hostPath;
    if (present(hostPath)) return hostPath;
    return path(hostPath);
  }

  /// Whether [path] is there at all.
  ///
  /// A link counts, even one whose target the sandbox cannot follow: the host's
  /// own binaries are links into its `/usr`, and that target is only there
  /// through the host mount.
  static bool present(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  /// Whether the host can run [hostPath]: a regular file with an execute bit.
  ///
  /// Not a plain `stat`: `/usr/bin/steam` is a link to
  /// `/usr/lib/steam/bin_steam.sh`, and from inside the sandbox that target is
  /// only there through the host mount, so a link is followed by re-rooting an
  /// absolute target at the mount. A link whose target the sandbox cannot see
  /// reports itself as `notFound` rather than failing, which is why the link is
  /// asked where it points before the answer is believed.
  static bool runnable(String hostPath) {
    var current = reachable(hostPath);
    for (var hop = 0; hop < _linkHops; hop++) {
      FileStat? stat;
      try {
        stat = File(current).statSync();
      } on FileSystemException {
        stat = null;
      }
      if (stat != null && stat.type == FileSystemEntityType.file) {
        return stat.mode & _execBits != 0;
      }
      final next = _linkTarget(current);
      if (next == null) return false;
      current = next;
    }
    return false;
  }

  /// Where the link at [path] points, as this side can reach it; null when
  /// [path] is not a link.
  static String? _linkTarget(String path) {
    final String target;
    try {
      target = Link(path).targetSync();
    } on FileSystemException {
      return null;
    }
    if (target.isEmpty) return null;
    if (!target.startsWith('/')) {
      final slash = path.lastIndexOf('/');
      return slash < 0 ? target : '${path.substring(0, slash)}/$target';
    }
    // A link inside the mount points at a host path, wherever the sandbox would
    // look for that path itself.
    return _inMount(path) ? Host.path(target) : target;
  }

  /// Whether [path] is inside the host mount.
  static bool _inMount(String path) =>
      inFlatpak && (path == _mount || path.startsWith('$_mount/'));

  /// [argv] ready to run: on the host when sandboxed.
  ///
  /// [directory] is the folder to run in, and [environment] the extra
  /// variables the game wants. Both have to be passed to the host helper as
  /// well, since the sandbox's own working directory and environment are not
  /// the game's.
  static List<String> command(
    List<String> argv, {
    String? directory,
    Map<String, String> environment = const {},
  }) => inFlatpak
      ? [
          _spawnForTest,
          '--host',
          if (directory != null) '--directory=$directory',
          for (final entry in environment.entries)
            '--env=${entry.key}=${entry.value}',
          ...argv,
        ]
      : argv;

  /// Directories that hold host binaries, nearest first, named the way the host
  /// names them: a search through the mount has to answer with a path the host
  /// can run, since that is where a launch ends up.
  static List<String> get binaryDirs => inFlatpak
      ? ['/usr/local/bin', '/usr/bin', '/bin', '$home/.local/bin']
      : (Platform.environment['PATH'] ?? '').split(':');
}
