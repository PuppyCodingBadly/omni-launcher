import 'dart:convert';
import 'dart:io';

/// Read and decode a JSON file, or `null` when missing/unreadable/invalid.
Future<Object?> loadJson(String path) async {
  try {
    return jsonDecode(await File(path).readAsString());
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Every `*.desktop` file in [dirs], first directory wins per file name.
///
/// Directories that cannot be listed are skipped, matching the Python
/// original (`glob` swallows the `OSError`).
Future<List<File>> iterDesktopFiles(Iterable<String> dirs) async {
  final seen = <String>{};
  final result = <File>[];
  for (final dir in dirs) {
    final directory = Directory(dir);
    bool isDir;
    try {
      isDir = await directory.exists();
    } on FileSystemException {
      continue;
    }
    if (!isDir) continue;
    List<FileSystemEntity> listed;
    try {
      listed = await directory.list().toList();
    } on FileSystemException {
      continue;
    }
    final entries = listed.whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in entries) {
      final name = file.uri.pathSegments.last;
      if (!name.endsWith('.desktop') || !seen.add(name)) continue;
      result.add(file);
    }
  }
  return result;
}

/// Parse the `[Desktop Entry]` group of a .desktop file.
///
/// Bytes that are not valid UTF-8 are replaced rather than dropping the whole
/// entry, matching the Python original's `errors="replace"`.
Future<Map<String, String>> readDesktopFile(String path) async {
  String text;
  try {
    text = utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
  } on FileSystemException {
    return <String, String>{};
  }
  return parseDesktopEntry(text);
}

/// Parse the `[Desktop Entry]` group out of desktop file contents.
Map<String, String> parseDesktopEntry(String text) {
  final entry = <String, String>{};
  String section = '';
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.substring(1, line.length - 1);
      continue;
    }
    if (section != 'Desktop Entry') continue;
    final index = line.indexOf('=');
    if (index < 0) continue;
    final key = line.substring(0, index).trim();
    // Skip localised keys such as Name[de]; the plain key wins.
    if (key.contains('[')) continue;
    entry[key] = line.substring(index + 1).trim();
  }
  return entry;
}

/// Write [text] to [path], creating parent directories.
Future<void> writeTextFile(String path, String text) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(text);
}
