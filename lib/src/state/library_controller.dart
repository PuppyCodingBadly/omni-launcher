import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../art/steamgriddb.dart';
import '../config.dart';
import '../covers.dart';
import '../launcher.dart';
import '../model/game.dart';
import '../model/launch_options.dart';
import '../paths.dart';
import '../plugins/bundled.dart';
import '../plugins/catalog.dart' as catalogue;
import '../plugins/plugin.dart';
import '../plugins/plugin_runner.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../util/log_tail.dart';
import '../util/proc.dart';
import '../util/search.dart';
import 'playtime_store.dart';
import 'plugin_store.dart';

enum LibraryStatus { loading, ready, failed }

/// Filters that are not tags: a property of the game itself.
enum SmartFilter {
  unplayed('Unplayed'),
  notRecent('Not played in 90 days'),
  noCover('No cover'),
  missing('Not installed');

  const SmartFilter(this.label);

  final String label;
}

/// A game that exited right after it started, kept so the panel and the page
/// can offer its log instead of silently calling the launch a success.
class LaunchExit {
  const LaunchExit({
    required this.gameId,
    required this.after,
    required this.at,
  });

  final String gameId;
  final Duration after;
  final DateTime at;
}

/// One watched process: the pid and the start tick that prove it is still the
/// process that was launched.
class _RunningGame {
  const _RunningGame(this.pid, this.startTick, {required this.tracked});

  final int pid;
  final int? startTick;

