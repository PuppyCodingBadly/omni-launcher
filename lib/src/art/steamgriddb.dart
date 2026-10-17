import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// SteamGridDB API client (v2).
///
/// Only the endpoints needed for cover art are used: game autocomplete,
/// grids by Steam app id and grids by SteamGridDB game id. The API key is
/// user supplied (SteamGridDB → Preferences → API), because the API has no
/// anonymous tier.
class SteamGridDb {
  SteamGridDb({
    required this.apiKey,
    HttpClient? client,
    this.baseUrl = defaultBaseUrl,
    this.userAgent = 'OmniLauncher/1.0',
  }) : _client = client ?? HttpClient()..connectionTimeout = const Duration(seconds: 10);

  static const String defaultBaseUrl = 'https://www.steamgriddb.com/api/v2';

  /// API root; overridable so the client can be pointed at a local server.
  final String baseUrl;

  /// Portrait-first grid shapes, Cartridges style.
  static const String defaultDimensions = '600x900,342x482,660x930,460x215';

  final String apiKey;
  final String userAgent;
  final HttpClient _client;

  /// SteamGridDB rate limits per key; keep a polite gap between calls.
  static const Duration _minGap = Duration(milliseconds: 250);

  /// How many redirects a request follows before it stops believing.
  static const int _maxRedirects = 5;

  /// The most a downloaded image may weigh.
  static const int _maxImageBytes = 16 * 1024 * 1024;

  /// The longest an image body may take; the connection timeout only covers
  /// the handshake, not a server that drips bytes forever.
  static const Duration _bodyTimeout = Duration(seconds: 30);
  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  /// Tail of the queue of requests that are still waiting for their turn.
  Future<void> _turn = Future<void>.value();

  bool get configured => apiKey.trim().isNotEmpty;

  /// Games matching [term], best match first.
  Future<List<SgdbGame>> searchGames(String term) async {
    final data = await _get('/search/autocomplete/${Uri.encodeComponent(term)}');
    return data
        .whereType<Map>()
        .map((entry) => SgdbGame.fromJson(entry.cast<String, Object?>()))
        .whereType<SgdbGame>()
        .toList();
  }

  /// Grids for a Steam app id (no name matching needed).
  Future<List<SgdbGrid>> gridsForSteamApp(int appId) => _grids('/grids/steam/$appId');

  /// Grids for a SteamGridDB game id.
  Future<List<SgdbGrid>> gridsForGame(int gameId) => _grids('/grids/game/$gameId');

  /// Grids for a game found by name; empty when nothing matches.
  Future<List<SgdbGrid>> gridsForName(String name) async {
    final matches = await searchGames(name);
    if (matches.isEmpty) return const [];
    return gridsForGame(matches.first.id);
  }

  /// Download [grid] to [targetPath]; returns the path on success.
  Future<String?> downloadGrid(SgdbGrid grid, String targetPath) async {
    final target = File(targetPath);
    if (target.existsSync()) return target.path;
    try {
      final bytes = await _fetchBytes(grid.url);
      if (bytes.isEmpty) return null;
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(bytes);
      return target.path;
    } on IOException {
      return null;
    } on SteamGridDbException {
      return null;
    }
  }

  /// Cheap way to validate a key: a search that must return a game list.
  Future<int> testKey() async {
    final games = await searchGames('portal');
    return games.length;
  }

  Future<List<SgdbGrid>> _grids(String path) async {
    final data = await _get(
      '$path?dimensions=$defaultDimensions&types=static&nsfw=false&humor=false',
    );
    return data
        .whereType<Map>()
        .map((entry) => SgdbGrid.fromJson(entry.cast<String, Object?>()))
        .whereType<SgdbGrid>()
        .toList();
  }

