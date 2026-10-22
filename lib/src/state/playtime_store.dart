import 'dart:convert';
import 'dart:io';

import '../paths.dart';

/// Played time for one game.
///
/// A session is `startedAt` … `lastSeenAt`: the launcher writes `startedAt`
/// when it launches a game and refreshes `lastSeenAt` while the process lives.
/// Only observed time is ever counted — if the launcher is killed mid-game the
/// session is closed at the last tick, never at "now", so a crash cannot invent
/// hours of playtime.
class GamePlaytime {
  const GamePlaytime({
    this.totalSeconds = 0,
    this.startedAt,
    this.lastSeenAt,
    this.lastPlayed,
  });

  /// Time from closed sessions, in seconds.
  final int totalSeconds;

  /// Start of the session that is still open, if any.
  final DateTime? startedAt;

  /// Last moment the open session was observed.
  final DateTime? lastSeenAt;

  /// Last moment the game was seen running (or stopped).
  final DateTime? lastPlayed;

  bool get isOpen => startedAt != null;

  /// Closed time plus the observed part of an open session.
  Duration get observed {
    var seconds = totalSeconds;
    final start = startedAt;
    if (start != null) {
      final end = lastSeenAt ?? start;
      if (end.isAfter(start)) seconds += end.difference(start).inSeconds;
    }
    return Duration(seconds: seconds);
  }

  Map<String, Object?> toJson() => {
    'total': totalSeconds,
    if (startedAt != null) 'started': startedAt!.millisecondsSinceEpoch,
    if (lastSeenAt != null) 'seen': lastSeenAt!.millisecondsSinceEpoch,
    if (lastPlayed != null) 'played': lastPlayed!.millisecondsSinceEpoch,
  };

  static GamePlaytime? fromJson(Map<String, Object?> data) {
    final total = _seconds(data['total']);
    return GamePlaytime(
      totalSeconds: total ?? 0,
      startedAt: _time(data['started']),
      lastSeenAt: _time(data['seen']),
      lastPlayed: _time(data['played']),
    );
  }

  static int? _seconds(Object? value) {
    if (value is int) return value < 0 ? 0 : value;
    if (value is num) return value.toInt().clamp(0, 1 << 62);
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed < 0 ? 0 : parsed;
    }
    return null;
  }

  static DateTime? _time(Object? value) {
    final millis = _seconds(value);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }
}

/// Playtime history (`~/.local/state/omnilauncher-flutter/playtime.json`).
class PlaytimeStore {
  PlaytimeStore({String? path}) : _path = path ?? AppPaths.playtimeFile {
    _load();
  }

  final String _path;
  final Map<String, GamePlaytime> _entries = <String, GamePlaytime>{};

  Map<String, GamePlaytime> get entries =>
      Map<String, GamePlaytime>.unmodifiable(_entries);

  /// Total observed playtime for [gameId].
  Duration totalFor(String gameId) =>
      _entries[gameId]?.observed ?? Duration.zero;

  DateTime? lastPlayedFor(String gameId) => _entries[gameId]?.lastPlayed;

  bool isOpen(String gameId) => _entries[gameId]?.isOpen ?? false;

  /// Start a session. A session already open for this game is closed first, so
  /// launching twice cannot double count — folded into the same write, so the
  /// replace costs one save, not two.
  void begin(String gameId, DateTime at) {
    final existing = _entries[gameId];
    var total = existing?.totalSeconds ?? 0;
    final openStart = existing?.startedAt;
    if (openStart != null) {
      // The session being replaced ends at [at], exactly as [end] would
      // close it.
      total += at.isAfter(openStart) ? at.difference(openStart).inSeconds : 0;
    }
    _entries[gameId] = GamePlaytime(
      totalSeconds: total,
      startedAt: at,
      lastSeenAt: at,
      lastPlayed: at,
    );
    _save();
  }

  /// Refresh an open session. Time never moves backwards; a stale or equal
  /// timestamp is ignored without touching the file.
  void touch(String gameId, DateTime at) {
    final entry = _entries[gameId];
    if (entry == null || !entry.isOpen) return;
    final seen = entry.lastSeenAt;
    if (seen != null && !at.isAfter(seen)) return;
    _entries[gameId] = GamePlaytime(
      totalSeconds: entry.totalSeconds,
      startedAt: entry.startedAt,
      lastSeenAt: at,
      lastPlayed: at,
    );
    _save();
  }

  /// Close the open session for [gameId] at [at].
  void end(String gameId, DateTime at) {
    final entry = _entries[gameId];
    final start = entry?.startedAt;
    if (entry == null || start == null) return;
    final seconds = at.isAfter(start) ? at.difference(start).inSeconds : 0;
    _entries[gameId] = GamePlaytime(
      totalSeconds: entry.totalSeconds + seconds,
      lastPlayed: at.isAfter(start) ? at : start,
    );
    _save();
  }

  /// Close sessions that were still open when the launcher stopped, counting
  /// only the time that was actually observed.
  void closeOpenSessions(DateTime now) {
    var changed = false;
    for (final gameId in _entries.keys.toList()) {
      final entry = _entries[gameId]!;
      final start = entry.startedAt;
      if (start == null) continue;
      var end = entry.lastSeenAt ?? start;
      if (end.isAfter(now)) end = now;
      if (end.isBefore(start)) end = start;
      _entries[gameId] = GamePlaytime(
        totalSeconds: entry.totalSeconds + end.difference(start).inSeconds,
        lastPlayed: entry.lastPlayed ?? end,
      );
      changed = true;
    }
    if (changed) _save();
  }

  /// Schema version of the written file. A missing `version` is version 1;
  /// bump only together with a migration in [_load].
  static const int schemaVersion = 1;

  void _load() {
    final file = File(_path);
    if (!file.existsSync()) return;
    Map<String, Object?> decoded;
    try {
      final parsed = jsonDecode(file.readAsStringSync());
      if (parsed is! Map) return;
      decoded = parsed.cast<String, Object?>();
    } on FileSystemException {
      return;
    } on FormatException {
      return;
    }
    for (final entry in decoded.entries) {
      if (entry.key == 'version') continue;
      final value = entry.value;
      if (value is! Map) continue;
      final playtime = GamePlaytime.fromJson(value.cast<String, Object?>());
      if (playtime != null) _entries[entry.key] = playtime;
    }
  }

  void _save() {
    try {
      final file = File(_path);
      file.parent.createSync(recursive: true);
      final payload = <String, Object?>{
        'version': schemaVersion,
        for (final entry in _entries.entries) entry.key: entry.value.toJson(),
      };
      // Through a sibling file and a rename: a crash halfway through writing
      // must not leave a half written history behind.
      final temporary = File('$_path.tmp');
      temporary.writeAsStringSync(jsonEncode(payload));
      temporary.renameSync(_path);
    } on FileSystemException {
      // Playtime is history, never a reason to fail a launch.
    }
  }
}
