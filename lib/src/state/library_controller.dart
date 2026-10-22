import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../art/steamgriddb.dart';
import '../config.dart';
import '../covers.dart';
import '../launcher.dart';
import '../model/game.dart';
import '../paths.dart';
import '../plugins/bundled.dart';
import '../plugins/catalog.dart' as catalogue;
import '../plugins/plugin.dart';
import '../plugins/plugin_runner.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../util/proc.dart';
import 'playtime_store.dart';
import 'plugin_store.dart';

enum LibraryStatus { loading, ready, failed }

/// Library state: discovery, filtering, artwork, launching and persistence.
class LibraryController extends ChangeNotifier {
  LibraryController({
    AppConfig? config,
    String? configPath,
    String? cachePath,
    PlaytimeStore? playtime,
    CoverStore? covers,
    PluginStore? pluginAnswers,
    String? pluginDir,
    AssetReader? pluginAssets,
    catalogue.UrlReader? pluginReader,
    Duration? pollInterval,
    Duration? noticeDuration,
    Duration? artSaveDelay,
    List<GameSource>? sources,
  }) : _configPath = configPath ?? AppPaths.configFile,
       _cachePath = cachePath ?? AppPaths.cacheFile,
       _pluginDir = pluginDir ?? AppPaths.pluginDir,
       _pluginAssets = pluginAssets ?? bundledAsset,
       _pluginReader = pluginReader ?? catalogue.readUrl,
       _pollInterval = pollInterval ?? const Duration(seconds: 5),
       _noticeDuration = noticeDuration ?? const Duration(seconds: 6),
       _artSaveDelay = artSaveDelay ?? const Duration(seconds: 2),
       // The parameter keeps its public name: tests inject sources through it.
       // ignore: prefer_initializing_formals
       _sources = sources,
       playtime = playtime ?? PlaytimeStore(),
       covers = covers ?? CoverStore(),
       pluginAnswers = pluginAnswers ?? PluginStore(),
       config = config ?? AppConfig.load(configPath ?? AppPaths.configFile) {
    this.covers.settings = ArtSettings.from(this.config);
  }

  final String _configPath;

  /// Where the last scan is remembered; the app's cache folder by default.
  final String _cachePath;

  /// Played time history. Tests inject a store pointed at a temporary file.
  final PlaytimeStore playtime;

  /// Sessions still being watched, by game id.
  final Map<String, Timer> _sessions = <String, Timer>{};

  /// How often a launched pid is checked, and how often the store is told.
  ///
  /// The pid check is a `/proc` lookup, so it can afford to be frequent; the
  /// store write is the part that is kept to [_touchInterval]. Tests shorten
  /// [_pollInterval] so a session can be watched to its end quickly.
  final Duration _pollInterval;
  static const Duration _touchInterval = Duration(seconds: 30);

  /// How long a [notice] stays before it clears itself. Tests shorten it.
  final Duration _noticeDuration;

  /// How long automatic-artwork config changes accumulate before they are
  /// written; a scan can add many at once, and each write is the whole file.
  final Duration _artSaveDelay;

  /// Set by [dispose]: async work still in flight must not notify afterwards.
  bool _disposed = false;

  /// [notifyListeners], unless the controller was disposed while the work
  /// that is notifying was still in flight. Synchronous callers keep plain
  /// `notifyListeners()`; this guard is for the post-`await` paths.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// The sources a rescan asks; the ones on this machine, unless a test
  /// handed in a fixed set (mirrors `discoverAll`'s own seam).
  final List<GameSource>? _sources;

  /// Consecutive polls a live launcher may have no descendants before it is
  /// asked to close.
  static const int closeAfterQuietTicks = 2;

  AppConfig config;

  /// Artwork resolution. Tests inject a store pointed at a local server.
  final CoverStore covers;

  /// Artwork fetches in flight, by game id.
  final Map<String, Future<Artwork?>> _artFetches =
      <String, Future<Artwork?>>{};

  /// Debounce for automatic-artwork config writes; see [_scheduleArtSave].
  Timer? _artSaveTimer;
  bool _artSavePending = false;

  /// What the plugins said, per plugin and game.
  final PluginStore pluginAnswers;

  /// Plugins found in the plugin folder, in name order.
  List<Plugin> plugins = const [];

  /// What the plugin store offers, once its catalogue has been read.
  List<catalogue.PluginEntry> catalog = const [];

