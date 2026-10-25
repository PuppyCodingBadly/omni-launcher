import 'dart:convert';
import 'dart:io';

import '../host.dart';

/// Where Steam records the apps it is running, and for which app.
///
/// `steam -applaunch` hands the game to the client and exits at once, so the
/// pid the launcher started says nothing about the game a second later.
/// Steam's own `gameprocess_log.txt` does: it records every pid it tracks for
/// the app and, when the game is over, that the app left the running list.
class SteamHandoff {
  const SteamHandoff({required this.appId, required this.path});

  /// The app id Steam was asked to start.
  final String appId;

  /// The client's `gameprocess_log.txt`.
  final String path;

  /// Test seam: the home [find] reads when a test cannot hand one in.
  static String? homeOverrideForTest;

  /// The hand-off [command] asks Steam for, or null when it is not one.
  ///
  /// Steam's own client and the flatpak keep their logs in different homes;
  /// only one of them launched the game, and the command says which.
  static SteamHandoff? find(List<String> command, {String? home}) {
    final index = command.indexOf('-applaunch');
    if (index < 0 || index + 1 >= command.length) return null;
    final appId = command[index + 1];
    if (appId.isEmpty) return null;
    final base = home ?? homeOverrideForTest ?? Host.home;
    final program = command.first;
    final flatpak = program == 'flatpak' || program.endsWith('/flatpak');
    final logs = flatpak
        ? '$base/.var/app/com.valvesoftware.Steam/.local/share/Steam/logs'
        : '$base/.steam/steam/logs';
    return SteamHandoff(appId: appId, path: '$logs/gameprocess_log.txt');
  }
}

/// What Steam's log says about the game right now.
enum SteamGameState {
  /// The launcher asked for the game, but Steam has not reported a process
  /// for it yet.
  starting,

  /// Steam has a process for the app.
  running,

  /// Steam reported the app leaving its running list: the game is over.
  ended,
}

/// A follow of [SteamHandoff.path] for one app.
///
/// Only what Steam writes after [SteamGameLog.start]'s baseline is about this
/// launch; the log's tail before it is read once to tell whether the game was
/// already running (a second click on a running game asks Steam to focus it,
/// not to start it again).
class SteamGameLog {
  SteamGameLog({
    required this.appId,
    required this.path,
    DateTime Function()? now,
    this.tailBytes = 256 * 1024,
  }) : _now = now ?? DateTime.now {
    _baseline = _length();
  }

  final String appId;
  final String path;

  /// How much of the log's end is read to tell whether the game was already
  /// running. A log the client has written for months is megabytes long; the
  /// last few thousand lines always hold the app's last transition.
  final int tailBytes;

  final DateTime Function() _now;

  /// The log's size when the launcher asked Steam to start the game.
  late int _baseline;

  /// Where the next read starts.
  int _offset = 0;

  /// An incomplete line left over from the previous read.
  String _carry = '';

  SteamGameState _state = SteamGameState.starting;

  /// Whether the tail's last transition for the app was an add.
  bool _seedRunning = false;

  /// The pids Steam reported for the app, newest launch only: a remove
  /// clears them so a Stop signals the game that is running, not the last one.
  final Set<int> pids = <int>{};

  /// When Steam reported the game over, from the log's own clock.
  DateTime? endedAt;

  SteamGameState get state => _state;

  /// Read the log from the launch point and fold in what it says so far.
  ///
  /// Called once the hand-off launcher has exited: by then Steam may have
  /// recorded the game already, or may still be starting it.
  void start() {
    if (_baseline == 0) {
      // Steam had not written a log when the launch was made; everything in
      // it now belongs to this session too.
      _baseline = _length();
    }
    _offset = _baseline;
    _seedFromTail();
    _readForward();
  }

  /// Fold in whatever Steam wrote since the last call.
  void poll() => _readForward();

  /// The app's last state before the baseline, and its pids, from the log's
  /// tail.
  void _seedFromTail() {
    final length = _length();
    if (length == 0) return;
    final end = _baseline < length ? _baseline : length;
    final start = end > tailBytes ? end - tailBytes : 0;
    final text = _readRange(start, end);
    if (start > 0) {
      // The first line is cut by the window; Steam did not write it whole.
      final newline = text.indexOf('\n');
      if (newline < 0) return;
      _apply(text.substring(newline + 1));
    } else {
      _apply(text);
    }
    // The tail describes what was already happening. What it says about the
    // game's end is not this launch's end: our game may still be starting.
    endedAt = null;
    _state = _seedRunning ? SteamGameState.running : SteamGameState.starting;
  }

  /// Read from [_offset] to the end, keeping a partial line for next time.
  void _readForward() {
    final length = _length();
    if (length < _offset) {
      // Steam rotates the log when it restarts, which also ends any game it
      // was running.
      _offset = length;
      _carry = '';
      _state = SteamGameState.ended;
      endedAt ??= _now();
      return;
    }
    if (length == _offset) return;
    final text = _readRange(_offset, length);
    _offset = length;
    _apply(_carry + text);
  }

  /// Fold every whole line in [text] in, keeping the last piece: Steam may be
  /// part way through writing it.
  void _apply(String text) {
    final pieces = text.split('\n');
    _carry = pieces.removeLast();
    for (final line in pieces) {
      _applyLine(line);
    }
  }

  void _applyLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    final add = _addLine.firstMatch(trimmed);
    if (add != null && add.group(2) == appId) {
      pids.add(int.parse(add.group(3)!));
      _state = SteamGameState.running;
      _seedRunning = true;
      return;
    }
    final remove = _removeLine.firstMatch(trimmed);
    if (remove != null && remove.group(2) == appId) {
      pids.clear();
      _state = SteamGameState.ended;
      _seedRunning = false;
      endedAt = _time(remove.group(1)!);
    }
  }

  static final RegExp _addLine = RegExp(
    r'^\[([^\]]+)\]\s+AppID\s+(\S+)\s+adding PID\s+(\d+)\s+as a tracked process',
  );

  static final RegExp _removeLine = RegExp(
    r'^\[([^\]]+)\]\s+Remove\s+(\S+)\s+from running list',
  );

  static DateTime? _time(String text) => DateTime.tryParse(text);

  int _length() {
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  String _readRange(int start, int end) {
    if (end <= start) return '';
    RandomAccessFile? handle;
    try {
      handle = File(path).openSync();
      handle.setPositionSync(start);
      return utf8.decode(handle.readSync(end - start), allowMalformed: true);
    } on FileSystemException {
      return '';
    } finally {
      handle?.closeSync();
    }
  }
}
