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
  const Artwork(this.kind, {this.value, this.isName = false, this.pending = false});

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
  CoverStore({ArtSettings? settings, String? coverDir, String? cdnBase, String? sgdbBase})
    : _settings = settings ?? const ArtSettings(),
      _coverFolder = coverDir ?? AppPaths.coverDir,
      _artCdn = cdnBase ?? defaultCdn,
      _sgdbBaseUrl = sgdbBase ?? SteamGridDb.defaultBaseUrl;

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
  static const String defaultCdn = 'https://cdn.cloudflare.steamstatic.com/steam/apps';
  static const String _userAgent = 'OmniLauncher/1.0';
  static const int _minBytes = 4096;

  /// How many capsules are fetched at once, the size of the Python
  /// launcher's cover pool.
  static const int _maxDownloads = 4;

  ArtSettings _settings;
  SteamGridDb? _sgdb;
  Map<String, String>? _themeIcons;
  final Set<String> _pending = <String>{};
  int _downloads = 0;
  final Queue<Completer<void>> _downloadQueue = Queue<Completer<void>>();

  ArtSettings get settings => _settings;

  set settings(ArtSettings value) {
    final keyChanged = _sgdb != null && _sgdb!.apiKey != value.sgdbKey;
    _settings = value;
    if (keyChanged) {
      _sgdb?.close();
      _sgdb = null;
    }
  }

  /// SteamGridDB client, created on demand.
  SteamGridDb get sgdb =>
      _sgdb ??= SteamGridDb(apiKey: _settings.sgdbKey, baseUrl: _sgdbBaseUrl);

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
      if (game.iconIsName) return Artwork(ArtworkKind.icon, value: icon, isName: true);
      if (File(icon).existsSync()) return Artwork(ArtworkKind.icon, value: icon);
    }
    return Artwork(ArtworkKind.letter, pending: _pendingFor(null));
  }

  /// Whether a fetch could still produce art for a game whose Steam app id is
  /// [appid] (`null` when it has none).
  ///
  /// Reporting a fetch that cannot happen makes every tile ask for the same
  /// cover again (a request and a stat per tile), so a known missing Steam
  /// capsule and the games the CDN never covers are excluded here.
  bool _pendingFor(String? appid) {
    if (appid != null && _settings.steamCovers && !_missingMarker(appid).existsSync()) {
      return true;
    }
    return _settings.sgdbEnabled && _settings.sgdbAuto;
  }

  // ---------------------------------------------------------------- steam

  File _missingMarker(String appid) => File('$_coverFolder/steam_$appid.missing');

  String? _steamLocal(String appid) {
    for (final asset in assets) {
      final file = File('$_steamLibraryCache/$appid/$asset');
      if (file.existsSync() && file.lengthSync() > _minBytes) return file.path;
    }
    return null;
  }

  String? _steamCached(String appid) {
    final file = File('$_coverFolder/steam_$appid.jpg');
    return file.existsSync() ? file.path : null;
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
    if (missing.existsSync()) return null;
    Directory(_coverFolder).createSync(recursive: true);
    final target = File('$_coverFolder/steam_$appid.jpg');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      for (final asset in assets) {
        try {
          final request = await client.getUrl(Uri.parse('$_artCdn/$appid/$asset'));
          request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) {
            await response.drain<void>();
            continue;
          }
          final builder = BytesBuilder(copy: false);
          await for (final chunk in response) {
            builder.add(chunk);
          }
          final bytes = builder.takeBytes();
          if (bytes.length > _minBytes) {
            target.writeAsBytesSync(bytes);
            return target.path;
          }
        } on IOException {
          continue;
        }
      }
    } finally {
      client.close(force: true);
    }
    try {
      missing.createSync(recursive: true);
    } on FileSystemException {
      // A missing marker is only an optimisation.
    }
    return null;
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
