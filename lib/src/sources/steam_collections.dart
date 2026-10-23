import 'dart:convert';
import 'dart:io';

/// Steam collection tags, keyed by app id.
///
/// Returns app id (as Steam spells it, e.g. `"440"`) to the names of the Steam
/// collections that app belongs to. An app can be in several collections.
///
/// Collections are read from the cloud storage namespace files Steam keeps per
/// user. Both the array-shaped and the object-shaped namespace files are
/// understood, as are integer and numeric-string app ids. Nothing here throws:
/// a missing, unreadable or malformed file simply contributes no tags.
Future<Map<String, Set<String>>> steamCollectionTags(List<String> roots) async {
  final tags = <String, Set<String>>{};
  for (final root in roots) {
    final userdata = Directory('$root/userdata');
    List<FileSystemEntity> users;
    try {
      if (!await userdata.exists()) continue;
      users = await userdata.list().toList();
    } on FileSystemException {
      continue;
    }
    users.sort((a, b) => a.path.compareTo(b.path));
    for (final user in users) {
      final cloudstorage = Directory('${user.path}/config/cloudstorage');
      List<FileSystemEntity> files;
      try {
        if (!await cloudstorage.exists()) continue;
        files = await cloudstorage.list().toList();
      } on FileSystemException {
        continue;
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in files) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('cloud-storage-namespace-')) continue;
        // Steam leaves modified copies next to the live file; only read the
        // live namespaces so a stale copy cannot resurrect an old collection.
        if (name.endsWith('.modified.json')) continue;
        if (!name.endsWith('.json')) continue;
        await _addFileTags(entity, tags);
      }
    }
  }
  return tags;
}

/// Read one namespace file and merge its collections into [tags].
Future<void> _addFileTags(File file, Map<String, Set<String>> tags) async {
  String text;
  try {
    text = await file.readAsString();
  } on FileSystemException {
    return;
  } on FormatException {
    return;
  }
  Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return;
  }
  for (final entry in _namespaceEntries(json)) {
    final key = entry.key;
    if (!key.startsWith('user-collections.')) continue;
    final record = entry.value;
    if (record is! Map) continue;
    if (_isDeleted(record['is_deleted'])) continue;
    final collection = _collection(record['value']);
    if (collection == null) continue;
    final id = collection['id'];
    if (id is String && (id == 'hidden' || id == 'favorite')) continue;
    final name = collection['name'];
    if (name is! String || name.trim().isEmpty) continue;
    final removed = _ids(collection['removed']);
    for (final appId in _ids(collection['added'])) {
      if (removed.contains(appId)) continue;
      tags.putIfAbsent(appId, () => <String>{}).add(name);
    }
  }
}

/// Normalise the two namespace shapes into key/entry pairs.
Iterable<MapEntry<String, Object?>> _namespaceEntries(Object? json) sync* {
  if (json is Map) {
    for (final entry in json.entries) {
      final key = entry.key;
      if (key is String) yield MapEntry(key, entry.value);
    }
    return;
  }
  if (json is List) {
    for (final item in json) {
      if (item is! List || item.length < 2) continue;
      final key = item[0];
      if (key is! String) continue;
      yield MapEntry(key, item[1]);
    }
  }
}

/// Steam stores the collection payload either as a JSON string or inline.
Map<Object?, Object?>? _collection(Object? value) {
  Object? decoded = value;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      return null;
    }
  }
  return decoded is Map ? decoded : null;
}

/// App ids as strings; Steam writes them as ints or numeric strings.
Set<String> _ids(Object? value) {
  final ids = <String>{};
  if (value is! List) return ids;
  for (final item in value) {
    if (item is int) {
      ids.add('$item');
    } else if (item is String && item.trim().isNotEmpty) {
      ids.add(item.trim());
    }
  }
  return ids;
}

bool _isDeleted(Object? value) =>
    value == true || value == 1 || value == 'true';
