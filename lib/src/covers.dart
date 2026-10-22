import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'art/steamgriddb.dart';
import 'config.dart';
import 'host.dart';
import 'model/game.dart';
import 'paths.dart';

/// What a tile should draw.
enum ArtworkKind { cover, icon, letter }

class Artwork {
  const Artwork(
    this.kind, {
    this.value,
    this.isName = false,
    this.pending = false,
  });

  final ArtworkKind kind;

  /// File path, or an icon theme name when [isName] is set.
  final String? value;
  final bool isName;

  /// True when artwork could still be fetched (Steam CDN or SteamGridDB).
  final bool pending;
}

/// The artwork-related slice of the user configuration.
class ArtSettings {
  const ArtSettings({
    this.steamCovers = true,
    this.sgdbKey = '',
    this.sgdbAuto = false,
    this.overrides = const <String, String>{},
    this.autoArt = const <String, String>{},
  });

  final bool steamCovers;
  final String sgdbKey;
  final bool sgdbAuto;

  /// Chosen artwork per game id (game id -> cached file path).
  final Map<String, String> overrides;

  /// Artwork fetched per game (game id -> cached file path).
  final Map<String, String> autoArt;

  bool get sgdbEnabled => sgdbKey.trim().isNotEmpty;

  factory ArtSettings.from(AppConfig config) => ArtSettings(
    steamCovers: config.coverFetch,
    sgdbKey: config.steamgriddbKey,
    sgdbAuto: config.steamgriddbAuto,
    overrides: config.artOverrides,
    autoArt: config.autoArt,
  );
}

/// Cover art / icon resolution, including lazy Steam CDN and SteamGridDB
/// downloads.
class CoverStore {
  CoverStore({
    ArtSettings? settings,
    String? coverDir,
    String? cdnBase,
    String? sgdbBase,
    Duration? bodyTimeout,
  }) : _settings = settings ?? const ArtSettings(),
       _coverFolder = coverDir ?? AppPaths.coverDir,
       _artCdn = cdnBase ?? defaultCdn,
       _sgdbBaseUrl = sgdbBase ?? SteamGridDb.defaultBaseUrl,
       _bodyTimeout = bodyTimeout ?? _defaultBodyTimeout;

  /// Where downloaded art is cached; the app's cache folder by default.
  final String _coverFolder;

  /// Steam CDN root, overridable so downloads can be pointed at a local server.
  final String _artCdn;

  /// SteamGridDB API root, overridable for the same reason.
  final String _sgdbBaseUrl;

  static const List<String> assets = [
    'library_600x900.jpg',
    'library_600x900_2x.jpg',
    'header.jpg',
  ];
  static const String defaultCdn =
      'https://cdn.cloudflare.steamstatic.com/steam/apps';
  static const String _userAgent = 'OmniLauncher/1.0';
  static const int _minBytes = 4096;

  /// The most a Steam capsule may weigh.
  static const int _maxCapsuleBytes = 16 * 1024 * 1024;

  /// The longest a capsule body may take; the connection timeout only covers
  /// the handshake, not a server that drips bytes forever.
  static const Duration _defaultBodyTimeout = Duration(seconds: 30);

  /// How long a Steam "no capsule" answer is believed before it is retried: a
  /// game can get artwork on the CDN long after the launcher first asked.
  static const Duration _missingTtl = Duration(days: 30);

  /// How many capsules are fetched at once.
  static const int _maxDownloads = 4;

  ArtSettings _settings;
  SteamGridDb? _sgdb;

  /// Steam CDN client, created on demand and shared by every capsule fetch:
  /// a grid of tiles asks for many capsules at once, and one client pools the
  /// connections instead of paying a handshake per capsule.
  HttpClient? _steamClient;

  /// The longest a capsule body may take, overridable for tests.
  final Duration _bodyTimeout;
  Map<String, String>? _themeIcons;
  final Set<String> _pending = <String>{};
  int _downloads = 0;
  final Queue<Completer<void>> _downloadQueue = Queue<Completer<void>>();

  /// Resolution results by game id, each with the file stamps it was computed
  /// from: [resolve] is called from build paths, so the stat chain runs again
  /// only when one of the files it read has actually changed.
  final Map<String, _Resolution> _resolutions = {};

  /// Whether the cover folder was already pruned this run.
  bool _pruned = false;

  ArtSettings get settings => _settings;

  set settings(ArtSettings value) {
    final keyChanged = _sgdb != null && _sgdb!.apiKey != value.sgdbKey;
    _settings = value;
    // New overrides or newly fetched art are exactly what the resolution
    // cache keys on, so a settings change has to recompute everything.
    _resolutions.clear();
    if (keyChanged) {
      _sgdb?.close();
      _sgdb = null;
    }
  }