  /// Why the catalogue could not be read, if it could not.
  String? catalogFailure;

  /// Whether the catalogue is being read right now.
  bool catalogLoading = false;

  /// Plugin lookups that are running right now, by plugin and query.
  final Set<String> _lookingUp = <String>{};

  /// Plugins being installed or removed right now, by plugin id.
  final Set<String> _pluginBusy = <String>{};

  /// Where plugins are installed. The app's own folder, unless a caller said
  /// otherwise.
  final String _pluginDir;

  /// Reads the plugins that ship with the launcher, out of the app bundle.
  final AssetReader _pluginAssets;

  /// Reads a URL. The app's own reader goes to the network; a test can hand in
  /// one that answers from memory.
  final catalogue.UrlReader _pluginReader;

  String get pluginDir => _pluginDir;

  /// Say something in the status bar, and show it now.
  ///
  /// For callers that are not the controller, such as the panel's cog: setting
  /// [notice] alone would wait for the next unrelated change to appear.
  void announce(String message) {
    notice = message;
    notifyListeners();
  }

  LibraryStatus status = LibraryStatus.loading;

  /// The library as discovered, before name overrides; [games] is this list
  /// with the overrides applied.
  List<Game> _discovered = const [];
  List<Game> games = const [];
  String query = '';
  final Set<SourceKind> sourceFilter = <SourceKind>{};
  Game? selected;

  /// Last thing that happened, shown in the status bar.
  ///
  /// A notice clears itself after [_noticeDuration]: the status bar reports
  /// what just happened, not what happened at some point. Assigning again —
  /// including null — replaces the pending clear.
  String? get notice => _notice;

  set notice(String? value) {
    _notice = value;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    // After dispose the clear would fire into a dead controller.
    if (value == null || _disposed) return;
    _noticeTimer = Timer(_noticeDuration, () {
      _noticeTimer = null;
      // A newer notice reschedules instead, so what fires here is only ever
      // the clear for a notice still showing.
      if (_notice == null) return;
      _notice = null;
      _notify();
    });
  }

  String? _notice;
  Timer? _noticeTimer;

  String? failure;

  /// Games matching the current query, filter and hidden settings.
  ///
  /// Favourites come first; inside each group the order is [sortMode].
  List<Game> get visibleGames {
    final needle = query.trim().toLowerCase();
    // One set for the whole pass: [config.favorites] is a list, and the loop
    // asks once per game.
    final favoriteIds = config.favorites.toSet();
    final favorites = <Game>[];
    final rest = <Game>[];
    for (final game in games) {
      if (!config.showHidden && config.isHidden(game.id)) continue;
      if (sourceFilter.isNotEmpty && !sourceFilter.contains(game.source)) {
        continue;
      }
      if (needle.isNotEmpty &&
          !game.name.toLowerCase().contains(needle) &&
          !game.id.toLowerCase().contains(needle) &&
          !game.displaySubtitle.toLowerCase().contains(needle)) {
        continue;
      }
      (favoriteIds.contains(game.id) ? favorites : rest).add(game);
    }
    return [..._ordered(favorites), ..._ordered(rest)];
  }

  /// How the wall orders its games; one of [AppConfig.sortModes].
  String get sortMode => config.sortMode;

  /// Persist [mode] and re-order the wall. Anything outside
  /// [AppConfig.sortModes] — or the mode already showing — is ignored.
  Future<void> setSortMode(String mode) async {
    if (!AppConfig.sortModes.contains(mode) || mode == config.sortMode) return;
    _apply(config.copyWith(sortMode: mode));
    notifyListeners();
  }

  /// Whether [gameId] is pinned as a favourite.
  bool isFavorite(String gameId) => config.favorites.contains(gameId);

  /// Pin or unpin [gameId] as a favourite, persisted with the config.
  Future<void> toggleFavorite(String gameId) async {
    final favorites = List<String>.from(config.favorites);
    if (!favorites.remove(gameId)) favorites.add(gameId);
    _apply(config.copyWith(favorites: favorites));
    notifyListeners();
  }

