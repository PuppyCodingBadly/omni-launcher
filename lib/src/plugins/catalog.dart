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
    required this.sha256,
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

  /// The archive's SHA-256 as the catalogue states it; an install refuses an
  /// archive whose checksum is anything else.
  final String sha256;

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
    final sha256 = _text(json['sha256']);
    if (id == null || name == null || file == null || sha256 == null) {
      return null;
    }
    if (!_idPattern.hasMatch(id)) return null;
    if (!_sha256Pattern.hasMatch(sha256)) return null;
    final version = json['version'];
    return PluginEntry(
      id: id,
      name: name,
      description: _text(json['description']) ?? '',
      author: _text(json['author']) ?? '',
      version: version is int && version > 0 ? version : 0,
      url: index.resolve(file),
      sha256: sha256.toLowerCase(),
    );
  }

  static final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]*$');

  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

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
  final sum = await _sha256Of(bytes);
  if (sum != entry.sha256) {
    throw PluginStoreException(
      'the archive\'s checksum is $sum, not the catalogue\'s ${entry.sha256}',
    );
  }
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

/// How many redirects [readUrl] follows before it stops believing.
const int _maxRedirects = 5;

/// Fetch [url] over the network, refusing anything larger than [limit].
///
/// Only https is fetched — a catalogue or an archive over plain http could be
/// rewritten by anyone on the path — with the loopback addresses a test
/// serves on as the one exception. Redirects are followed by hand, so a hop
/// to plain http is refused like any other plain http address.
Future<Uint8List> readUrl(Uri url, {required int limit}) async {
  final client = HttpClient()..connectionTimeout = _timeout;
  try {
    var target = url;
    late HttpClientResponse response;
    for (var redirects = 0;; redirects++) {
      _refusePlainHttp(target);
      final request = await client.getUrl(target);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final current = await request.close();
      if (!_isRedirect(current.statusCode)) {
        response = current;
        break;
      }
      final location = current.headers.value(HttpHeaders.locationHeader);
      await current.drain<void>();
      if (location == null || redirects >= _maxRedirects) {
        throw PluginStoreException('$url will not stop redirecting');
      }
      target = target.resolve(location);
    }
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

/// Complain when [url] is plain http anywhere but the machine itself.
void _refusePlainHttp(Uri url) {
  if (url.scheme == 'https') return;
  if (url.scheme == 'http' &&
      (url.host == 'localhost' || url.host == '127.0.0.1' || url.host == '::1')) {
    return;
  }
  throw PluginStoreException('$url is not an https address');
}

bool _isRedirect(int status) =>
    status == HttpStatus.movedPermanently ||
    status == HttpStatus.found ||
    status == HttpStatus.seeOther ||
    status == HttpStatus.temporaryRedirect ||
    status == HttpStatus.permanentRedirect;

/// The SHA-256 of [bytes] as hex, by `sha256sum`: the app carries no crypto
/// package, and coreutils is as boring a dependency as there is.
Future<String> _sha256Of(List<int> bytes) async {
  final folder = await Directory.systemTemp.createTemp('omni-sum');
  try {
    final file = File('${folder.path}/archive.zip');
    await file.writeAsBytes(bytes, flush: true);
    final result = await Process.run('sha256sum', [file.path]);
    if (result.exitCode != 0) {
      throw PluginStoreException('sha256sum would not read the archive');
    }
    return '${result.stdout}'.split(RegExp(r'\s+')).first;
  } on ProcessException {
    throw const PluginStoreException('sha256sum is not on this machine');
  } finally {
    _delete(folder.path);
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
