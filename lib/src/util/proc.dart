import 'dart:convert';
import 'dart:io';

import '../host.dart';

/// Run a command and return stdout, or the empty string on any failure.
///
/// `Process.start` rather than `Process.run`, because a timeout has to kill
/// the child: a timed-out `Process.run` keeps it running.
Future<String> runCapture(
  List<String> argv, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    final host = Host.command(argv);
    final process = await Process.start(host.first, host.sublist(1));
    // Nothing is ever written to the child: closing stdin keeps a command
    // that reads it, or waits for its end, from stalling the capture.
    try {
      await process.stdin.close();
    } on Object {
      // A child that already exited took its end of the pipe with it.
    }
    final out = StringBuffer();
    final reading = process.stdout.transform(utf8.decoder).forEach(out.write);
    // stderr is drained rather than read, so a chatty command cannot stall on
    // a full pipe.
    final draining = process.stderr.drain<void>();
    var timedOut = false;
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (timedOut || code != 0) {
      // A descendant can hold the pipes after the direct child is gone — a
      // backgrounded shell command, or flatpak-spawn's host-side process. The
      // capture has already given up; waiting on those pipes would make the
      // timeout meaningless.
      reading.ignore();
      draining.ignore();
      return '';
    }
    // A successful run closes its pipes; awaiting them here keeps the capture
    // from returning before the last output arrived.
    try {
      await reading;
      await draining;
    } on Object {
      return '';
    }
    return out.toString();
  } on ProcessException {
    return '';
  }
}

/// Fields of `/proc/<pid>/stat` from the state field onwards, or null when the
/// process is gone.
///
/// The command name sits in parentheses and may itself contain spaces and
/// parentheses, so the fields are taken from the last `)`.
List<String>? _statFields(int pid) {
  String text;
  try {
    text = File('/proc/$pid/stat').readAsStringSync();
  } on FileSystemException {
    return null;
  }
  final close = text.lastIndexOf(')');
  if (close < 0 || close + 2 > text.length) return null;
  final fields = text.substring(close + 2).split(' ');
  return fields.length > 1 ? fields : null;
}

/// Whether [pid] is a live process. A zombie is not.
bool processRunning(int pid) {
  final fields = _statFields(pid);
  if (fields == null) return false;
  final state = fields.first;
  return state != 'Z' && state != 'X';
}

/// When [pid] started, in clock ticks since boot; null when it is gone.
///
/// Together with the pid this identifies a process: a recycled pid gets a new
/// start time, so a caller can tell the process it started from a stranger.
int? processStartTime(int pid) {
  final fields = _statFields(pid);
  if (fields == null || fields.length < 20) return null;
  return int.tryParse(fields[19]);
}

/// The parent pid of [pid], or null when the process is gone.
int? parentPid(int pid) {
  final fields = _statFields(pid);
  if (fields == null) return null;
  return int.tryParse(fields[1]);
}

/// One read of a process: whether it is live and when it started.
///
/// Both facts come from a single `/proc/<pid>/stat` read, so a caller that
/// needs the two together never races a recycled pid between two reads.
class ProcessSnapshot {
  const ProcessSnapshot({required this.running, required this.startTime});

  /// Whether the process is live. A zombie is not.
  final bool running;

  /// When the process started, in clock ticks since boot; null when the stat
  /// was too short to tell. Together with the pid this identifies a process:
  /// a recycled pid gets a new start time, so a caller can tell the process
  /// it started from a stranger.
  final int? startTime;
}

/// A snapshot of [pid] from one read of its `/proc/<pid>/stat`, or null when
/// the process is gone.
ProcessSnapshot? processSnapshot(int pid) {
  final fields = _statFields(pid);
  if (fields == null) return null;
  final state = fields.first;
  return ProcessSnapshot(
    running: state != 'Z' && state != 'X',
    startTime: fields.length >= 20 ? int.tryParse(fields[19]) : null,
  );
}

/// Everything running below [pid] (not [pid] itself).
///
/// One pass over `/proc` builds the parent map, then the tree is walked in
/// memory, so the cost does not grow with the depth of the tree.
Set<int> descendants(int pid) {
  final byParent = <int, List<int>>{};
  for (final candidate in _runningPids()) {
    final parent = parentPid(candidate);
    if (parent == null) continue;
    (byParent[parent] ??= <int>[]).add(candidate);
  }
  final found = <int>{};
  final pending = <int>[pid];
  while (pending.isNotEmpty) {
    for (final child in byParent[pending.removeLast()] ?? const <int>[]) {
      if (found.add(child)) pending.add(child);
    }
  }
  return found;
}

/// The numeric entries of `/proc`: every process the kernel is tracking.
List<int> _runningPids() {
  List<FileSystemEntity> entries;
  try {
    entries = Directory('/proc').listSync(followLinks: false);
  } on FileSystemException {
    return const [];
  }
  final pids = <int>[];
  for (final entry in entries) {
    final pid = int.tryParse(_entryName(entry));
    if (pid != null) pids.add(pid);
  }
  return pids;
}

/// The last path component of [entry] (`/proc/1234` -> `1234`).
///
/// `uri.pathSegments` cannot be used here: a directory URI keeps the trailing
/// slash, so its last segment is empty.
String _entryName(FileSystemEntity entry) {
  final path = entry.path;
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// `shutil.which`: first executable `name` on `PATH`.
///
/// [searchPath] overrides the `PATH` that is searched. A candidate has to be a
/// regular file carrying an execute bit, so a non-executable file that shadows
/// the real binary is skipped instead of being returned.
///
/// The answer is a host path. Inside the sandbox a program is only there
/// through the host mount (`/run/host/usr/bin/steam`) and is named the way the
/// host names it (`/usr/bin/steam`), because that is the path a launch hands to
/// the host.
String? which(String name, {String? searchPath}) {
  if (searchPath != null) return _whichIn(name, searchPath.split(':'));
  return _whichIn(name, Host.binaryDirs);
}

String? _whichIn(String name, Iterable<String> dirs) {
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final candidate = '$dir/$name';
    if (Host.runnable(candidate)) return candidate;
  }
  return null;
}

Set<String>? _flatpakAppIds;

/// Application ids of every installed flatpak app (cached).
Future<Set<String>> flatpakAppIds() async {
  final cached = _flatpakAppIds;
  if (cached != null) return cached;
  if (which('flatpak') == null) return _flatpakAppIds = <String>{};
  final out = await runCapture([
    'flatpak',
    'list',
    '--app',
    '--columns=application',
  ]);
  final ids = out
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toSet();
  return _flatpakAppIds = ids;
}

/// Test seam for [flatpakAppIds].
void setFlatpakAppIdsForTest(Set<String>? ids) => _flatpakAppIds = ids;
