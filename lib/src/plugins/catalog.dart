import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'plugin.dart';
import 'zip.dart';

/// Where the plugin catalogue lives.
///
/// A file in the launcher's own repository, served straight from the branch
/// that carries it: the list and the archives it points at are then always from
/// the same commit, and a plugin is published by adding it to that branch.
const String pluginIndexUrl =
    'https://raw.githubusercontent.com/PuppyCodingBadly/omni-launcher/main/plugins/index.json';

const String _userAgent = 'OmniLauncher/1.0';
const Duration _timeout = Duration(seconds: 20);
const int _indexLimit = 256 * 1024;

/// One plugin the store offers.
class PluginEntry {
  const PluginEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.author,
    required this.version,
    required this.url,
  });

  final String id;
  final String name;

  /// One line about what it does; may be empty.
  final String description;

  /// Who wrote it; may be empty.
  final String author;

  /// What the catalogue says the plugin's version is, to compare with the
  /// installed one.
  final int version;

  /// The plugin's archive.
  final Uri url;

  /// The entries in a catalogue, with [index] resolving the archives' names.
  ///
  /// An entry that does not make sense is left out rather than half used.
  static List<PluginEntry> listFromJson(Object? json, Uri index) {
    final plugins = json is Map ? json['plugins'] : null;
    if (plugins is! List) {
      throw const PluginStoreException('the plugin list holds no plugins');
    }
    final entries = <PluginEntry>[];
    for (final raw in plugins) {
      final entry = fromJson(raw, index);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  static PluginEntry? fromJson(Object? json, Uri index) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    final name = _text(json['name']);
    final file = _text(json['file']);
    if (id == null || name == null || file == null) return null;
    if (!_idPattern.hasMatch(id)) return null;
    final version = json['version'];
    return PluginEntry(
      id: id,
      name: name,
      description: _text(json['description']) ?? '',
      author: _text(json['author']) ?? '',
      version: version is int && version > 0 ? version : 0,
      url: index.resolve(file),
    );
  }

  static final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]*$');

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Why the catalogue could not be read, or a plugin could not be installed.
class PluginStoreException implements Exception {
  const PluginStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fetches a URL, refusing anything larger than the limit.
///
/// The app's own reader is [readUrl]; a test can hand in one that answers from
/// memory, so nothing in a widget test waits on a socket.
typedef UrlReader = Future<Uint8List> Function(Uri url, {required int limit});

/// Read the catalogue at [index] ([pluginIndexUrl] by default).
Future<List<PluginEntry>> fetchCatalog({Uri? index, UrlReader? read}) async {
  final url = index ?? Uri.parse(pluginIndexUrl);
  final body = await (read ?? readUrl)(url, limit: _indexLimit);
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
  } on FormatException catch (error) {
    throw PluginStoreException('the plugin list is not JSON: ${error.message}');
  }
  return PluginEntry.listFromJson(decoded, url);
}

/// Download [entry]'s archive and unpack it into `<dir>/<id>`.
///
/// The archive is unpacked into a staging folder first and only then put in
/// place, so an install that turns out to be rubbish leaves the plugin that was
/// already there alone.
Future<void> installPlugin(
  PluginEntry entry, {
  required String dir,
  UrlReader? read,
}) async {
  if (!PluginEntry._idPattern.hasMatch(entry.id)) {
    throw PluginStoreException('${entry.id} is not a plugin id');
  }
  final bytes = await (read ?? readUrl)(entry.url, limit: maxArchiveBytes);
  final folder = '$dir/${entry.id}';
  final staging = '$dir/.${entry.id}.new';
  _delete(staging);
  try {
    unpackZip(bytes, staging);
    final manifest = File('$staging/plugin.json');
    if (!manifest.existsSync()) {
      throw const PluginStoreException(
        'the archive holds no plugin.json at its top level',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(manifest.readAsStringSync());
    } on FormatException catch (error) {
      throw PluginStoreException('the plugin\'s manifest is not JSON: ${error.message}');
    }
    final plugin = Plugin.fromManifest(staging, json);
    if (plugin == null) {
      throw const PluginStoreException('the plugin\'s manifest does not describe a plugin');
    }
    if (plugin.id != entry.id) {
      throw PluginStoreException(
        'the archive holds ${plugin.id}, not ${entry.id}',
      );
    }
    // The plugin that is already there is only taken away once the new one is
    // in its place, so a rename that goes wrong cannot lose it.
    final backup = '$dir/.${entry.id}.old';
    _delete(backup);
    if (Directory(folder).existsSync()) Directory(folder).renameSync(backup);
    try {
      Directory(staging).renameSync(folder);
    } catch (_) {
      if (Directory(backup).existsSync()) Directory(backup).renameSync(folder);
      rethrow;
    }
    _delete(backup);
  } catch (_) {
    _delete(staging);
    rethrow;
  }
}

/// Remove the plugin in `<dir>/<id>`.
Future<void> removePlugin(String id, {required String dir}) async {
  if (!PluginEntry._idPattern.hasMatch(id)) {
    throw PluginStoreException('$id is not a plugin id');
  }
  _delete('$dir/$id');
}

/// Fetch [url] over the network, refusing anything larger than [limit].
Future<Uint8List> readUrl(Uri url, {required int limit}) async {
  final client = HttpClient()..connectionTimeout = _timeout;
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw PluginStoreException('$url answered ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > limit) {
        throw PluginStoreException('$url sent more than ${limit ~/ 1024} KiB');
      }
    }
    return builder.takeBytes();
  } on SocketException catch (error) {
    throw PluginStoreException('could not reach $url: ${error.message}');
  } on HttpException catch (error) {
    throw PluginStoreException('$url: ${error.message}');
  } on TimeoutException {
    throw PluginStoreException('$url took too long to answer');
  } finally {
    client.close(force: true);
  }
}

/// Delete [path] whether it is a file or a folder, and say nothing when it is
/// not there.
void _delete(String path) {
  final entity = FileSystemEntity.typeSync(path, followLinks: false);
  if (entity == FileSystemEntityType.directory) {
    Directory(path).deleteSync(recursive: true);
  } else if (entity != FileSystemEntityType.notFound) {
    File(path).deleteSync();
  }
}