  /// [matched] in [sortMode] order: by name, by last played (never played
  /// last), or by total played (none last). Ties fall back to the name order
  /// the library itself keeps.
  List<Game> _ordered(List<Game> matched) {
    switch (config.sortMode) {
      case 'lastPlayed':
        // One store lookup per game, memoized for the sort, instead of two
        // per comparison.
        final lastPlayed = <String, DateTime?>{
          for (final game in matched) game.id: playtime.lastPlayedFor(game.id),
        };
        matched.sort((a, b) {
          final at = lastPlayed[a.id];
          final bt = lastPlayed[b.id];
          if (at == null) return bt == null ? _byName(a, b) : 1;
          if (bt == null) return -1;
          final byPlayed = bt.compareTo(at);
          return byPlayed != 0 ? byPlayed : _byName(a, b);
        });
        return matched;
      case 'mostPlayed':
        final totals = <String, Duration>{
          for (final game in matched) game.id: playtime.totalFor(game.id),
        };
        matched.sort((a, b) {
          final byTime = totals[b.id]!.compareTo(totals[a.id]!);
          return byTime != 0 ? byTime : _byName(a, b);
        });
        return matched;
      default:
        return sortGames(matched);
    }
  }

  static int _byName(Game a, Game b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.source.index.compareTo(b.source.index);
  }

  int get hiddenCount => games.where((game) => config.isHidden(game.id)).length;

  Map<SourceKind, int> get countsBySource {
    final counts = <SourceKind, int>{};
    for (final game in games) {
      counts[game.source] = (counts[game.source] ?? 0) + 1;
    }
    return counts;
  }

  /// How many games the recently played shelf offers.
  static const int recentLimit = 10;