  Future<List<Object?>> _get(String path) async {
    if (!configured) {
      throw const SteamGridDbException('No SteamGridDB API key set.');
    }
    final response = await _request(Uri.parse('$baseUrl$path'));
    if (response.statusCode == 401 || response.statusCode == 403) {
      await response.drain<void>();
      throw const SteamGridDbException('SteamGridDB rejected the API key.');
    }
    if (response.statusCode == 404) {
      await response.drain<void>();
      return const [];
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw SteamGridDbException('SteamGridDB returned HTTP ${response.statusCode}.');
    }
    final body = await _readString(response);
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const SteamGridDbException('SteamGridDB sent an unreadable response.');
    }
    if (decoded is! Map || decoded['success'] != true) {
      throw const SteamGridDbException('SteamGridDB reported a failure.');
    }
    final data = decoded['data'];
    return data is List ? data.cast<Object?>() : const [];
  }

  /// Wait for this request's turn, so the gap between request *starts* holds
  /// even when several tiles ask for art at the same time.
  ///
  /// Without the queue every caller measures the same gap against the last
  /// request, waits the same amount and then fires together, which is exactly
  /// the burst the rate limit punishes.
  Future<void> _waitForTurn() async {
    final previous = _turn;
    final turn = Completer<void>();
    _turn = turn.future;
    await previous;
    try {
      final gap = DateTime.now().difference(_lastRequest);
      if (gap < _minGap) await Future<void>.delayed(_minGap - gap);
      _lastRequest = DateTime.now();
    } finally {
      turn.complete();
    }
  }

  /// [authenticate] is off for the CDN: the key authenticates the API, and the
  /// image host neither needs nor asks for it.
  ///
  /// Redirects are re-issued by hand, and the key only rides along when the
  /// redirect leads back to SteamGridDB itself: anywhere else gets a plain
  /// request, so a redirect cannot talk the client into leaking the key.
  Future<HttpClientResponse> _request(Uri uri, {bool authenticate = true}) async {
    await _waitForTurn();
    var target = uri;
    var sendKey = authenticate;
    for (var redirects = 0;; redirects++) {
      final HttpClientResponse response;
      try {
        final request = await _client.getUrl(target);
        // Redirects are re-issued by hand: the key must not ride along to a
        // host that is not SteamGridDB.
        request.followRedirects = false;
        if (sendKey) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${apiKey.trim()}');
        }
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        response = await request.close();
      } on IOException catch (error) {
        // A host that cannot be reached has to look like every other failure, or
        // it walks past the callers that only handle SteamGridDbException.
        throw _unreachable(error);
      }
      if (!_isRedirect(response.statusCode)) return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null || redirects >= _maxRedirects) {
        throw const SteamGridDbException('SteamGridDB will not stop redirecting.');
      }
      target = target.resolve(location);
      sendKey = target.host == 'www.steamgriddb.com';
    }
  }

  static bool _isRedirect(int status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == HttpStatus.permanentRedirect;

  static SteamGridDbException _unreachable(IOException error) =>
      SteamGridDbException('SteamGridDB is unreachable: $error');

  /// The response body; a connection that dies halfway through reads as a
  /// failure of the request, not as a socket error. [limit] refuses a body
  /// that grows past it.
  Future<List<int>> _body(HttpClientResponse response, {int? limit}) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in response) {
        builder.add(chunk);
        if (limit != null && builder.length > limit) {
          throw SteamGridDbException(
            'SteamGridDB sent more than ${limit ~/ (1024 * 1024)} MiB.',
          );
        }
      }
    } on IOException catch (error) {
      throw _unreachable(error);
    }
    return builder.takeBytes();
  }

  Future<List<int>> _fetchBytes(String url) async {
    final response = await _request(Uri.parse(url), authenticate: false);
    if (response.statusCode != 200) {
      await response.drain<void>();
      return const [];
    }
    try {
      return await _body(response, limit: _maxImageBytes).timeout(_bodyTimeout);
    } on TimeoutException {
      throw const SteamGridDbException(
        'SteamGridDB took too long to send an image.',
      );
    }
  }

  Future<String> _readString(HttpClientResponse response) async =>
      utf8.decode(await _body(response), allowMalformed: true);

  void close() => _client.close(force: true);
}

class SteamGridDbException implements Exception {
  const SteamGridDbException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One game as SteamGridDB knows it.
class SgdbGame {
  const SgdbGame({required this.id, required this.name});

  final int id;
  final String name;

  static SgdbGame? fromJson(Map<String, Object?> data) {
    final id = data['id'];
    final name = data['name'];
    if (id is! int || name is! String) return null;
    return SgdbGame(id: id, name: name);
  }
}

/// One artwork candidate.
class SgdbGrid {
  const SgdbGrid({
    required this.id,
    required this.url,
    required this.thumb,
    this.width,
    this.height,
    this.style,
    this.mime,
    this.author,
  });

  final int id;
  final String url;
  final String thumb;
  final int? width;
  final int? height;
  final String? style;
  final String? mime;
  final String? author;

  /// File extension to store the download under.
  String get extension {
    final mime = this.mime;
    if (mime == 'image/png') return '.png';
    if (mime == 'image/jpeg') return '.jpg';
    final dot = url.lastIndexOf('.');
    if (dot > 0) {
      final suffix = url.substring(dot).toLowerCase();
      if (suffix == '.png' || suffix == '.jpg' || suffix == '.jpeg') return suffix;
    }
    return '.jpg';
  }

  static SgdbGrid? fromJson(Map<String, Object?> data) {
    final id = data['id'];
    final url = data['url'];
    if (id is! int || url is! String || url.isEmpty) return null;
    final thumb = data['thumb'];
    return SgdbGrid(
      id: id,
      url: url,
      thumb: thumb is String && thumb.isNotEmpty ? thumb : url,
      width: data['width'] is int ? data['width'] as int : null,
      height: data['height'] is int ? data['height'] as int : null,
      style: data['style'] as String?,
      mime: data['mime'] as String?,
      author: data['author'] is Map ? (data['author'] as Map)['name'] as String? : null,
    );
  }
}
