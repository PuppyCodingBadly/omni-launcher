import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../paths.dart';

/// A Steam non-Steam shortcut, as stored in `userdata/<id>/config/shortcuts.vdf`.
class SteamShortcut {
  const SteamShortcut({
    required this.appId,
    required this.name,
    this.exe,
    this.startDir,
    this.launchOptions,
    this.flatpakAppId,
    this.hidden = false,
  });

  /// Unsigned 32-bit app id — exactly what `steam -applaunch` expects.
  final int appId;

  final String name;
  final String? exe;
  final String? startDir;
  final String? launchOptions;

  /// Set when the shortcut was created for a flatpak app.
  final String? flatpakAppId;

  final bool hidden;

  bool matchesFlatpak(String key) =>
      flatpakAppId != null && flatpakAppId!.isNotEmpty && flatpakAppId == key;

  bool matchesName(String other) =>
      name.trim().toLowerCase() == other.trim().toLowerCase();
}

/// Steam roots to scan, in order.
List<String> defaultSteamRoots() => [
  '${AppPaths.home}/.local/share/Steam',
  '${AppPaths.home}/.steam/steam',
];

/// Every shortcut in every Steam userdata directory.
///
/// The two default roots usually point at the same directory through a symlink,
/// so files are de-duplicated by their resolved path. Nothing here throws: a
/// missing, unreadable or half-written file simply yields no shortcuts.
List<SteamShortcut> readSteamShortcuts({List<String>? roots}) {
  final seen = <String>{};
  final shortcuts = <SteamShortcut>[];
  for (final root in roots ?? defaultSteamRoots()) {
    final userdata = Directory('$root/userdata');
    if (!userdata.existsSync()) continue;
    List<FileSystemEntity> users;
    try {
      users = userdata.listSync()..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      continue;
    }
    for (final user in users) {
      final file = File('${user.path}/config/shortcuts.vdf');
      if (!file.existsSync()) continue;
      String identity;
      try {
        identity = file.resolveSymbolicLinksSync();
      } on FileSystemException {
        identity = file.path;
      }
      if (!seen.add(identity)) continue;
      shortcuts.addAll(_readShortcutsFile(file));
    }
  }
  return shortcuts;
}

List<SteamShortcut> _readShortcutsFile(File file) {
  Uint8List bytes;
  try {
    bytes = file.readAsBytesSync();
  } on FileSystemException {
    return const [];
  }
  final root = parseBinaryVdf(bytes);
  final entries = root['shortcuts'];
  if (entries is! Map) return const [];
  final shortcuts = <SteamShortcut>[];
  for (final entry in entries.values) {
    if (entry is! Map) continue;
    final appId = entry['appid'];
    if (appId is! int) continue;
    final name =
        _text(entry['appname']) ?? _text(entry['AppName']) ?? _text(entry['name']);
    if (name == null || name.trim().isEmpty) continue;
    shortcuts.add(
      SteamShortcut(
        // Steam stores the id as a signed 32-bit int; -applaunch wants it unsigned.
        appId: appId & 0xFFFFFFFF,
        name: name,
        exe: _text(entry['exe']) ?? _text(entry['Exe']),
        startDir: _text(entry['StartDir']),
        launchOptions: _text(entry['LaunchOptions']),
        flatpakAppId: _text(entry['FlatpakAppID']) ?? _text(entry['FlatpakAppId']),
        hidden: _isTrue(entry['IsHidden']),
      ),
    );
  }
  return shortcuts;
}

String? _text(Object? value) {
  if (value is String) return value;
  if (value is int) return '$value';
  return null;
}

bool _isTrue(Object? value) => value is int ? value != 0 : value == true;

/// Valve's binary KeyValues, the format of `shortcuts.vdf`.
///
/// A tolerant reader: the types Steam uses for shortcuts are decoded, anything
/// else stops the walk and returns what was read so far, so a file from a newer
/// Steam cannot make the launcher throw.
Map<String, Object?> parseBinaryVdf(List<int> bytes) {
  var index = 0;

  String? readString() {
    final start = index;
    while (index < bytes.length && bytes[index] != 0) {
      index++;
    }
    if (index >= bytes.length) {
      index = bytes.length;
      return null;
    }
    final value = utf8.decode(bytes.sublist(start, index), allowMalformed: true);
    index++; // skip the NUL terminator
    return value;
  }

  int? readInt(int size) {
    if (index + size > bytes.length) {
      index = bytes.length;
      return null;
    }
    var value = 0;
    for (var i = size - 1; i >= 0; i--) {
      value = (value << 8) | (bytes[index + i] & 0xFF);
    }
    index += size;
    return value;
  }

  Map<String, Object?> readObject() {
    final result = <String, Object?>{};
    while (index < bytes.length) {
      final type = bytes[index++];
      if (type == 0x08) return result; // end of object
      final key = readString();
      if (key == null) return result;
      switch (type) {
        case 0x00:
          result[key] = readObject();
        case 0x01:
          final value = readString();
          if (value == null) return result;
          result[key] = value;
        case 0x02:
          final value = readInt(4);
          if (value == null) return result;
          result[key] = value;
        case 0x03: // float
        case 0x04: // pointer
        case 0x06: // colour
          if (readInt(4) == null) return result;
        case 0x07: // uint64
        case 0x0A: // int64
          final value = readInt(8);
          if (value == null) return result;
          result[key] = value;
        default:
          return result;
      }
    }
    return result;
  }

  return readObject();
}
