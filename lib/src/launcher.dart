import 'dart:io';

import 'host.dart';
import 'model/game.dart';
import 'paths.dart';
import 'util/proc.dart';
import 'util/shell.dart';

/// Starting games: argv resolution, detaching and logging.
class Launcher {
  static String formatCommand(Game game) => quoteCommand(game.command);

  /// Where the launch line and the game's own output are written.
  ///
  /// Overridable so tests never append to the real log.
  static String? logPathOverrideForTest;

  static String get logPath => logPathOverrideForTest ?? AppPaths.launchLog;

  static void log(String line) {
    try {
      AppPaths.ensureDirs();
      final stamp = DateTime.now().toIso8601String();
      File(logPath).writeAsStringSync('$stamp $line\n', mode: FileMode.append);
    } on FileSystemException {
      // Logging must never stop a launch.
    }
  }

  /// AppImages downloaded through a browser lose their exec bit.
  ///
  /// The chmod runs on the host: the sandbox's own view of the file may be a
  /// read-only mount.
  static void ensureExecutable(String program, {String? cwd}) {
    final path = _programPath(program, cwd);
    if (path == null) return;
    // One stat answers both "is it there" and "does it need the exec bit".
    final FileStat stat;
    try {
      stat = File(path).statSync();
    } on FileSystemException {
      return;
    }
    if (stat.type != FileSystemEntityType.file) return;
    if (stat.mode & 0x49 != 0) return; // any of the three exec bits
    try {
      final host = Host.command(['chmod', '+x', path]);
      if (Process.runSync(host.first, host.sublist(1)).exitCode == 0) {
        log('chmod +x $path');
      }
    } on ProcessException {
      // Leave it to the shell to complain.
    }
  }

  /// [command] with a leading `~` (or `~/`) expanded to the host's home, and
  /// `$VAR`/`${VAR}` replaced from the environment.
  ///
  /// The launch line quotes every word and a shell does not expand either
  /// inside quotes, so the expansion has to happen here, before quoting. A
  /// variable that is not set stays as written: the command still reaches the
  /// shell exactly as the user typed it, rather than losing the text.
  static List<String> expandPaths(List<String> command) => [
    for (final word in command) _expandWord(word),
  ];

  static String _expandWord(String word) {
    var expanded = word;
    if (expanded == '~') {
      expanded = AppPaths.home;
    } else if (expanded.startsWith('~/')) {
      expanded = '${AppPaths.home}${expanded.substring(1)}';
    }
    return expanded.replaceAllMapped(
      RegExp(r'\$(?:([A-Za-z_]\w*)|\{([A-Za-z_]\w*)\})'),
      (match) {
        final name = match.group(1) ?? match.group(2)!;
        return Platform.environment[name] ?? match.group(0)!;
      },
    );
  }

  /// Where [program] lives, or `null` when that cannot be told from here.
  ///
  /// A bare name is looked up on `PATH`. `~` and defined `$VAR`s are expanded
  /// by [expandPaths] before a launch gets here; an unset variable does not
  /// have a path of its own either.
  static String? _programPath(String program, String? cwd) {
    if (!program.contains('/')) return null;
    if (program.startsWith('~') || program.contains(r'$')) return null;
    if (program.startsWith('/') || cwd == null || cwd.isEmpty) return program;
    return '$cwd/$program';
  }

  /// The program [command] runs, or `null` when the shell could not run it.
  ///
  /// The launch is detached, so a binary that is missing only shows up as an
  /// error line in the log while the caller is told the game started; checking
  /// up front is the only way to report it.
  ///
  /// The command runs on the host, so a path is looked for where the host keeps
  /// it: from inside the sandbox that is the host mount for a system path such
  /// as `/usr/bin/steam`, and its own path for a granted folder.
  static String? resolveProgram(List<String> command, {String? cwd}) {
    if (command.isEmpty) return null;
    final program = command.first;
    if (program.isEmpty) return null;
    if (program.contains('/')) {
      final path = _programPath(program, cwd);
      // No path to check: pass it through as written.
      if (path == null) return program;
      return Host.runnable(path) ? path : null;
    }
    // Without a PATH the shell falls back to its own default, which we cannot
    // reproduce here; let it try rather than refusing a launch that may work.
    if ((Platform.environment['PATH'] ?? '').isEmpty) return program;
    final found = which(program);
    if (found != null) return found;
    // Inside the sandbox [Host.binaryDirs] cannot see every directory the
    // host's PATH holds, so a program that lives elsewhere would be refused
    // here even though the host shell would run it: ask the host shell
    // itself before giving up.
    if (Host.inFlatpak) return _hostLookup(program);
    return null;
  }

  /// Where the host's shell finds the bare [program], or null when it does
  /// not.
  ///
  /// One `command -v` on the host answers with the path the host would run,
  /// whatever directories the host's PATH holds that the sandbox cannot see.
  static String? _hostLookup(String program) {
    try {
      final host = Host.command([
        'sh',
        '-c',
        r'command -v "$1"',
        'sh',
        program,
      ]);
      final result = Process.runSync(host.first, host.sublist(1));
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    } on ProcessException {
      return null;
    }
  }

  /// The argv [launch] starts: [command] under a shell that appends its
  /// output to the log, wrapped for the host, in [cwd] when one is set.
  ///
  /// `exec` keeps the game's pid, the redirection keeps its output in the
  /// log. The host gets the directory too: the sandbox's own working
  /// directory means nothing there.
  static List<String> launchScript(List<String> command, {String? cwd}) {
    final script =
        'exec ${quoteCommand(command)} >> ${quoteCommand([logPath])} 2>&1';
    return Host.command(['sh', '-c', script], directory: cwd);
  }

  /// Start [game] detached from us; returns its pid.
  static Future<int?> launch(Game game) async {
    if (!game.launchable) {
      throw StateError('${game.name}: no launch command known');
    }
    final cwd = game.cwd != null && Directory(game.cwd!).existsSync()
        ? game.cwd
        : null;
    final command = expandPaths(game.command);
    ensureExecutable(command.first, cwd: cwd);
    if (resolveProgram(command, cwd: cwd) == null) {
      throw StateError(
        '${game.name}: command not found: ${game.command.first}',
      );
    }
    AppPaths.ensureDirs();
    final host = launchScript(command, cwd: cwd);
    final process = await Process.start(
      host.first,
      host.sublist(1),
      workingDirectory: cwd,
      mode: ProcessStartMode.detached,
    );
    log('launched ${game.id} pid=${process.pid} :: ${formatCommand(game)}');
    return process.pid;
  }

  /// Open a file manager at the game's folder, or the folder itself.
  static Future<void> openFolder(String path) async {
    final host = Host.command(['xdg-open', path]);
    await Process.start(
      host.first,
      host.sublist(1),
      mode: ProcessStartMode.detached,
    );
  }

  /// Open a URL in whatever the desktop uses for links.
  static Future<void> openUrl(String url) async {
    final host = Host.command(['xdg-open', url]);
    await Process.start(
      host.first,
      host.sublist(1),
      mode: ProcessStartMode.detached,
    );
  }
}