  /// The games that were played most recently, newest first, at most [limit].
  ///
  /// Only games still in the library can appear: playtime outlives a game that
  /// was uninstalled or a source that went away, and the history keeps those
  /// ids. The wall's own rules apply on top, so the shelf never offers a cover
  /// the wall itself would hide: [visible] is the already-computed visible
  /// list when the caller has one, and [visibleGames] otherwise.
  List<Game> recentlyPlayed({int limit = recentLimit, List<Game>? visible}) {
    final played = <(DateTime, Game)>[
      for (final game in visible ?? visibleGames)
        if (playtime.lastPlayedFor(game.id) case final at?) (at, game),
    ];
    played.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final (_, game) in played.take(limit)) game];
  }

  /// Load the cached library first, then rescan when asked to.
  Future<void> load({bool refresh = true}) async {
    // A session left open by a previous run is closed at the last moment the
    // game was seen, so a launcher that was killed mid-game cannot invent time.
    playtime.closeOpenSessions(DateTime.now());
    status = LibraryStatus.loading;
    notifyListeners();
    final cached = _readCache();
    if (cached.isNotEmpty) {
      _discovered = cached;
      games = applyNameOverrides(cached, config.nameOverrides);
      status = LibraryStatus.ready;
      notifyListeners();
    }
    if (refresh) await rescan();
  }

  /// The scan that is running, if one is. Rescans never overlap.
  Future<void>? _rescan;

  /// Whether another scan was asked for while [_rescan] ran.
  bool _rescanAgain = false;

  /// Scan every source again.
  ///
  /// Asking while a scan runs queues exactly one more behind it — however
  /// often the ask comes (a refresh during a load, two manual entries added
  /// in a row) it collapses into that one trailing scan — and every caller's
  /// future settles when the scans its ask folded into are done.
  Future<void> rescan() {
    final running = _rescan;
    if (running != null) {
      _rescanAgain = true;
      return running;
    }
    final scan = _scanUntilSettled();
    _rescan = scan;
    return scan;
  }

  Future<void> _scanUntilSettled() async {
    try {
      do {
        _rescanAgain = false;
        await _scan();
      } while (_rescanAgain);
    } finally {
      _rescan = null;
    }
  }

  Future<void> _scan() async {
    status = games.isEmpty ? LibraryStatus.loading : status;
    notifyListeners();
    try {
      // One broken source fails its games, not the scan: the rest of the
      // library still arrives, and the status bar says what was lost.
      final errors = <String>[];
      final found = await discoverAll(
        // Overrides are applied here instead, so a rename can be undone.
        config.copyWith(nameOverrides: const <String, String>{}),
        sources: _sources,
        onError: (kind, error) => errors.add('${kind.label}: $error'),
      );
      _discovered = found;
      games = applyNameOverrides(found, config.nameOverrides);
      _writeCache(found);
      failure = errors.isEmpty ? null : errors.join('; ');
      notice = '${found.length} games from ${countsBySource.length} sources';
    } catch (error) {
      failure = '$error';
    }
    status = LibraryStatus.ready;
    // The selection survives a scan by id; a game the scan no longer offers
    // is gone, and so is its selection.
    selected = selected == null ? null : _findById(selected!.id);
    _notify();
  }

  Game? _findById(String id) {
    for (final game in games) {
      if (game.id == id) return game;
    }
    return null;
  }

  void setQuery(String value) {
    if (query == value) return;
    query = value;
    notifyListeners();
  }

  void toggleSource(SourceKind kind) {
    if (!sourceFilter.remove(kind)) sourceFilter.add(kind);
    notifyListeners();
  }

  void clearSources() {
    sourceFilter.clear();
    notifyListeners();
  }

  void select(Game? game) {
    selected = game;
    notifyListeners();
  }

  /// Rename a game for display and for SteamGridDB lookups.
  ///
  /// [name] null or blank resets it to the discovered name.
  void setName(String gameId, String? name) {
    final trimmed = (name ?? '').trim();
    final overrides = {...config.nameOverrides};
    if (trimmed.isEmpty) {
      overrides.remove(gameId);
    } else {
      overrides[gameId] = trimmed;
    }
    _apply(config.copyWith(nameOverrides: overrides));
    games = applyNameOverrides(_discovered, overrides);
    if (selected?.id == gameId) selected = _findById(gameId);
    notice = trimmed.isEmpty ? 'Name reset' : 'Renamed to $trimmed';
    notifyListeners();
  }

  /// The name the launcher found for [gameId], before any rename.
  ///
  /// Null when the game is not in the discovered list, which is only possible
  /// before the first scan has produced one.
  String? discoveredNameFor(String gameId) {
    for (final game in _discovered) {
      if (game.id == gameId) return game.name;
    }
    return null;
  }

  Future<void> launch(Game game) async {
    final startedAt = DateTime.now();
    int? pid;
    try {
      pid = await Launcher.launch(game);
      // A launch that works clears an earlier failure (say a scan report),
      // so it does not resurface once the transient notice fades.
      failure = null;
      notice = 'Launched ${game.name}';
    } catch (error) {
      failure = 'Could not launch ${game.name}: $error';
    }
    // A launch that failed has nothing to record.
    if (pid != null) _watchSession(game.id, pid, startedAt);
    _notify();
  }

  /// Total time played, from closed sessions plus the open one.
  Duration playtimeOf(String gameId) => playtime.totalFor(gameId);

  /// When the game was last seen running or stopped, if ever.
  DateTime? lastPlayedFor(String gameId) => playtime.lastPlayedFor(gameId);

  /// Whether an open session is due another persisted heartbeat.
  ///
  /// The store is told at most every [_touchInterval], however often the pid is
  /// polled: writes stay rare without the session end losing accuracy, because
  /// the session always ends at the last moment the process was seen.
  static bool shouldTouch(DateTime lastTouched, DateTime now) =>
      now.difference(lastTouched) >= _touchInterval;

  /// Whether the process we started should be asked to close.
  ///
  /// Only true for a game the user asked for, while the process we launched is
  /// still alive, once it has started something of its own and that something
  /// has been gone for [closeAfterQuietTicks] polls. A process that never
  /// started a child is left alone: that is the game itself, not a launcher
  /// window around it, and `steam -applaunch` hands over and exits the same way.
  static bool shouldCloseLauncher({
    required bool closeWithGame,
    required bool alive,
    required bool sawDescendants,
    required int quietTicks,
  }) =>
      closeWithGame &&
      alive &&
      sawDescendants &&
      quietTicks >= closeAfterQuietTicks;

  /// Follow a launched game's pid so its session ends when the game does.
  ///
  /// `Launcher` starts the game detached with `exec`, so [pid] is the game's
  /// own. The session always ends at the last moment the process was seen: a
  /// game that exits between two checks is never credited with the gap.
  ///
  /// The same poll asks a launcher window to close when the game it started is
  /// gone (see [shouldCloseLauncher]) — a launcher that ignores the request
  /// simply stays open.
  void _watchSession(String gameId, int pid, DateTime startedAt) {
    _sessions.remove(gameId)?.cancel();
    playtime.begin(gameId, startedAt);
    // Identifies the process we started: a recycled pid must never be signalled.
    final startTick = processStartTime(pid);
    var lastSeen = startedAt;
    var lastTouched = startedAt;
    var sawDescendants = false;
    var quietTicks = 0;
    var asked = false;
    _sessions[gameId] = Timer.periodic(_pollInterval, (timer) {
      final now = DateTime.now();
      // One read of /proc/<pid>/stat answers both questions: alive, and still
      // the process we started (a recycled pid gets a new start time).
      final snapshot = processSnapshot(pid);
      final alive =
          snapshot != null &&
          snapshot.running &&
          (startTick == null || snapshot.startTime == startTick);
      if (!alive) {
        timer.cancel();
        _sessions.remove(gameId);
        playtime.end(gameId, lastSeen);
        notifyListeners();
        return;
      }
      lastSeen = now;
      if (shouldTouch(lastTouched, now)) {
        lastTouched = now;
        playtime.touch(gameId, now);
        // The heartbeat moved the totals; the detail panel and the shelf
        // follow the session live rather than freezing until it ends.
        notifyListeners();
      }
      if (asked) return;
      // Walking /proc on every tick is only needed to decide when a game
      // launcher has outlived its game; a plain session just polls the pid.
      if (!config.closesWithGame(gameId)) return;
      if (descendants(pid).isEmpty) {
        quietTicks++;
      } else {
        // The launcher has its game running; losing it later means the game is
        // over.
        sawDescendants = true;
        quietTicks = 0;
      }
      if (shouldCloseLauncher(
        closeWithGame: config.closesWithGame(gameId),
        alive: alive,
        sawDescendants: sawDescendants,
        quietTicks: quietTicks,
      )) {
        asked = true;
        Process.killPid(pid, ProcessSignal.sigterm);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _sessions.values) {
      timer.cancel();
    }
    _sessions.clear();
    _noticeTimer?.cancel();
    // A debounced automatic-art write must not be lost with the window.
    _flushArtSave();
    covers.close();
    super.dispose();
  }

  Future<void> openFolder(Game game) async {
    final target =
        game.path ??
        (game.command.isNotEmpty ? _parentOf(game.command.first) : null);
    if (target == null || !Directory(target).existsSync()) {
      failure = '${game.name}: no folder known';
      notifyListeners();
      return;
    }
    try {
      await Launcher.openFolder(target);
      failure = null;
      notice = 'Opened $target';
    } catch (error) {
      failure = 'Could not open $target: $error';
    }
    _notify();
  }

  static String? _parentOf(String path) {
    final index = path.lastIndexOf('/');
    return index <= 0 ? null : path.substring(0, index);
  }

  // ------------------------------------------------------------ artwork

  /// Artwork for a tile: Steam CDN first, then SteamGridDB when enabled.
  ///
  /// A SteamGridDB pick is remembered in the config so it survives rescans.
  ///
  /// The wall and the recently played shelf can show one game at the same
  /// moment, and both tiles ask: they get the same answer from one fetch. A
  /// caller told "nothing came back" keeps its letter tile until it is rebuilt,
  /// so the second one waits for the first fetch rather than being refused.
  Future<Artwork?> requestCoverArt(Game game) {
    final pending = _artFetches[game.id];
    if (pending != null) return pending;
    final fetch = _fetchCoverArt(game);
    _artFetches[game.id] = fetch;
    // The entry goes when the fetch settles, whatever it settled with.
    fetch.whenComplete(() => _artFetches.remove(game.id)).ignore();
    return fetch;
  }

  /// How long an automatic SteamGridDB lookup that found nothing is believed
  /// before the game is asked about again — comparable to [CoverStore]'s
  /// 30-day Steam missing marker: artwork can appear long after release.
  static const Duration sgdbMissTtl = Duration(days: 30);

  Future<Artwork?> _fetchCoverArt(Game game) async {
    if (covers.overrideFor(game) != null) return null;
    if (covers.autoArtFor(game) != null) return null;
    final steam = await covers.fetchSteamCover(game);
    if (steam != null) return steam;
    if (!(covers.settings.sgdbEnabled && covers.settings.sgdbAuto)) return null;
    final miss = config.sgdbMisses[game.id];
    if (miss != null &&
        DateTime.now().millisecondsSinceEpoch - miss <
            sgdbMissTtl.inMilliseconds) {
      // This game was asked about recently and had nothing; asking again
      // every run would only cost the API quota.
      return null;
    }
    try {
      final grids = await covers.searchArt(game);
      if (grids.isEmpty) {
        _applyAutoArt(
          sgdbMisses: {
            ...config.sgdbMisses,
            game.id: DateTime.now().millisecondsSinceEpoch,
          },
        );
        return null;
      }
      final path = await covers.downloadArt(game, grids.first);
      if (path == null) return null;
      final misses = {...config.sgdbMisses}..remove(game.id);
      _applyAutoArt(
        autoArt: {...config.autoArt, game.id: path},
        sgdbMisses: misses,
      );
      return Artwork(ArtworkKind.cover, value: path);
    } on SteamGridDbException catch (error) {
      failure = '${game.name}: $error';
      return null;
    }
  }

  /// Fold automatic-artwork changes (a fetched pick or a remembered miss)
  /// into [config] and schedule the write.
  ///
  /// A scan can add many entries at once and each save writes the whole
  /// file, so the write is debounced: a burst costs one write once it
  /// settles, and [dispose] flushes whatever is still pending. Any other
  /// config change saves everything at once, which clears the pending write
  /// (see [_apply]).
  void _applyAutoArt({
    Map<String, String>? autoArt,
    Map<String, int>? sgdbMisses,
  }) {
    config = config.copyWith(autoArt: autoArt, sgdbMisses: sgdbMisses);
    covers.settings = ArtSettings.from(config);
    _artSavePending = true;
    _artSaveTimer?.cancel();
    _artSaveTimer = Timer(_artSaveDelay, _flushArtSave);
  }

  /// Write the config now when automatic-artwork changes are waiting.
  void _flushArtSave() {
    _artSaveTimer?.cancel();
    _artSaveTimer = null;
    if (!_artSavePending) return;
    _artSavePending = false;
    config.save(_configPath);
  }

  /// Candidates for the art picker; sets [failure] when the lookup fails.
  Future<List<SgdbGrid>> searchArt(Game game) async {
    try {
      return await covers.searchArt(game);
    } on SteamGridDbException catch (error) {
      failure = '${game.name}: $error';
      _notify();
      return const [];
    }
  }

  /// Pin [grid] as this game's artwork.
  ///
  /// A download that fails is reported through [failure] and never thrown, so
  /// a caller (the art picker) cannot be left stuck on its "applying" state.
  Future<bool> applyArt(Game game, SgdbGrid grid) async {
    String? path;
    Object? problem;
    try {
      path = await covers.downloadArt(game, grid);
    } catch (error) {
      problem = error;
    }
    if (path == null) {
      failure = problem == null
          ? '${game.name}: artwork download failed'
          : '${game.name}: $problem';
      _notify();
      return false;
    }
    _apply(
      config.copyWith(artOverrides: {...config.artOverrides, game.id: path}),
    );
    failure = null;
    notice = 'Artwork for ${game.name} set';
    _notify();
    return true;
  }

  /// Drop the pinned artwork, falling back to the automatic sources.
  void clearArt(Game game) {
    final overrides = {...config.artOverrides}..remove(game.id);
    _apply(config.copyWith(artOverrides: overrides));
    notice = 'Artwork for ${game.name} reset';
    notifyListeners();
  }

  /// Check a key without saving it; returns a human readable result.
  Future<String> testSgdbKey(String key) async {
    if (key.trim().isEmpty) return 'Paste a SteamGridDB API key first.';
    final client = SteamGridDb(apiKey: key);
    try {
      final count = await client.testKey();
      return 'Key works: $count results for "portal".';
    } on SteamGridDbException catch (error) {
      return '$error';
    } finally {
      client.close();
    }
  }

  // ------------------------------------------------------------- plugins

  /// Install the plugins that ship with the launcher, then read the plugin
  /// folder again.
  ///
  /// Called at start up, and whenever the folder may have changed.
  Future<void> reloadPlugins() async {
    try {
      await installBundledPlugins(dir: _pluginDir, read: _pluginAssets);
    } catch (error) {
      failure = 'Plugins: $error';
    }
    plugins = discoverPlugins(
      _pluginDir,
      onError: (_, error) => failure = 'Plugins: $error',
    );
    _notify();
  }

  /// Read the plugin store's catalogue.
  Future<void> refreshCatalog({Uri? index}) async {
    catalogLoading = true;
    catalogFailure = null;
    notifyListeners();
    try {
      catalog = await catalogue.fetchCatalog(index: index, read: _pluginReader);
    } on catalogue.PluginStoreException catch (error) {
      catalogFailure = error.message;
    }
    catalogLoading = false;
    _notify();
  }

  /// Whether [pluginId] is being installed or removed right now.
  bool isPluginBusy(String pluginId) => _pluginBusy.contains(pluginId);

  /// Install what the store offers for [entry], and pick it up.
  ///
  /// A plugin applies to the launcher as soon as it is unpacked: the folder is
  /// read again, which is what puts its section in the detail panel.
  Future<void> installPlugin(catalogue.PluginEntry entry) async {
    if (!_pluginBusy.add(entry.id)) return;
    notice = 'Installing ${entry.name}…';
    notifyListeners();
    try {
      await catalogue.installPlugin(
        entry,
        dir: _pluginDir,
        read: _pluginReader,
      );
      notice = 'Installed ${entry.name}';
    } on catalogue.PluginStoreException catch (error) {
      failure = '${entry.name}: ${error.message}';
    } catch (error) {
      failure = '${entry.name}: $error';
    }
    _pluginBusy.remove(entry.id);
    await reloadPlugins();
    _notify();
  }

  /// Remove the installed [plugin].
  Future<void> removePlugin(Plugin plugin) async {
    if (!_pluginBusy.add(plugin.id)) return;
    notice = 'Removing ${plugin.name}…';
    notifyListeners();
    try {
      await catalogue.removePlugin(plugin.id, dir: _pluginDir);
      notice = 'Removed ${plugin.name}';
    } on catalogue.PluginStoreException catch (error) {
      failure = '${plugin.name}: ${error.message}';
    } catch (error) {
      failure = '${plugin.name}: $error';
    }
    _pluginBusy.remove(plugin.id);
    await reloadPlugins();
    _notify();
  }

  /// The loaded plugin with [id], if there is one.
  Plugin? plugin(String id) {
    for (final plugin in plugins) {
      if (plugin.id == id) return plugin;
    }
    return null;
  }

  /// What [pluginId] said about the game (or the name) [queryId], if it was
  /// ever asked.
  PluginAnswer? pluginAnswer(String pluginId, String queryId) =>
      pluginAnswers.answer(pluginId, queryId);

  /// Whether [pluginId] is answering [queryId] right now.
  bool isLookingUp(String pluginId, String queryId) =>
      _lookingUp.contains(PluginStore.keyFor(pluginId, queryId));

  /// Ask [plugin] about [query], and remember what it says.
  ///
  /// A lookup is a round trip to somebody else's site, so the answer is cached
  /// and the same query is never asked twice at once.
  Future<void> lookUp(Plugin plugin, PluginQuery query) async {
    final key = PluginStore.keyFor(plugin.id, query.id);
    if (!_lookingUp.add(key)) return;
    notice = '${plugin.name}: looking up ${query.name}…';
    notifyListeners();
    try {
      final answer = await askPlugin(plugin, query);
      pluginAnswers.put(plugin.id, query.id, answer);
      if (answer.ok) {
        failure = null;
        notice = '${plugin.name} answered for ${query.name}';
      } else {
        failure = answer.error;
      }
    } catch (error) {
      // runPlugin promises never to throw; if that promise ever breaks, the
      // user still hears about it and the guard below still clears.
      failure = '${plugin.name}: $error';
    } finally {
      _lookingUp.remove(key);
    }
    _notify();
  }

  /// The round trip [lookUp] makes, split out so a test can make it fail.
  Future<PluginAnswer> askPlugin(Plugin plugin, PluginQuery query) =>
      runPlugin(plugin, query);

  /// Open a URL in whatever the desktop uses for links.
  Future<void> openUrl(String url) async {
    try {
      await Launcher.openUrl(url);
    } catch (error) {
      failure = 'Could not open $url: $error';
      _notify();
    }
  }

  // -------------------------------------------------------------- config

  void _apply(AppConfig next) {
    config = next;
    covers.settings = ArtSettings.from(next);
    next.save(_configPath);
    // The save just wrote everything, including any automatic-art burst that
    // was still waiting for its debounce.
    _artSaveTimer?.cancel();
    _artSaveTimer = null;
    _artSavePending = false;
  }

  void setHidden(Game game, {required bool hidden}) {
    final hiddenIds = {...config.hidden};
    if (hidden) {
      hiddenIds.add(game.id);
    } else {
      hiddenIds.remove(game.id);
    }
    _apply(config.copyWith(hidden: hiddenIds));
    notice = hidden ? 'Hid ${game.name}' : 'Unhid ${game.name}';
    notifyListeners();
  }

  void toggleShowHidden() {
    _apply(config.copyWith(showHidden: !config.showHidden));
    notifyListeners();
  }

  /// Fold the source sidebar down to its icon rail, or open it again.
  void toggleSidebar() {
    _apply(config.copyWith(sidebarCollapsed: !config.sidebarCollapsed));
    notifyListeners();
  }

  void setCoverFetch(bool value) {
    _apply(config.copyWith(coverFetch: value));
    notifyListeners();
  }

  void setSteamgriddbAuto(bool value) {
    _apply(config.copyWith(steamgriddbAuto: value));
    notifyListeners();
  }

  /// Palette selection, persisted with the rest of the config.
  void setThemeMode(AppThemeMode mode) {
    _apply(config.copyWith(themeMode: mode));
    notifyListeners();
  }

  /// Accent colour, persisted with the rest of the config.
  void setAccentColor(AppAccent accent) {
    _apply(config.copyWith(accentColor: accent.id));
    notifyListeners();
  }

  /// Whether the launcher window should close when this game exits.
  void setCloseWithGame(String gameId, bool value) {
    final ids = {...config.closeWithGame};
    if (value) {
      ids.add(gameId);
    } else {
      ids.remove(gameId);
    }
    _apply(config.copyWith(closeWithGame: ids));
    notice = value ? 'Launcher closes with the game' : 'Launcher stays open';
    notifyListeners();
  }

  void setSteamgriddbKey(String value) {
    _apply(config.copyWith(steamgriddbKey: value.trim()));
    notice = value.trim().isEmpty
        ? 'SteamGridDB key cleared'
        : 'SteamGridDB key saved';
    notifyListeners();
  }

  void setAppimageDirs(List<String> dirs) {
    _apply(config.copyWith(appimageDirs: dirs));
    notifyListeners();
  }

  /// Remember the window's size so the next launch restores it.
  ///
  /// Saved without notifying: the window is already that size, so nothing
  /// would repaint — and resize bookkeeping can call this on every frame of
  /// a drag.
  Future<void> saveWindowSize(double width, double height) async {
    _apply(config.copyWith(windowWidth: width, windowHeight: height));
  }

  Future<void> addManual(
    String name,
    List<String> command, {
    String? cwd,
  }) async {
    // The name is the entry's identity (the game id is `manual:<name>`), so a
    // second entry under the same name would never reach the library and could
    // only be removed together with the first one.
    final entry = ManualEntry(name: name, command: command, cwd: cwd);
    final manual = List<ManualEntry>.from(config.manual);
    final index = manual.indexWhere((existing) => existing.name == name);
    if (index < 0) {
      manual.add(entry);
    } else {
      manual[index] = entry;
    }
    _apply(config.copyWith(manual: manual));
    await rescan();
    notice = 'Added $name';
    _notify();
  }

  Future<void> removeManual(String name) async {
    _apply(
      config.copyWith(
        manual: config.manual.where((entry) => entry.name != name).toList(),
      ),
    );
    await rescan();
    notice = 'Removed $name';
    _notify();
  }

  // --------------------------------------------------------------- cache

  /// The on-disk shape this build writes. A bare list from an older build
  /// still loads, so the cache survived the upgrade.
  static const int cacheVersion = 1;

  List<Game> _readCache() {
    final file = File(_cachePath);
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      final entries = decoded is Map && decoded['games'] is List
          ? decoded['games'] as List
          : decoded;
      if (entries is! List) return const [];
      return entries
          .whereType<Map>()
          .map((entry) => Game.fromJson(entry.cast<String, Object?>()))
          .whereType<Game>()
          .toList();
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  void _writeCache(List<Game> value) {
    try {
      final file = File(_cachePath);
      file.parent.createSync(recursive: true);
      // Through a sibling file and a rename: a crash halfway through writing
      // must not leave a half written cache behind.
      final temporary = File('$_cachePath.tmp');
      temporary.writeAsStringSync(
        jsonEncode({
          'version': cacheVersion,
          'games': value.map((game) => game.toJson()).toList(),
        }),
      );
      temporary.renameSync(_cachePath);
    } on FileSystemException {
      // The cache is only a fast start.
    }
  }
}