  /// SteamGridDB client, created on demand.
  SteamGridDb get sgdb =>
      _sgdb ??= SteamGridDb(apiKey: _settings.sgdbKey, baseUrl: _sgdbBaseUrl);

  /// The shared Steam CDN client, created on demand.
  HttpClient get _cdn =>
      _steamClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);

  /// Release the network clients; the store must not be asked for art again.
  void close() {
    _steamClient?.close(force: true);
    _steamClient = null;
    _sgdb?.close();
    _sgdb = null;
  }

  String get _steamLibraryCache =>
      '${AppPaths.home}/.local/share/Steam/appcache/librarycache';

  /// Artwork the user pinned for this game, if the file is still there.
  String? overrideFor(Game game) {
    final path = _settings.overrides[game.id];
    if (path == null || path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }

  /// Artwork fetched for [game], when it is still on disk.
  String? autoArtFor(Game game) {
    final path = _settings.autoArt[game.id];
    if (path == null || path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }

  /// Best artwork available right now (never blocks on the network).
  Artwork resolve(Game game) {
    _prune();
    final stamp = _stampFor(game);
    final cached = _resolutions[game.id];
    if (cached != null && cached.matches(stamp)) return cached.artwork;
    final artwork = _resolve(game);
    _resolutions[game.id] = _Resolution(stamp, artwork);
    return artwork;
  }

  /// Best artwork available right now, worked out from the files on disk.
  Artwork _resolve(Game game) {
    final override = overrideFor(game);
    if (override != null) return Artwork(ArtworkKind.cover, value: override);
    final fetched = autoArtFor(game);
    if (fetched != null) return Artwork(ArtworkKind.cover, value: fetched);
    final cover = game.cover;
    if (cover != null && File(cover).existsSync()) {
      return Artwork(ArtworkKind.cover, value: cover);
    }
    if (game.source == SourceKind.steam) {
      final appid = '${game.extra['appid'] ?? ''}';
      if (appid.isNotEmpty) {
        final local = _steamLocal(appid) ?? _steamCached(appid);
        if (local != null) return Artwork(ArtworkKind.cover, value: local);
        return Artwork(ArtworkKind.letter, pending: _pendingFor(appid));
      }
    }
    final icon = game.icon;
    if (icon != null && icon.isNotEmpty) {
      if (game.iconIsName) {
        return Artwork(ArtworkKind.icon, value: icon, isName: true);
      }
      if (File(icon).existsSync()) {
        return Artwork(ArtworkKind.icon, value: icon);
      }
    }
    return Artwork(ArtworkKind.letter, pending: _pendingFor(null));
  }

  /// The file stamps [_resolve]'s answer for [game] depends on, in a fixed
  /// order: any change that could change the answer changes one of these.
  ///
  /// Steam's per-game folder is stamped rather than every asset in it: an
  /// asset that appears or vanishes changes the folder's mtime, and a file's
  /// contents changing does not matter — the answer is the path, which the
  /// tile reloads when it paints.
  List<int> _stampFor(Game game) {
    final stamp = <int>[
      _stamp(_settings.overrides[game.id]),
      _stamp(_settings.autoArt[game.id]),
      _stamp(game.cover),
    ];
    if (game.source == SourceKind.steam) {
      final appid = '${game.extra['appid'] ?? ''}';
      if (appid.isNotEmpty) {
        stamp.add(_stamp('$_steamLibraryCache/$appid'));
        stamp.add(_stamp('$_coverFolder/steam_$appid.jpg'));
        stamp.add(_stamp(_missingMarker(appid).path));
      }
    }
    final icon = game.icon;
    if (icon != null && icon.isNotEmpty && !game.iconIsName) {
      stamp.add(_stamp(icon));
    }
    return stamp;
  }

  /// [path]'s mtime in milliseconds, or -1 when it is not there.
  static int _stamp(String? path) {
    if (path == null || path.isEmpty) return -1;
    final FileStat stat;
    try {
      stat = FileStat.statSync(path);
    } on FileSystemException {
      return -1;
    }
    return stat.type == FileSystemEntityType.notFound
        ? -1
        : stat.modified.millisecondsSinceEpoch;
  }

  /// Delete cached art that nothing points at any more, once per run.
  ///
  /// A SteamGridDB pick of a game the library no longer holds would sit in the
  /// folder forever otherwise. Steam's capsules and the missing markers stay:
  /// they are keyed by app id, and a game that comes back finds them waiting.
  /// Anything that is not the launcher's own cache file is left alone.
  void _prune() {
    if (_pruned) return;
    _pruned = true;
    final folder = Directory(_coverFolder);
    if (!folder.existsSync()) return;
    final keep = <String>{
      ..._settings.overrides.values,
      ..._settings.autoArt.values,
    };
    final List<FileSystemEntity> entries;
    try {
      entries = folder.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      if (entry is! File) continue;
      // Only the SteamGridDB cache files are pruned: Steam's capsules and
      // markers are keyed by app id, and anything else is not ours.
      if (!entry.uri.pathSegments.last.startsWith('sgdb_')) continue;
      if (keep.contains(entry.path)) continue;
      try {
        entry.deleteSync();
      } on FileSystemException {
        // Another run of the launcher got there first; a stale file is only
        // ever disk space.
      }
    }
  }

  /// Whether a fetch could still produce art for a game whose Steam app id is
  /// [appid] (`null` when it has none).
  ///
  /// Reporting a fetch that cannot happen makes every tile ask for the same
  /// cover again (a request and a stat per tile), so a known missing Steam
  /// capsule and the games the CDN never covers are excluded here.
  bool _pendingFor(String? appid) {
    if (appid != null && _settings.steamCovers && !_missingFresh(appid)) {
      return true;
    }
    return _settings.sgdbEnabled && _settings.sgdbAuto;
  }

  // ---------------------------------------------------------------- steam

  File _missingMarker(String appid) =>
      File('$_coverFolder/steam_$appid.missing');

  /// True while [appid]'s missing marker is fresh enough to believe: a
  /// capsule can appear on the CDN later, so a marker older than
  /// [_missingTtl] counts as absent and the fetch is tried again.
  bool _missingFresh(String appid) {
    final marker = _missingMarker(appid);
    final FileStat stat;
    try {
      stat = marker.statSync();
    } on FileSystemException {
      return false;
    }
    if (stat.type == FileSystemEntityType.notFound) return false;
    return DateTime.now().difference(stat.modified) < _missingTtl;
  }

  String? _steamLocal(String appid) {
    for (final asset in assets) {
      final file = File('$_steamLibraryCache/$appid/$asset');
      if (file.existsSync() && file.lengthSync() > _minBytes) return file.path;
    }
    return null;
  }

  String? _steamCached(String appid) {
    final file = File('$_coverFolder/steam_$appid.jpg');
    if (!file.existsSync()) return null;
    if (file.lengthSync() > _minBytes) return file.path;
    // A zero or truncated capsule is no artwork; drop it so it is fetched
    // again instead of being shown as a broken image forever.
    try {
      file.deleteSync();
    } on FileSystemException {
      // Another run of the launcher got there first; a retry refetches.
    }
    return null;
  }

  /// Fetch the Steam capsule once; `null` when unavailable or disabled.
  Future<Artwork?> fetchSteamCover(Game game) async {
    if (!_settings.steamCovers || game.source != SourceKind.steam) return null;
    final appid = '${game.extra['appid'] ?? ''}';
    if (appid.isEmpty || !_pending.add('steam:$appid')) return null;
    await _acquireDownloadSlot();
    try {
      final path = await _downloadSteamCover(appid);
      return path == null ? null : Artwork(ArtworkKind.cover, value: path);
    } finally {
      _releaseDownloadSlot();
      _pending.remove('steam:$appid');
    }
  }

  /// Take one of the [_maxDownloads] download slots, waiting for a free one.
  ///
  /// A grid asks for every tile it shows at once; without the cap each of them
  /// would open its own connection to the CDN.
  Future<void> _acquireDownloadSlot() async {
    if (_downloads < _maxDownloads) {
      _downloads++;
      return;
    }
    final waiting = Completer<void>();
    _downloadQueue.add(waiting);
    await waiting.future;
  }

  void _releaseDownloadSlot() {
    if (_downloadQueue.isEmpty) {
      _downloads--;
      return;
    }
    // Hand the slot over to the next waiter instead of giving it up.
    _downloadQueue.removeFirst().complete();
  }

  Future<String?> _downloadSteamCover(String appid) async {
    final cached = _steamCached(appid);
    if (cached != null) return cached;
    final missing = _missingMarker(appid);
    if (_missingFresh(appid)) return null;
    Directory(_coverFolder).createSync(recursive: true);
    final target = File('$_coverFolder/steam_$appid.jpg');
    // The missing marker may only be written once the CDN has actually
    // answered for this app id; a host that cannot be reached says nothing
    // about whether the capsule exists.
    var answered = false;
    for (final asset in assets) {
      final HttpClientResponse response;
      try {
        final request = await _cdn.getUrl(Uri.parse('$_artCdn/$appid/$asset'));
        request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        response = await request.close();
      } on IOException {
        // Connection, DNS or TLS failure before any answer: not a "missing".
        continue;
      }
      answered = true;
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await _readBody(response);
      } on IOException {
        // A body that dies or stalls halfway says nothing about the capsule;
        // in particular it must not be remembered as missing.
        return null;
      } on TimeoutException {
        // A slow drip must not hold a download slot forever, and is no
        // answer either.
        return null;
      }
      if (bytes.length > _minBytes) {
        return await _writeCapsule(target, bytes) ? target.path : null;
      }
      // A body too small to be a real capsule; try the next asset.
    }
    if (answered) {
      try {
        missing.createSync(recursive: true);
      } on FileSystemException {
        // A missing marker is only an optimisation.
      }
    }
    return null;
  }

  /// The whole capsule body, bounded in size and time: the connection
  /// timeout covers the handshake only, so a server that drips bytes forever
  /// would otherwise hold a download slot for the rest of the run.
  Future<Uint8List> _readBody(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    // A stream timeout cancels the subscription; a future timeout would keep
    // reading the drip after the caller gave up.
    await for (final chunk in response.timeout(_bodyTimeout)) {
      builder.add(chunk);
      if (builder.length > _maxCapsuleBytes) {
        throw HttpException('capsule larger than $_maxCapsuleBytes bytes');
      }
    }
    return builder.takeBytes();
  }

  /// Store [bytes] at [target] via a temp file, so a tile can never read a
  /// half-written capsule; false when the disk would not take the write.
  Future<bool> _writeCapsule(File target, Uint8List bytes) async {
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
      return true;
    } on IOException {
      try {
        await temp.delete();
      } on IOException {
        // The write may have failed before the temp file existed.
      }
      return false;
    }
  }

  // ---------------------------------------------------------- steamgriddb

  /// Candidate artwork from SteamGridDB, best match first.
  ///
  /// Steam games are looked up by app id; everything else by name.
  Future<List<SgdbGrid>> searchArt(Game game) async {
    if (!_settings.sgdbEnabled) return const [];
    final appid = int.tryParse('${game.extra['appid'] ?? ''}');
    if (appid != null) {
      final byId = await sgdb.gridsForSteamApp(appid);
      if (byId.isNotEmpty) return byId;
    }
    return sgdb.gridsForName(game.name);
  }

  /// Where a SteamGridDB grid for [game] is cached.
  String artPath(Game game, SgdbGrid grid) =>
      '$_coverFolder/sgdb_${_slug(game.id)}_${grid.id}${grid.extension}';

  /// Download [grid] for [game]; returns the cached file path.
  Future<String?> downloadArt(Game game, SgdbGrid grid) =>
      sgdb.downloadGrid(grid, artPath(game, grid));

  static String _slug(String id) {
    final buffer = StringBuffer();
    for (final unit in id.codeUnits) {
      final isSafe =
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x41 && unit <= 0x5A) ||
          (unit >= 0x61 && unit <= 0x7A) ||
          unit == 0x2D ||
          unit == 0x2E;
      buffer.write(isSafe ? String.fromCharCode(unit) : '_');
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------- icons

  /// Index of PNG icons from the icon themes, built once and reused.
  ///
  /// Flutter cannot render SVG without a package, so only raster icons are
  /// indexed; anything else falls back to the letter tile.
  Map<String, String> _themeIconIndex() {
    final cached = _themeIcons;
    if (cached != null) return cached;
    final index = <String, String>{};
    final roots = [
      '${AppPaths.home}/.local/share/icons',
      Host.path('/usr/share/icons/hicolor'),
      Host.path('/usr/share/pixmaps'),
    ];
    for (final root in roots) {
      final directory = Directory(root);
      if (!directory.existsSync()) continue;
      List<FileSystemEntity> entries;
      try {
        entries = directory.listSync(recursive: true, followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        final dot = name.lastIndexOf('.');
        if (dot <= 0) continue;
        final extension = name.substring(dot).toLowerCase();
        if (extension != '.png' && extension != '.jpg') continue;
        index.putIfAbsent(name.substring(0, dot), () => entry.path);
      }
    }
    return _themeIcons = index;
  }

  /// Resolve an icon-theme name such as `steam` to a raster file, if any.
  String? themeIconPath(String name) => _themeIconIndex()[name];
}

/// A [CoverStore.resolve] answer, with the file stamps it was computed from.
class _Resolution {
  const _Resolution(this.stamp, this.artwork);

  final List<int> stamp;
  final Artwork artwork;

  /// True when [other] is the stamp the files give now.
  bool matches(List<int> other) {
    if (other.length != stamp.length) return false;
    for (var index = 0; index < stamp.length; index++) {
      if (stamp[index] != other[index]) return false;
    }
    return true;
  }
}
