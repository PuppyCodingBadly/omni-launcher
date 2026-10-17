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
      File(logPath).writeAsStringSync(
        '$stamp $line\n',
        mode: FileMode.append,
      );
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
    final file = File(path);
    if (!file.existsSync()) return;
    final mode = file.statSync().mode;
    if (mode & 0x49 != 0) return; // any of the three exec bits
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
    return which(program);
  }

  /// Start [game] detached from us; returns its pid.
  static Future<int?> launch(Game game) async {
    if (!game.launchable) {
      throw StateError('${game.name}: no launch command known');
    }
    final cwd = game.cwd != null && Directory(game.cwd!).existsSync() ? game.cwd : null;
    final command = expandPaths(game.command);
    ensureExecutable(command.first, cwd: cwd);
    if (resolveProgram(command, cwd: cwd) == null) {
      throw StateError('${game.name}: command not found: ${game.command.first}');
    }
    AppPaths.ensureDirs();
    // `exec` keeps the game's pid, the redirection keeps its output in the log.
    final script = 'exec ${quoteCommand(command)} >> ${quoteCommand([logPath])} 2>&1';
    final host = Host.command(['sh', '-c', script]);
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
    await Process.start(host.first, host.sublist(1), mode: ProcessStartMode.detached);
  }

  /// Open a URL in whatever the desktop uses for links.
  static Future<void> openUrl(String url) async {
    final host = Host.command(['xdg-open', url]);
    await Process.start(host.first, host.sublist(1), mode: ProcessStartMode.detached);
  }
}
