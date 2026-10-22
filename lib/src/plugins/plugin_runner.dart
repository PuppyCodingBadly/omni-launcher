import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../host.dart';
import '../model/game.dart';
import '../util/proc.dart';
import 'plugin.dart';

/// How long a plugin may take before it is killed.
const Duration pluginTimeout = Duration(seconds: 30);

/// How much a plugin may print before it is killed: a plugin that floods its
/// stdout must not be able to eat the launcher's memory.
const int pluginOutputLimit = 256 * 1024;

/// How long the last of a plugin's output is waited for once it has exited.
///
/// A plugin that leaves a process of its own behind can hold its pipes open for
/// good; the output that arrived by then is all there is.
const Duration pluginOutputGrace = Duration(seconds: 2);

/// The plugins in [dir]: every subfolder with a `plugin.json` the launcher can
/// read, in name order.
///
/// A folder that cannot be read is reported through [onError] and left out, so
/// one broken plugin cannot hide the others.
List<Plugin> discoverPlugins(
  String dir, {
  void Function(String dir, Object error)? onError,
}) {
  final root = Directory(dir);
  List<FileSystemEntity> entries;
  try {
    if (!root.existsSync()) return const [];
    entries = root.listSync()..sort((a, b) => a.path.compareTo(b.path));
  } on FileSystemException catch (error) {
    onError?.call(dir, error);
    return const [];
  }
  final plugins = <Plugin>[];
  for (final entry in entries) {
    if (entry is! Directory) continue;
    // A folder whose name starts with a dot is an install's staging or
    // backup (".<id>.new", ".<id>.old"), not a plugin to run.
    if (entry.path.split('/').last.startsWith('.')) continue;
    final manifest = File('${entry.path}/plugin.json');
    try {
      if (!manifest.existsSync()) continue;
      final plugin = Plugin.fromManifest(
        entry.path,
        jsonDecode(manifest.readAsStringSync()),
      );
      if (plugin == null) {
        onError?.call(entry.path, 'plugin.json does not describe a plugin');
        continue;
      }
      plugins.add(plugin);
    } on FileSystemException catch (error) {
      onError?.call(entry.path, error);
    } on FormatException catch (error) {
      onError?.call(entry.path, error.message);
    }
  }
  return plugins;
}

/// What a plugin is asked about.
///
/// The detail panel asks about a game from the library; the settings page asks
/// about a name the user typed. A plugin is told which, so it can use the id
/// when there is one and fall back to the name when there is not.
class PluginQuery {
  PluginQuery.forGame(Game game) : game = game, name = game.name;

  PluginQuery.byName(String name) : game = null, name = name.trim();

  /// The game, when the query came from one.
  final Game? game;

  /// The name to look up.
  final String name;

  /// What the answer is remembered under.
  String get id => game?.id ?? 'name:$name';

  Map<String, Object?> toJson() => {
    'action': 'lookup',
    'game': {
      'id': id,
      'key': game?.key ?? '',
      'name': name,
      // A query from the settings page has no source of its own.
      'source': game?.source.id ?? 'search',
      'path': game?.path,
      'cwd': game?.cwd,
      'command': game?.command ?? const <String>[],
      'extra': game?.extra ?? const <String, Object?>{},
    },
  };
}

/// Ask [plugin] about [query]. Never throws: every way a plugin can fail comes
/// back as a failed answer, because the caller has to say something either way.
Future<PluginAnswer> runPlugin(
  Plugin plugin,
  PluginQuery query, {
  Duration timeout = pluginTimeout,
}) async {
  // setsid puts the plugin in a session — and so a process group — of its
  // own, so a timeout can kill everything it started, not just the plugin
  // itself. It goes inside any sandbox wrapper: the group has to be made on
  // the host, where the plugin runs.
  //
  // Under Flatpak the direct child is flatpak-spawn, whose host-side plugin is
  // not in its process group or its descendant tree. The host shell records
  // the plugin's own pid file before `exec`-ing it, so a timeout can signal
  // the real process group on the host rather than only the wrapper.
  final pidFile = '${plugin.dir}/.run.pid';
  try {
    File(pidFile).deleteSync();
  } on FileSystemException {
    // No stale pid file to clear.
  }
  final argv = Host.command([
    'setsid',
    'sh',
    '-c',
    r'echo $$ > "$1"; shift; exec "$@"',
    'sh',
    pidFile,
    ...plugin.command,
  ], directory: plugin.dir);
  final Process process;
  try {
    process = await Process.start(
      argv.first,
      argv.sublist(1),
      workingDirectory: plugin.dir,
    );
  } on ProcessException catch (error) {
    return PluginAnswer.failure('${plugin.name}: ${error.message}');
  }

  // Both pipes have to be drained while the plugin runs, or a plugin that says
  // a lot before it exits would block on its own output.
  final out = _Pipe(
    process.stdout,
    // A flooding plugin is killed the same way a timed-out one is: a helper
    // it forked does not get to stay behind and hold the pipes.
    onOverflow: () => unawaited(_killGroup(process, pidFile: pidFile)),
  );
  final err = _Pipe(process.stderr);
  try {
    process.stdin.write(jsonEncode(query.toJson()));
    await process.stdin.close();
  } on IOException {
    // A plugin that closed its stdin early shows up in its exit code.
  }

  int code;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    await _killGroup(process, pidFile: pidFile);
    await process.exitCode;
    out.stop();
    err.stop();
    return PluginAnswer.failure(
      '${plugin.name} did not answer within ${timeout.inSeconds}s',
    );
  }

  // The plugin is gone; the pid file has done its job.
  _deletePidFile(pidFile);
  await Future.wait([out.finished, err.finished]).timeout(
    pluginOutputGrace,
    onTimeout: () {
      out.stop();
      err.stop();
      return const <void>[];
    },
  );

  if (out.tooLong) {
    return PluginAnswer.failure(
      '${plugin.name} printed more than ${pluginOutputLimit ~/ 1024} KiB',
    );
  }
  final complaint = err.text.trim();
  if (code != 0) {
    return PluginAnswer.failure(
      '${plugin.name}: ${complaint.isEmpty ? 'exited with $code' : _lastLine(complaint)}',
    );
  }

  Object? decoded;
  try {
    decoded = jsonDecode(out.text.trim());
  } on FormatException {
    return PluginAnswer.failure('${plugin.name}: the answer was not JSON');
  }
  final parsed = PluginAnswer.fromJson(decoded);
  if (parsed == null) {
    return PluginAnswer.failure('${plugin.name}: the answer made no sense');
  }
  if (parsed.fields.isEmpty && parsed.url == null && parsed.ok) {
    return PluginAnswer.failure(
      '${plugin.name} found nothing for ${query.name}',
    );
  }
  return parsed;
}

