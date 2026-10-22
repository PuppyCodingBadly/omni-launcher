import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../paths.dart';
import 'source.dart';

/// AppImage files found in the configured directories.
class AppImageSource extends GameSource {
  @override
  SourceKind get kind => SourceKind.appimage;

  /// Type-2 AppImage magic (`AI\x02`) at offset 8.
  static const List<int> _magic = [0x41, 0x49, 0x02];
  static const int _magicOffset = 8;
  static const String _suffix = '.appimage';
  static const List<String> _iconExts = ['.png', '.svg', '.jpg'];

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final games = <Game>[];
    final seen = <String>{};
    final iconNames = await _iconNames();
    for (final dir in cfg.appimagePaths(AppPaths.expand)) {
      try {
        if (!await Directory(dir).exists()) continue;
        final entries = await Directory(dir).list().toList();
        entries.sort((a, b) => a.path.compareTo(b.path));
        for (final entry in entries) {
          try {
            if (!await FileSystemEntity.isFile(entry.path)) continue;
          } on FileSystemException {
            continue;
          }
          if (!await _isAppImage(entry.path)) continue;
          final real = await _realPath(entry.path);
          if (!seen.add(real)) continue;
          final parent = _parent(real);
          final stem = _stem(real);
          games.add(
            Game(
              id: 'appimage:$real',
              key: real,
              name: _displayName(stem),
              source: kind,
              command: [real],
              cwd: parent,
              icon: await _icon(stem, parent, iconNames),
              iconIsName: false,
              cover: null,
              path: real,
              subtitle: 'AppImage',
            ),
          );
        }
      } on FileSystemException {
        continue;
      }
    }
    return games;
  }

  /// True when [path] ends with `.appimage` (case-insensitive) or carries the
  /// Type-2 AppImage magic at offset 8.
  ///
  /// Only the magic window (bytes 8-10) is read - extensionless files get a
  /// three-byte probe, not a full read.
  static Future<bool> _isAppImage(String path) async {
    if (path.toLowerCase().endsWith(_suffix)) return true;
    RandomAccessFile? handle;
    try {
      handle = await File(path).open();
      if (await handle.length() < _magicOffset + _magic.length) return false;
      await handle.setPosition(_magicOffset);
      final head = await handle.read(_magic.length);
      if (head.length != _magic.length) return false;
      for (var i = 0; i < _magic.length; i++) {
        if (head[i] != _magic[i]) return false;
      }
      return true;
    } on FileSystemException {
      return false;
    } finally {
      try {
        await handle?.close();
      } on FileSystemException {
        // Ignore: nothing useful to do about a failing close.
      }
    }
  }

  /// `os.path.realpath`: resolves symlinks, tolerating missing targets.
  static Future<String> _realPath(String path) async {
    try {
      return await File(path).resolveSymbolicLinks();
    } on FileSystemException {
      return File(path).absolute.path;
    }
  }

  static String _parent(String path) {
    final index = path.lastIndexOf('/');
    if (index < 0) return '.';
    if (index == 0) return '/';
    return path.substring(0, index);
  }

  static String _baseName(String path) {
    final index = path.lastIndexOf('/');
    return index < 0 ? path : path.substring(index + 1);
  }

  static String _stem(String path) {
    final name = _baseName(path);
    if (name.toLowerCase().endsWith(_suffix)) {
      return name.substring(0, name.length - _suffix.length);
    }
    return name;
  }

  static String _displayName(String stem) {
    final spaced = stem
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .replaceAll('.', ' ');
    return spaced
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .join(' ');
  }

  /// `~/AppImages/.icons`: every file name in it, sorted.
  ///
  /// Listed once per scan rather than once per game - the directory does not
  /// change while a scan runs, and re-reading it for every AppImage turned a
  /// scan of 200 games into 200 full directory listings.
  static Future<List<String>> _iconNames() async {
    final icons = '${AppPaths.home}/AppImages/.icons';
    try {
      final names = await Directory(icons)
          .list()
          .map((entity) => _baseName(entity.path))
          .toList();
      return names..sort();
    } on FileSystemException {
      // Missing/unreadable icon directory: no glob matches.
      return const [];
    }
  }

  /// Index of the first element of [sorted] that is not less than [value].
  static int _lowerBound(List<String> sorted, String value) {
    var low = 0;
    var high = sorted.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (sorted[mid].compareTo(value) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  static Future<String?> _icon(
    String stem,
    String parent,
    List<String> iconNames,
  ) async {
    final icons = '${AppPaths.home}/AppImages/.icons';
    final prefix = '$stem.';
    final candidates = <String>['$icons/$stem'];
    // `sorted(icons.glob(f"{stem}.*"))`: every name with that prefix, and they
    // are contiguous in the sorted listing.
    for (
      var i = _lowerBound(iconNames, prefix);
      i < iconNames.length && iconNames[i].startsWith(prefix);
      i++
    ) {
      candidates.add('$icons/${iconNames[i]}');
    }
    for (final ext in _iconExts) {
      candidates.add('$parent/$stem$ext');
    }
    for (final candidate in candidates) {
      try {
        if (await FileSystemEntity.isFile(candidate)) return candidate;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }
}
