import 'dart:convert';
import 'dart:io';

import '../paths.dart';
import '../plugins/plugin.dart';

/// What the plugins said, per plugin and game
/// (`~/.cache/omnilauncher-flutter/plugin_answers.json`).
///
/// A lookup costs a round trip to somebody else's site, so the answer is kept:
/// selecting the game again shows it without asking again, and the panel's cog
/// asks again when a fresh answer is wanted.
class PluginStore {
  PluginStore({String? path}) : _path = path ?? AppPaths.pluginAnswerFile {
    _load();
  }

  final String _path;
  final Map<String, PluginAnswer> _entries = <String, PluginAnswer>{};

  PluginAnswer? answer(String pluginId, String gameId) =>
      _entries[keyFor(pluginId, gameId)];

  void put(String pluginId, String gameId, PluginAnswer answer) {
    _entries[keyFor(pluginId, gameId)] = answer;
    _save();
  }

  /// The key a plugin and a query share. A plugin id cannot contain a slash, so
  /// one key cannot be read as another.
  static String keyFor(String pluginId, String queryId) => '$pluginId/$queryId';

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
      final answer = PluginAnswer.fromJson(entry.value);
      if (answer != null) _entries[entry.key] = answer;
    }
  }

  void _save() {
    try {
      final file = File(_path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          for (final entry in _entries.entries) entry.key: entry.value.toJson(),
        }),
      );
    } on FileSystemException {
      // The answers are a shortcut, never a reason to fail a lookup.
    }
  }
}