/// Kill [process] and whatever it left running.
///
/// setsid made the plugin the leader of its own process group, so the signal
/// goes to the group: a plugin that forked a helper and stopped answering
/// loses the helper too. When the group is gone already — or a sandbox
/// renumbered the pid, so the group only exists on the host — the plugin
/// itself is still killed on its own.
Future<void> _killGroup(Process process, {String? pidFile}) async {
  try {
    await Process.run('kill', ['-KILL', '-${process.pid}']);
  } on ProcessException {
    // No kill(1) on this machine: the sweep below still has the plugin.
  }
  if (Host.inFlatpak && pidFile != null) {
    // The pid above is flatpak-spawn's; the plugin lives on the host, outside
    // both the wrapper's group and its descendant tree. The pid file records
    // the group leader created by setsid, so signal it on the host.
    final hostPid = await _readHostPid(pidFile);
    if (hostPid != null) {
      for (final signal in ['-$hostPid', '$hostPid']) {
        final argv = Host.command(['kill', '-KILL', signal]);
        try {
          await Process.run(argv.first, argv.sublist(1));
        } on ProcessException {
          // The group may be gone; the bare pid above is the fallback, and a
          // plugin that already exited needs neither.
        }
      }
    }
  }
  // The group signal can be missing or refused — a sandbox that renumbered the
  // pid, a PATH without kill(1) — so the process tree is walked as well.
  // Children first: once the plugin is gone they are reparented out of reach.
  final children = <int, int>{};
  for (final pid in descendants(process.pid)) {
    final started = processStartTime(pid);
    if (started != null) children[pid] = started;
  }
  for (final child in children.entries) {
    // A pid is recycled the moment its process dies: signal it only while it
    // is still the process that was found, start time and all, never the
    // stranger that has taken its number since.
    if (processStartTime(child.key) != child.value) continue;
    Process.killPid(child.key, ProcessSignal.sigkill);
  }
  process.kill(ProcessSignal.sigkill);
  if (pidFile != null) _deletePidFile(pidFile);
}

/// The plugin pid recorded by the host shell, or null when it did not get far
/// enough to write one (a plugin killed for flooding while still starting).
Future<int?> _readHostPid(String path) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      final pid = int.tryParse(File(path).readAsStringSync().trim());
      if (pid != null && pid > 0) return pid;
    } on FileSystemException {
      // Not written yet.
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return null;
}

void _deletePidFile(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone.
  }
}

/// The last line of a plugin's stderr: a traceback ends with the actual
/// complaint, and a one line message is its own last line.
String _lastLine(String text) {
  final lines = text.split('\n');
  for (var index = lines.length - 1; index >= 0; index--) {
    final line = lines[index].trim();
    if (line.isNotEmpty) return line;
  }
  return text;
}

/// One of a plugin's pipes, read as it arrives.
class _Pipe {
  _Pipe(Stream<List<int>> stream, {void Function()? onOverflow}) {
    _subscription = stream.listen(
      (chunk) {
        if (tooLong) return;
        _bytes.add(chunk);
        if (_bytes.length > pluginOutputLimit) {
          tooLong = true;
          onOverflow?.call();
        }
      },
      onDone: _finish,
      onError: (_) => _finish(),
    );
  }

  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final Completer<void> _finished = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  /// True once the plugin has printed more than [pluginOutputLimit].
  bool tooLong = false;

  String? _text;

  /// Everything that arrived, read once and kept.
  String get text =>
      _text ??= utf8.decode(_bytes.takeBytes(), allowMalformed: true);

  /// Completes when the pipe closes.
  Future<void> get finished => _finished.future;

  /// Stop reading. The write end may never close, since a process the plugin
  /// left behind can hold it, and nothing more is wanted from it.
  void stop() {
    _subscription.cancel().ignore();
    _finish();
  }

  void _finish() {
    if (!_finished.isCompleted) _finished.complete();
  }
}