  /// False for a hand-off launcher whose exit says nothing about the game.
  final bool tracked;
}

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
    _adoptCachedArtPaths();
    this.covers.settings = ArtSettings.from(this.config);
  }

  final String _configPath;

  /// Where the last scan is remembered; the app's cache folder by default.
  final String _cachePath;

  /// Played time history. Tests inject a store pointed at a temporary file.
  final PlaytimeStore playtime;

  /// Sessions still being watched, by game id.
  final Map<String, Timer> _sessions = <String, Timer>{};

  /// Games running right now, by game id, with the process identity a stop
  /// has to check before signalling.
  final Map<String, _RunningGame> _running = <String, _RunningGame>{};

  /// Games the user asked to stop, so a quick exit after that is not reported
  /// as a crash.
  final Set<String> _stopping = <String>{};

  /// Games a launch is already being prepared for, so two quick clicks do not
  /// start the same game twice before its pid exists.
  final Set<String> _launching = <String>{};

  /// SIGKILL fallbacks for a stop that did not take effect.
  final Map<String, Timer> _stopTimers = <String, Timer>{};

  /// Recent launches that ended within [quickExitThreshold], by game id.
  final Map<String, Duration> _quickExits = <String, Duration>{};

  /// The latest quick exit, for the page's "View log" offer.
  LaunchExit? latestQuickExit;

  /// When the last scan finished, so a focus-rescan can skip a fresh library.
  DateTime? lastScan;

  /// Tags and smart filters applied to the wall. Source filters live in
  /// [sourceFilter]; these are session-only like it.
  final Set<String> tagFilter = <String>{};
  final Set<SmartFilter> smartFilters = <SmartFilter>{};

  /// Called with the game after it starts, so the window can step out of the
  /// way. The controller knows nothing about windows; `main` wires this to GTK.
  void Function(Game)? onGameStarted;

  /// Called with the game when a watched process is gone, so the window can
  /// come back if the user asked it to step aside.
  void Function(Game)? onGameEnded;

  /// A launch that exits sooner than this is reported with its log.
  static const Duration quickExitThreshold = Duration(seconds: 10);

  /// How long a stop waits for SIGTERM before SIGKILL.
  static const Duration stopGrace = Duration(seconds: 5);

  /// A focus-triggered rescan is skipped while the last one is this fresh.
  static const Duration autoRescanAge = Duration(seconds: 30);

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

  /// Games whose missing pin was already downloaded again this run: a pick
  /// that cannot be recovered must not cost a search per tile that shows it.
  final Set<String> _pinRecovered = <String>{};

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

  /// Plugin actions running right now, keyed plugin/action/game.
  final Set<String> _actionBusy = <String>{};

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
    final needle = query.trim();
    // One set for the whole pass: [config.favorites] is a list, and the loop
    // asks once per game.
    final favoriteIds = config.favorites.toSet();
    final favorites = <Game>[];
    final rest = <Game>[];
    final scores = <String, int>{};
    for (final game in games) {
      if (!config.showHidden && config.isHidden(game.id)) continue;
      if (sourceFilter.isNotEmpty && !sourceFilter.contains(game.source)) {
        continue;
      }
      if (!_matchesFilters(game)) continue;
      if (needle.isNotEmpty) {
        final score = gameSearchScore(game, needle, tags: tagsFor(game));
        if (score == null) continue;
        scores[game.id] = score;
      }
      (favoriteIds.contains(game.id) ? favorites : rest).add(game);
    }
    if (needle.isEmpty) {
      return [..._ordered(favorites), ..._ordered(rest)];
    }
    // Search results are ranked by the match; the wall's sort is the tie
    // breaker, so two equally good matches still read alphabetically.
    List<Game> ranked(List<Game> matched) {
      matched.sort((a, b) {
        final byScore = scores[b.id]!.compareTo(scores[a.id]!);
        return byScore != 0 ? byScore : _byName(a, b);
      });
      return matched;
    }

    return [...ranked(favorites), ...ranked(rest)];
  }

  /// Whether [game] passes the tag and smart filters.
  bool _matchesFilters(Game game) {
    if (tagFilter.isNotEmpty) {
      final tags = {for (final tag in tagsFor(game)) tag.toLowerCase()};
      for (final wanted in tagFilter) {
        if (!tags.contains(wanted.toLowerCase())) return false;
      }
    }
    for (final filter in smartFilters) {
      switch (filter) {
        case SmartFilter.unplayed:
          if (playtimeOf(game.id) > Duration.zero) return false;
        case SmartFilter.notRecent:
          final last = lastPlayedFor(game.id);
          if (last != null &&
              DateTime.now().difference(last) < const Duration(days: 90)) {
            return false;
          }
        case SmartFilter.noCover:
          if (covers.resolve(game).kind != ArtworkKind.letter) return false;
        case SmartFilter.missing:
          if (!game.missing) return false;
      }
    }
    return true;
  }

  /// The tags on [game]: the ones its source knows, then the user's own.
  ///
  /// A tag that both know is kept once, in the casing the source used.
  List<String> tagsFor(Game game) {
    final seen = <String>{};
    return [
      for (final tag in [...game.sourceTags, ...config.tagsFor(game.id)])
        if (seen.add(tag.toLowerCase())) tag,
    ];
  }

  /// Every tag on the wall, alphabetically, for the filter menu.
  List<String> get allTags {
    final byLower = <String, String>{};
    for (final game in games) {
      for (final tag in tagsFor(game)) {
        byLower.putIfAbsent(tag.toLowerCase(), () => tag);
      }
    }
    final tags = byLower.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return tags;
  }

  void toggleTag(String tag) {
    // Match regardless of casing: a source's "Action" and a click on "action"
    // are the same filter, not two entries that happen to look alike.
    final matches = <String>[
      for (final applied in tagFilter)
        if (applied.toLowerCase() == tag.toLowerCase()) applied,
    ];
    if (matches.isEmpty) {
      tagFilter.add(tag);
    } else {
      tagFilter.removeAll(matches);
    }
    notifyListeners();
  }

  void clearTags() {
    if (tagFilter.isEmpty) return;
    tagFilter.clear();
    notifyListeners();
  }

  void toggleSmartFilter(SmartFilter filter) {
    if (!smartFilters.remove(filter)) smartFilters.add(filter);
    notifyListeners();
  }

  void clearSmartFilters() {
    if (smartFilters.isEmpty) return;
    smartFilters.clear();
    notifyListeners();
  }

  /// Search the library without touching the wall's query: the command
  /// palette has a query of its own.
  List<Game> searchGames(String text, {int limit = 8}) {
    final needle = text.trim();
    if (needle.isEmpty) return const [];
    final scored = <(int, Game)>[];
    for (final game in games) {
      if (!config.showHidden && config.isHidden(game.id)) continue;
      final score = gameSearchScore(game, needle, tags: tagsFor(game));
      if (score != null) scored.add((score, game));
    }
    scored.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : _byName(a.$2, b.$2);
    });
    return [for (final (_, game) in scored.take(limit)) game];
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

  /// Rescan for a window focus, unless the library was just scanned.
  ///
  /// The page calls this when the window comes back; an install that finished
  /// while the launcher was behind the browser shows up without Ctrl+R. A
  /// scan already running collapses with this one, so the throttle is only
  /// about focus toggles.
  Future<void> rescanIfStale({Duration maxAge = autoRescanAge}) async {
    // A scan already running is this rescan's answer; queueing another behind
    // it would be work the focus did not ask for.
    final running = _rescan;
    if (running != null) {
      await running;
      return;
    }
    final at = lastScan;
    if (at != null && DateTime.now().difference(at) < maxAge) return;
    await rescan();
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
      // A game its source stopped offering is kept when it has history: the
      // playtime, favourite or tag is the user's, not the source's. It is
      // marked missing and can be forgotten from the detail panel.
      final foundIds = {for (final game in found) game.id};
      // A forgotten game that came back is no longer forgotten, so a later
      // uninstall keeps its history again.
      if (config.forgotten.any(foundIds.contains)) {
        _apply(
          config.copyWith(
            forgotten: config.forgotten
                .where((id) => !foundIds.contains(id))
                .toSet(),
          ),
        );
      }
      final kept = <Game>[
        for (final old in _discovered)
          if (!foundIds.contains(old.id) &&
              !config.isForgotten(old.id) &&
              (playtime.totalFor(old.id) > Duration.zero ||
                  config.favorites.contains(old.id) ||
                  config.tagsFor(old.id).isNotEmpty))
            old.copyWith(extra: const {'missing': true}),
      ];
      final merged = [...found, ...kept];
      _discovered = merged;
      games = applyNameOverrides(merged, config.nameOverrides);
      _writeCache(merged);
      failure = errors.isEmpty ? null : errors.join('; ');
      notice =
          '${found.length} games from ${countsBySource.length} sources'
          '${kept.isEmpty ? '' : ' · ${kept.length} kept from before'}';
    } catch (error) {
      failure = '$error';
    }
    status = LibraryStatus.ready;
    lastScan = DateTime.now();
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
    if (game.missing || game.broken) {
      notice = game.missing
          ? '${game.name} is not installed'
          : '${game.name}: files missing, repair it in Steam';
      _notify();
      return;
    }
    if (isRunning(game.id)) {
      notice = '${game.name} is already running';
      _notify();
      return;
    }
    if (!_launching.add(game.id)) {
      notice = '${game.name} is already starting';
      _notify();
      return;
    }
    try {
      _quickExits.remove(game.id);
      final hookErrors = await _runHooks(PluginHook.preLaunch, game);
      // The window may have gone while a hook ran; a disposed controller must
      // not start a process it can no longer watch.
      if (_disposed) return;
      final startedAt = DateTime.now();
      int? pid;
      String? launchFailure;
      try {
        pid = await Launcher.launch(
          game,
          options: config.launchOptionsFor(game.id),
        );
      } catch (error) {
        launchFailure = 'Could not launch ${game.name}: $error';
      }
      // The window may have gone while the process was starting; nothing can
      // watch it now, so no session and no window callback may follow.
      if (_disposed) return;
      if (launchFailure != null) {
        failure = launchFailure;
      } else if (hookErrors.isNotEmpty) {
        failure = hookErrors.join('; ');
      } else {
        // A launch that works clears an earlier failure (say a scan report),
        // so it does not resurface once the transient notice fades.
        failure = null;
      }
      if (pid != null) {
        notice = 'Launched ${game.name}';
        _watchSession(game, pid, startedAt);
        onGameStarted?.call(game);
      }
      _notify();
    } finally {
      _launching.remove(game.id);
    }
  }

  /// Whether [gameId]'s process is still running.
  bool isRunning(String gameId) => _running.containsKey(gameId);

  /// Whether the user asked [gameId] to stop and it has not exited yet.
  bool isStopping(String gameId) => _stopping.contains(gameId);

  /// Whether any tracked game is running right now.
  ///
  /// A hand-off launcher does not count: its exit is never reported, so it
  /// must not keep the window from coming back after a tracked game ends.
  bool get hasRunningGames => _running.values.any((game) => game.tracked);

  /// Ask [gameId] to stop: SIGTERM now, SIGKILL if it is still there after
  /// [stopGrace]. The session watcher ends playtime when the process goes.
  void stop(Game game) {
    final running = _running[game.id];
    if (running == null) return;
    final snapshot = processSnapshot(running.pid);
    final same =
        snapshot != null &&
        snapshot.running &&
        (running.startTick == null || snapshot.startTime == running.startTick);
    if (!same) {
      // The pid is gone or belongs to another process now. There is nothing
      // to signal, and no "Stopping…" may be left behind for a game that is
      // already gone.
      _running.remove(game.id);
      _stopping.remove(game.id);
      _stopTimers.remove(game.id)?.cancel();
      notifyListeners();
      return;
    }
    _stopping.add(game.id);
    Process.killPid(running.pid, ProcessSignal.sigterm);
    notice = 'Stopping ${game.name}…';
    _stopTimers.remove(game.id)?.cancel();
    _stopTimers[game.id] = Timer(stopGrace, () {
      _stopTimers.remove(game.id);
      final latest = processSnapshot(running.pid);
      if (latest != null &&
          latest.running &&
          (running.startTick == null ||
              latest.startTime == running.startTick)) {
        Process.killPid(running.pid, ProcessSignal.sigkill);
      }
    });
    notifyListeners();
  }

  /// [game]'s effective argv, with the user's launch options folded in.
  String commandFor(Game game) =>
      Launcher.formatCommand(game, options: config.launchOptionsFor(game.id));

  /// The last logged output for [game], or the tail of the log when the game
  /// has no line yet.
  String? launchLogFor(Game game) =>
      readLogTail(Launcher.logPath, gameId: game.id);

  /// How long ago [gameId] exited after a quick launch, when it did.
  Duration? quickExitFor(String gameId) => _quickExits[gameId];

  /// The store page for [game], when its source has one.
  String? storeUrl(Game game) {
    if (game.source != SourceKind.steam) return null;
    final appid = '${game.extra['appid'] ?? game.key}';
    if (appid.isEmpty) return null;
    return 'https://store.steampowered.com/app/$appid';
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

  /// Whether [game]'s launched process is the game itself.
  ///
  /// `steam -applaunch` and the `xdg-open`/`gtk-launch` shims exit as soon as
  /// they have asked something else to start the game. Treating that exit as
  /// the game's would fake a quick exit, run the post-exit hooks early and
  /// bring the window back while the game is still starting.
  static bool tracksProcess(Game game) {
    if (game.command.isEmpty) return true;
    final program = game.command.first;
    final slash = program.lastIndexOf('/');
    final name = slash < 0 ? program : program.substring(slash + 1);
    if (name == 'xdg-open' || name == 'gtk-launch') return false;
    return !game.command.contains('-applaunch');
  }

  /// Follow a launched game's pid so its session ends when the game does.
  ///
  /// `Launcher` starts the game detached with `exec`, so [pid] is the game's
  /// own. The session always ends at the last moment the process was seen: a
  /// game that exits between two checks is never credited with the gap.
  ///
  /// The same poll asks a launcher window to close when the game it started is
  /// gone (see [shouldCloseLauncher]) — a launcher that ignores the request
  /// simply stays open.
  void _watchSession(Game game, int pid, DateTime startedAt) {
    final gameId = game.id;
    _sessions.remove(gameId)?.cancel();
    playtime.begin(gameId, startedAt);
    // Identifies the process we started: a recycled pid must never be signalled.
    final startTick = processStartTime(pid);
    _running[gameId] = _RunningGame(
      pid,
      startTick,
      tracked: tracksProcess(game),
    );
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
        _running.remove(gameId);
        _stopTimers.remove(gameId)?.cancel();
        final stopped = _stopping.remove(gameId);
        playtime.end(gameId, lastSeen);
        // A hand-off launcher's exit says nothing about the game: it must not
        // fake a quick exit, run the post-exit hooks early, or bring the
        // window back while the game it handed over to is still starting.
        if (tracksProcess(game)) {
          final after = lastSeen.difference(startedAt);
          if (!stopped && after < quickExitThreshold) {
            _quickExits[gameId] = after;
            latestQuickExit = LaunchExit(
              gameId: gameId,
              after: after,
              at: DateTime.now(),
            );
          }
          unawaited(_runHooks(PluginHook.postExit, game));
          onGameEnded?.call(game);
        }
        _notify();
        return;
      }
      lastSeen = now;
      if (shouldTouch(lastTouched, now)) {
        lastTouched = now;
        playtime.touch(gameId, now);
        // The heartbeat moved the totals; the detail panel and the shelf
        // follow the session live rather than freezing until it ends.
        _notify();
      }
      if (asked) return;
      // Walking /proc on every tick is only needed to decide when a game
      // launcher has outlived its game; a plain session just polls the pid.
      if (!config.closesWithGame(game.source)) return;
      if (descendants(pid).isEmpty) {
        quietTicks++;
      } else {
        // The launcher has its game running; losing it later means the game is
        // over.
        sawDescendants = true;
        quietTicks = 0;
      }
      if (shouldCloseLauncher(
        closeWithGame: config.closesWithGame(game.source),
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
    for (final timer in _stopTimers.values) {
      timer.cancel();
    }
    _stopTimers.clear();
    _running.clear();
    _stopping.clear();
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

  /// Rewrite artwork paths that point into an old cache folder.
  ///
  /// Artwork used to be stored under `~/.cache/omnilauncher-flutter/covers`;
  /// it lives with the launcher's data now, because cache folders are emptied
  /// by updates and cleanups and a picked grid cannot always be found again.
  /// A file that is still on disk is copied across, so the pick keeps showing
  /// with nothing re-downloaded.
  void _adoptCachedArtPaths() {
    Map<String, String> rehomed(Map<String, String> paths) => {
      for (final entry in paths.entries)
        entry.key: AppPaths.rehomeCover(entry.value),
    };
    final overrides = rehomed(config.artOverrides);
    final autoArt = rehomed(config.autoArt);
    bool differs(Map<String, String> a, Map<String, String> b) {
      if (a.length != b.length) return true;
      for (final entry in a.entries) {
        if (b[entry.key] != entry.value) return true;
      }
      return false;
    }

    if (!differs(overrides, config.artOverrides) &&
        !differs(autoArt, config.autoArt)) {
      return;
    }
    _apply(config.copyWith(artOverrides: overrides, autoArt: autoArt));
  }

  /// Artwork for a tile: Steam CDN first, then SteamGridDB when enabled.
  ///
  /// A SteamGridDB pick is remembered in the config so it survives rescans,
  /// and its grid id is remembered with it, so a pick whose file was deleted
  /// is downloaded again instead of being forgotten.
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
    final pinnedPath = covers.pinnedArtPath(game);
    if (pinnedPath != null && _pinRecovered.add(game.id)) {
      final recovered = await covers.refetchPinned(game);
      if (recovered != null) {
        // The download may land in the cover folder's new home: keep the pin
        // pointing at the file that is actually there.
        if (recovered.value != null && recovered.value != pinnedPath) {
          _apply(
            config.copyWith(
              artOverrides: {...config.artOverrides, game.id: recovered.value!},
            ),
          );
        }
        return recovered;
      }
      // The grid could not be fetched this time (offline, or it is gone). The
      // pin stays, and the automatic sources cover the tile meanwhile.
    }
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
    var installedOk = false;
    try {
      await catalogue.installPlugin(
        entry,
        dir: _pluginDir,
        read: _pluginReader,
      );
      installedOk = true;
      notice = 'Installed ${entry.name}';
    } on catalogue.PluginStoreException catch (error) {
      failure = '${entry.name}: ${error.message}';
    } catch (error) {
      failure = '${entry.name}: $error';
    }
    _pluginBusy.remove(entry.id);
    await reloadPlugins();
    // Lookup is what a plugin has always been allowed to do; actions and
    // launch hooks are the user's decision, made from its permissions after
    // the manifest is on disk to show them. Only a fresh install seeds it: an
    // update keeps the grants the user already decided, and a failed install
    // changes nothing.
    final installed = plugin(entry.id);
    if (installedOk &&
        installed != null &&
        !config.pluginGrants.containsKey(installed.id)) {
      _apply(
        config.copyWith(
          pluginGrants: {
            ...config.pluginGrants,
            installed.id: {
              if (installed.has(PluginCapability.lookup))
                PluginCapability.lookup.id,
            },
          },
        ),
      );
    }
    _notify();
  }

  /// Remove the installed [plugin].
  Future<void> removePlugin(Plugin plugin) async {
    if (!_pluginBusy.add(plugin.id)) return;
    notice = 'Removing ${plugin.name}…';
    notifyListeners();
    var removedOk = false;
    try {
      await catalogue.removePlugin(plugin.id, dir: _pluginDir);
      removedOk = true;
      notice = 'Removed ${plugin.name}';
    } on catalogue.PluginStoreException catch (error) {
      failure = '${plugin.name}: ${error.message}';
    } catch (error) {
      failure = '${plugin.name}: $error';
    }
    _pluginBusy.remove(plugin.id);
    await reloadPlugins();
    // A removed plugin's permissions go with it; a later install asks again.
    // A failed removal leaves them alone: the plugin is still installed.
    if (removedOk && config.pluginGrants.containsKey(plugin.id)) {
      final grants = {...config.pluginGrants}..remove(plugin.id);
      _apply(config.copyWith(pluginGrants: grants));
    }
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

  /// The same round trip for an action or a hook; split out for tests.
  Future<PluginAnswer> askPluginRequest(
    Plugin plugin,
    Map<String, Object?> request, {
    bool requireAnswer = true,
  }) => runPluginRequest(plugin, request, requireAnswer: requireAnswer);

  /// The capabilities of [plugin] the user allowed.
  Set<PluginCapability> grantedCapabilities(Plugin plugin) {
    final grants = config.pluginGrantsFor(plugin.id);
    return {
      for (final capability in plugin.capabilities)
        if (grants.contains(capability.id)) capability,
    };
  }

  /// Whether [plugin] may use [capability]: declared and granted.
  bool pluginGranted(Plugin plugin, PluginCapability capability) =>
      plugin.has(capability) &&
      config.pluginGrantsFor(plugin.id).contains(capability.id);

  /// Whether [plugin] has anything to show in the detail panel.
  bool pluginHasSection(Plugin plugin) =>
      pluginGranted(plugin, PluginCapability.lookup) ||
      (pluginGranted(plugin, PluginCapability.actions) &&
          plugin.actions.isNotEmpty);

  /// Allow or refuse one of [plugin]'s declared capabilities.
  void setPluginGrant(
    Plugin plugin,
    PluginCapability capability,
    bool allowed,
  ) {
    if (!plugin.has(capability)) return;
    final grants = <String>{
      for (final current in config.pluginGrantsFor(plugin.id))
        if (current != capability.id) current,
      if (allowed) capability.id,
    };
    _apply(
      config.copyWith(
        pluginGrants: {...config.pluginGrants, plugin.id: grants},
      ),
    );
    notice = allowed
        ? '${plugin.name}: ${capability.label.toLowerCase()} allowed'
        : '${plugin.name}: ${capability.label.toLowerCase()} refused';
    notifyListeners();
  }

  /// Whether [action] is running for [game] right now.
  bool isPluginActionRunning(Plugin plugin, PluginAction action, Game game) =>
      _actionBusy.contains(
        PluginStore.keyFor(plugin.id, '${action.id}/${game.id}'),
      );

  /// Run one of [plugin]'s actions on [game], and return what it answered.
  ///
  /// The answer is not cached: an action changes something, and a stale
  /// result would lie about it. Failures are answers too.
  Future<PluginAnswer?> runPluginAction(
    Plugin plugin,
    PluginAction action,
    Game game,
  ) async {
    if (!pluginGranted(plugin, PluginCapability.actions)) {
      return PluginAnswer.failure(
        '${plugin.name} does not have permission to run actions',
      );
    }
    final key = PluginStore.keyFor(plugin.id, '${action.id}/${game.id}');
    if (!_actionBusy.add(key)) return null;
    notice = '${plugin.name}: ${action.name}…';
    notifyListeners();
    PluginAnswer answer;
    try {
      answer = await askPluginRequest(plugin, {
        'action': 'action',
        'id': action.id,
        'name': action.name,
        'game': _pluginGame(game),
      });
    } catch (error) {
      answer = PluginAnswer.failure('${plugin.name}: $error');
    } finally {
      _actionBusy.remove(key);
    }
    if (answer.ok) {
      failure = null;
      notice = '${plugin.name}: ${action.name} finished';
    } else {
      failure = answer.error;
    }
    _notify();
    return answer;
  }

  /// The game shape a plugin receives, including the user's own tags.
  Map<String, Object?> _pluginGame(Game game) => {
    'id': game.id,
    'key': game.key,
    'name': game.name,
    'source': game.source.id,
    'path': game.path,
    'cwd': game.cwd,
    'command': game.command,
    'extra': game.extra,
    'tags': tagsFor(game),
  };

  /// Call every plugin that declared [hook] and may use hooks.
  ///
  /// Hooks never throw: one plugin's failure is reported and the others still
  /// run. A pre-launch failure is returned so the launch can say it happened;
  /// a post-exit one is reported in the status bar.
  Future<List<String>> _runHooks(PluginHook hook, Game game) async {
    final errors = <String>[];
    for (final plugin in plugins) {
      if (!plugin.hooks.contains(hook) ||
          !pluginGranted(plugin, PluginCapability.hooks)) {
        continue;
      }
      try {
        final answer = await askPluginRequest(plugin, {
          'action': hook.id,
          'game': _pluginGame(game),
        }, requireAnswer: false);
        if (!answer.ok) {
          errors.add('${plugin.name}: ${answer.error ?? 'hook failed'}');
        }
      } catch (error) {
        errors.add('${plugin.name}: $error');
      }
    }
    if (hook == PluginHook.postExit && errors.isNotEmpty) {
      _reportHookErrors(errors);
    }
    return errors;
  }

  void _reportHookErrors(List<String> errors) {
    if (errors.isEmpty) return;
    failure = errors.join('; ');
    notice = 'Plugin hook failed';
    _notify();
  }

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

  /// Whether the launcher behind [source] should close when its game exits.
  ///
  /// Only a game launcher client can be closed this way; a direct source has
  /// no launcher window to name.
  void setCloseWithGame(SourceKind source, bool value) {
    if (!source.isLauncher) return;
    final ids = {...config.closeWithGame};
    if (value) {
      ids.add(source.id);
    } else {
      ids.remove(source.id);
    }
    _apply(config.copyWith(closeWithGame: ids));
    notice = value
        ? '${source.label} closes with its game'
        : '${source.label} stays open';
    notifyListeners();
  }

  /// Replace the user's tags for [gameId]. Blank tags and duplicates (by
  /// letter case) are dropped before saving.
  void setTags(String gameId, List<String> tags) {
    final seen = <String>{};
    final cleaned = <String>[
      for (final tag in tags)
        if (tag.trim().isNotEmpty && seen.add(tag.trim().toLowerCase()))
          tag.trim(),
    ];
    final map = {...config.tags};
    if (cleaned.isEmpty) {
      map.remove(gameId);
    } else {
      map[gameId] = cleaned;
    }
    _apply(config.copyWith(tags: map));
    notice = cleaned.isEmpty ? 'Tags cleared' : 'Tags saved';
    notifyListeners();
  }

  /// Replace [gameId]'s launch options; an empty set removes the entry.
  void setLaunchOptions(String gameId, LaunchOptions options) {
    final map = {...config.launchOptions};
    if (options.isEmpty) {
      map.remove(gameId);
    } else {
      map[gameId] = options;
    }
    _apply(config.copyWith(launchOptions: map));
    notice = options.isEmpty
        ? 'Launch options cleared'
        : 'Launch options saved';
    notifyListeners();
  }

  /// Remove a missing [game] from the library for good, with its history.
  void forget(Game game) {
    if (!game.missing) return;
    _apply(config.copyWith(forgotten: {...config.forgotten, game.id}));
    _discovered = [
      for (final entry in _discovered)
        if (entry.id != game.id) entry,
    ];
    games = [
      for (final entry in games)
        if (entry.id != game.id) entry,
    ];
    if (selected?.id == game.id) selected = null;
    _writeCache(_discovered);
    notice = 'Removed ${game.name} from the library';
    notifyListeners();
  }

  void setMinimizeOnLaunch(bool value) {
    _apply(config.copyWith(minimizeOnLaunch: value));
    notifyListeners();
  }

  void setTrayIcon(bool value) {
    _apply(config.copyWith(trayIcon: value));
    notifyListeners();
  }

  /// Open [game]'s store page, when its source has one.
  Future<void> openStore(Game game) async {
    final url = storeUrl(game);
    if (url == null) {
      notice = '${game.name} has no store page';
      notifyListeners();
      return;
    }
    await openUrl(url);
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
