import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/art/steamgriddb.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/covers.dart';
import 'package:omni_launcher/src/launcher.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/model/launch_options.dart';
import 'package:omni_launcher/src/plugins/plugin.dart';
import 'package:omni_launcher/src/plugins/plugin_runner.dart';
import 'package:omni_launcher/src/sources/source.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/state/plugin_store.dart';

Game game(String id, String name, SourceKind source) => Game(
  id: id,
  key: id.split(':').last,
  name: name,
  source: source,
  command: const ['true'],
);

void main() {
  late Directory dir;
  late String configPath;
  late LibraryController controller;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-controller');
    configPath = '${dir.path}/config.json';
    controller =
        LibraryController(
            configPath: configPath,
            config: AppConfig(hidden: {'steam:2'}),
          )
          ..games = [
            game('steam:1', 'Alpha', SourceKind.steam),
            game('steam:2', 'Beta', SourceKind.steam),
            game('flatpak:gamma', 'Gamma', SourceKind.flatpak),
          ];
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('hidden games are filtered out unless they are shown', () {
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'steam:1',
      'flatpak:gamma',
    ]);

    controller.toggleShowHidden();
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'steam:1',
      'steam:2',
      'flatpak:gamma',
    ]);
    expect(AppConfig.load(configPath).showHidden, isTrue);
  });

  test('the query matches name, id and subtitle', () {
    controller.setQuery('gamm');
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'flatpak:gamma',
    ]);

    controller.setQuery('steam:1');
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'steam:1',
    ]);

    controller.setQuery('flatpak');
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'flatpak:gamma',
    ]);

    controller.setQuery('nothing-here');
    expect(controller.visibleGames, isEmpty);
  });

  test('search ranks an acronym and reaches tags', () {
    controller.games = [
      game('steam:1', 'Team Fortress 2', SourceKind.steam).copyWith(
        extra: const {
          'tags': ['Shooter'],
        },
      ),
      game('steam:3', 'Accounting', SourceKind.steam),
    ];

    expect(controller.searchGames('tf2').map((entry) => entry.name).toList(), [
      'Team Fortress 2',
    ]);
    // Subsequence and tags both count.
    expect(
      controller.searchGames('accntg').map((entry) => entry.name).toList(),
      ['Accounting'],
    );
    expect(
      controller.searchGames('shooter').map((entry) => entry.name).toList(),
      ['Team Fortress 2'],
    );
    expect(controller.searchGames('  '), isEmpty);
  });

  test('tags merge source and user tags, and filter the wall', () {
    controller.games = [
      game('steam:1', 'Alpha', SourceKind.steam).copyWith(
        extra: const {
          'tags': ['Action'],
        },
      ),
      game('steam:3', 'Beta', SourceKind.steam),
    ];

    controller.setTags('steam:3', ['Puzzle', 'puzzle']);
    expect(controller.tagsFor(controller.games[1]), ['Puzzle']);
    expect(controller.allTags, ['Action', 'Puzzle']);

    controller.toggleTag('Action');
    expect(controller.visibleGames.map((entry) => entry.id), ['steam:1']);

    controller.toggleTag('Action');
    controller.toggleTag('Puzzle');
    expect(controller.visibleGames.map((entry) => entry.id), ['steam:3']);
    expect(AppConfig.load(configPath).tagsFor('steam:3'), ['Puzzle']);

    // Search matches the tags too.
    controller.clearTags();
    controller.setQuery('puzzle');
    expect(controller.visibleGames.map((entry) => entry.id), ['steam:3']);
  });

  test('smart filters read playtime and missing state', () {
    // Its own controller with a temporary playtime file: the setUp one would
    // write the real ~/.local/state history.
    final local = LibraryController(
      configPath: configPath,
      playtime: PlaytimeStore(path: '${dir.path}/smart-playtime.json'),
      config: AppConfig(),
    );
    addTearDown(local.dispose);
    final played = game('steam:1', 'Alpha', SourceKind.steam);
    final missing = game(
      'steam:3',
      'Beta',
      SourceKind.steam,
    ).copyWith(extra: const {'missing': true});
    local.games = [played, missing];
    final at = DateTime(2026, 1, 1);
    local.playtime.begin(played.id, at);
    local.playtime.end(played.id, at.add(const Duration(hours: 1)));

    local.toggleSmartFilter(SmartFilter.unplayed);
    expect(local.visibleGames.map((entry) => entry.id), ['steam:3']);

    local.toggleSmartFilter(SmartFilter.unplayed);
    local.toggleSmartFilter(SmartFilter.missing);
    expect(local.visibleGames.map((entry) => entry.id), ['steam:3']);
  });

  test('tracksProcess tells hand-off launchers from the game itself', () {
    Game withCommand(List<String> command) => Game(
      id: 'steam:1',
      key: '1',
      name: 'Alpha',
      source: SourceKind.steam,
      command: command,
    );

    // Steam's hand-off exits once the real game is started.
    expect(
      LibraryController.tracksProcess(
        withCommand(const ['/usr/bin/steam', '-applaunch', '1']),
      ),
      isFalse,
    );
    // The desktop-portal shims do the same.
    expect(
      LibraryController.tracksProcess(
        withCommand(const ['/usr/bin/xdg-open', 'steam://run/1']),
      ),
      isFalse,
    );
    // A command that is the game stays watched.
    expect(
      LibraryController.tracksProcess(
        withCommand(const ['/bin/sh', '-c', 'true']),
      ),
      isTrue,
    );
  });

  test('launch options are stored per game and removed when empty', () {
    controller.setLaunchOptions(
      'steam:1',
      const LaunchOptions(wrapper: ['gamemoderun'], env: {'FOO': 'bar'}),
    );
    expect(controller.config.launchOptionsFor('steam:1').wrapper, [
      'gamemoderun',
    ]);
    expect(
      controller.commandFor(controller.visibleGames.first),
      contains('gamemoderun'),
    );

    controller.setLaunchOptions('steam:1', const LaunchOptions());
    expect(controller.config.launchOptionsFor('steam:1').isEmpty, isTrue);
    expect(AppConfig.load(configPath).launchOptions, isEmpty);
  });

  test('source filters toggle on and off', () {
    controller.toggleSource(SourceKind.steam);
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'steam:1',
    ]);

    controller.toggleSource(SourceKind.flatpak);
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'steam:1',
      'flatpak:gamma',
    ]);

    controller.toggleSource(SourceKind.steam);
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'flatpak:gamma',
    ]);

    controller.clearSources();
    expect(controller.visibleGames, hasLength(2));
  });

  test('hiding a game persists and updates the counts', () {
    final gamma = controller.games.last;
    controller.setHidden(gamma, hidden: true);
    expect(controller.hiddenCount, 2);
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'steam:1',
    ]);
    expect(AppConfig.load(configPath).hidden, {'steam:2', 'flatpak:gamma'});

    controller.setHidden(gamma, hidden: false);
    expect(controller.hiddenCount, 1);
    expect(controller.visibleGames, hasLength(2));
  });

  test('opening a folder the game does not have is a failure', () async {
    final game = controller.games.first;
    await controller.openFolder(game);

    expect(controller.failure, contains('no folder known'));
  });

  test('a favorite is persisted and comes first', () async {
    final gamma = controller.games.last;
    await controller.toggleFavorite(gamma.id);

    expect(controller.isFavorite(gamma.id), isTrue);
    expect(controller.visibleGames.first.id, gamma.id);
    expect(AppConfig.load(configPath).favorites, contains(gamma.id));

    await controller.toggleFavorite(gamma.id);
    expect(controller.isFavorite(gamma.id), isFalse);
    expect(AppConfig.load(configPath).favorites, isNot(contains(gamma.id)));
  });

  test('pinned artwork survives a reload and wins over the icon', () {
    final gamma = controller.games.last;
    final art = File('${dir.path}/art.png')..writeAsBytesSync([1, 2, 3]);
    AppConfig(artOverrides: {gamma.id: art.path}).save(configPath);

    final reloaded = LibraryController(configPath: configPath);
    expect(reloaded.covers.overrideFor(gamma), art.path);
    expect(reloaded.covers.resolve(gamma).kind, ArtworkKind.cover);
  });

  test('a missing pinned file falls back to the automatic artwork', () {
    final gamma = controller.games.last;
    AppConfig(artOverrides: {gamma.id: '${dir.path}/gone.png'})
        .save(configPath);
    final reloaded = LibraryController(configPath: configPath);
    expect(reloaded.covers.overrideFor(gamma), isNull);
    expect(reloaded.covers.resolve(gamma).kind, ArtworkKind.letter);
  });

  test('no artwork is requested when both sources are off', () async {
    final off = LibraryController(
      configPath: configPath,
      config: AppConfig(
        coverFetch: false,
        steamgriddbKey: '',
        steamgriddbAuto: false,
      ),
    );
    expect(
      await off.requestCoverArt(game('flatpak:x', 'X', SourceKind.flatpak)),
      isNull,
    );
    expect(
      await off.searchArt(game('flatpak:x', 'X', SourceKind.flatpak)),
      isEmpty,
    );
  });

  group('fetched artwork', () => _fetchedArtTests(() => dir));

  test('source counts follow the library', () {
    expect(controller.countsBySource, {
      SourceKind.steam: 2,
      SourceKind.flatpak: 1,
    });
  });

  group('scanning', () {
    LibraryController scanning(List<GameSource> sources) => LibraryController(
      configPath: configPath,
      cachePath: '${dir.path}/games.json',
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      config: AppConfig(appimageDirs: const []),
      sources: sources,
    );

    test(
      'a source that fails is reported, and the rest arrives anyway',
      () async {
        final broken = _ThrowingSource(
          SourceKind.flatpak,
          StateError('no permission'),
        );
        final also = _ThrowingSource(SourceKind.epic, StateError('gone'));
        final controller = scanning([
          _FixedSource(SourceKind.steam, [
            game('steam:1', 'Alpha', SourceKind.steam),
          ]),
          broken,
          also,
        ]);
        addTearDown(controller.dispose);

        await controller.rescan();

        expect(controller.status, LibraryStatus.ready);
        expect(controller.games.map((entry) => entry.id).toList(), ['steam:1']);
        // Every broken source is named, not just the last one asked.
        expect(controller.failure, contains('Flatpak'));
        expect(controller.failure, contains('no permission'));
        expect(controller.failure, contains('Epic Games Launcher'));
        expect(controller.failure, contains('gone'));

        // A clean scan clears the report.
        broken.error = null;
        also.error = null;
        await controller.rescan();
        expect(controller.failure, isNull);
      },
    );

    test('the cache is versioned, and a bare list still loads', () async {
      final path = '${dir.path}/games.json';
      File(path).writeAsStringSync(
        jsonEncode([game('steam:9', 'Old', SourceKind.steam).toJson()]),
      );
      final controller = scanning([
        _FixedSource(SourceKind.steam, [
          game('steam:1', 'Alpha', SourceKind.steam),
        ]),
      ]);
      addTearDown(controller.dispose);

      // The old bare-list format still starts the wall.
      await controller.load(refresh: false);
      expect(controller.games.map((entry) => entry.id).toList(), ['steam:9']);

      // A scan writes the versioned envelope.
      await controller.rescan();
      final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(decoded['version'], LibraryController.cacheVersion);
      expect((decoded['games'] as List).single['id'], 'steam:1');
      expect(File('$path.tmp').existsSync(), isFalse);
    });

    test('a rescan during a rescan folds into one trailing scan', () async {
      final source = _GatedSource();
      final controller = scanning([source]);
      addTearDown(controller.dispose);

      final first = controller.rescan();
      expect(source.calls, 1);
      // Three asks while the gate is shut are one trailing scan, not three.
      final second = controller.rescan();
      final third = controller.rescan();
      source.gates.single.complete();
      await untilTrue(() => source.calls == 2);
      source.gates.last.complete();
      await Future.wait([first, second, third]);

      expect(source.calls, 2);
      expect(controller.status, LibraryStatus.ready);
    });

    test(
      'the selection survives a scan by id, and clears when the game goes',
      () async {
        final source = _FixedSource(SourceKind.steam, [
          game('steam:1', 'Alpha', SourceKind.steam),
          game('steam:2', 'Beta', SourceKind.steam),
        ]);
        final controller = scanning([source]);
        addTearDown(controller.dispose);
        await controller.rescan();

        controller.select(
          controller.games.firstWhere((entry) => entry.id == 'steam:1'),
        );
        await controller.rescan();
        expect(controller.selected?.id, 'steam:1');

        source.games = [game('steam:2', 'Beta', SourceKind.steam)];
        await controller.rescan();
        expect(controller.selected, isNull);
      },
    );
  });

  group('ordering', () {
    /// A controller over four games: two played (one long ago and much, one
    /// recently and little), one played as recently and as little as the
    /// second, and one never played at all.
    LibraryController ordered({AppConfig? config}) {
      File('${dir.path}/playtime.json').writeAsStringSync(
        jsonEncode({
          'steam:1': {
            'total': 3600,
            'played': DateTime(2026, 10, 14, 9).millisecondsSinceEpoch,
          },
          'steam:2': {
            'total': 60,
            'played': DateTime(2026, 10, 15, 9).millisecondsSinceEpoch,
          },
          'desktop:delta': {
            'total': 60,
            'played': DateTime(2026, 10, 15, 9).millisecondsSinceEpoch,
          },
        }),
      );
      return LibraryController(
          configPath: configPath,
          cachePath: '${dir.path}/games.json',
          playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
          config: config ?? AppConfig(appimageDirs: const []),
        )
        ..games = [
          game('flatpak:gamma', 'Gamma', SourceKind.flatpak),
          game('desktop:delta', 'Delta', SourceKind.desktop),
          game('steam:2', 'beta', SourceKind.steam),
          game('steam:1', 'Alpha', SourceKind.steam),
        ];
    }

    List<String> ids(LibraryController controller) =>
        controller.visibleGames.map((entry) => entry.id).toList();

    test('by name, case-insensitive, is the default', () {
      final controller = ordered();
      addTearDown(controller.dispose);

      expect(controller.sortMode, 'name');
      expect(ids(controller), [
        'steam:1',
        'steam:2',
        'desktop:delta',
        'flatpak:gamma',
      ]);
    });

    test('by last played, never played last, ties by name', () async {
      final controller = ordered(config: AppConfig(sortMode: 'lastPlayed'));
      addTearDown(controller.dispose);

      // beta and Delta played at the same moment, so the name decides.
      expect(ids(controller), [
        'steam:2',
        'desktop:delta',
        'steam:1',
        'flatpak:gamma',
      ]);
    });

    test('by most played, nothing played last, ties by name', () async {
      final controller = ordered(config: AppConfig(sortMode: 'mostPlayed'));
      addTearDown(controller.dispose);

      // beta and Delta both played a minute, so the name decides.
      expect(ids(controller), [
        'steam:1',
        'steam:2',
        'desktop:delta',
        'flatpak:gamma',
      ]);
    });

    test('favourites come first, ordered among themselves', () async {
      final controller = ordered(
        config: AppConfig(
          sortMode: 'lastPlayed',
          favorites: ['flatpak:gamma', 'steam:2'],
        ),
      );
      addTearDown(controller.dispose);

      // Gamma never played still leads, as a favourite; behind the favourites
      // the last played order is untouched.
      expect(ids(controller), [
        'steam:2',
        'flatpak:gamma',
        'desktop:delta',
        'steam:1',
      ]);
    });

    test('the sort mode persists and re-orders the wall', () async {
      final controller = ordered();
      addTearDown(controller.dispose);

      await controller.setSortMode('lastPlayed');
      expect(controller.sortMode, 'lastPlayed');
      expect(ids(controller).first, 'steam:2');
      expect(AppConfig.load(configPath).sortMode, 'lastPlayed');

      // An unknown mode is refused, not saved.
      await controller.setSortMode('random');
      expect(controller.sortMode, 'lastPlayed');
      expect(AppConfig.load(configPath).sortMode, 'lastPlayed');
    });

    test('a favourite persists through a reload', () async {
      final controller = ordered();
      addTearDown(controller.dispose);

      expect(controller.isFavorite('steam:1'), isFalse);
      await controller.toggleFavorite('steam:1');
      expect(controller.isFavorite('steam:1'), isTrue);
      expect(AppConfig.load(configPath).favorites, ['steam:1']);

      final reloaded = LibraryController(
        configPath: configPath,
        cachePath: '${dir.path}/games.json',
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      )..games = controller.games;
      addTearDown(reloaded.dispose);
      expect(reloaded.isFavorite('steam:1'), isTrue);
      expect(reloaded.visibleGames.first.id, 'steam:1');

      await reloaded.toggleFavorite('steam:1');
      expect(reloaded.isFavorite('steam:1'), isFalse);
      expect(AppConfig.load(configPath).favorites, isEmpty);
    });
  });

  group('notices', () {
    test(
      'a notice clears itself, and a new one reschedules the clear',
      () async {
        final controller = LibraryController(
          configPath: configPath,
          config: AppConfig(),
          noticeDuration: const Duration(milliseconds: 200),
        );
        addTearDown(controller.dispose);
        var clears = 0;
        controller.addListener(() {
          if (controller.notice == null) clears++;
        });

        controller.announce('one');
        expect(controller.notice, 'one');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        // A new notice pushes the clear back: 'one' would be gone by now.
        controller.announce('two');
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(controller.notice, 'two');

        await untilTrue(() => controller.notice == null);
        expect(controller.notice, isNull);
        expect(clears, greaterThan(0));
      },
    );
  });

  test('a failed launch is a failure, not a notice', () async {
    final controller = LibraryController(
      configPath: configPath,
      config: AppConfig(),
    );
    addTearDown(controller.dispose);
    const gone = Game(
      id: 'manual:gone',
      key: 'gone',
      name: 'Gone',
      source: SourceKind.manual,
      command: ['definitely-not-a-program-xyz'],
    );

    await controller.launch(gone);

    expect(controller.failure, contains('Could not launch Gone'));
    expect(controller.notice, isNull);
  });

  test(
    'a lookup that throws is reported, and the guard still clears',
    () async {
      final controller = _FailingLookupController(
        configPath: configPath,
        cachePath: '${dir.path}/games.json',
        config: AppConfig(appimageDirs: const []),
        pluginAnswers: PluginStore(path: '${dir.path}/answers.json'),
      );
      addTearDown(controller.dispose);
      const plugin = Plugin(
        id: 'beat',
        name: 'Beat',
        description: '',
        action: 'Ask',
        command: ['true'],
        dir: '/tmp',
      );
      final query = PluginQuery.byName('Alpha');

      await controller.lookUp(plugin, query);

      expect(controller.failure, contains('boom'));
      expect(controller.isLookingUp(plugin.id, query.id), isFalse);

      // The guard cleared: asking again really asks again.
      await controller.lookUp(plugin, query);
      expect(controller.pluginAnswer(plugin.id, query.id)?.ok, isTrue);
      // And the success cleared the earlier failure instead of letting it
      // resurface once the transient notice fades.
      expect(controller.failure, isNull);
    },
  );

  test('the window size is saved without repainting', () async {
    final controller = LibraryController(
      configPath: configPath,
      config: AppConfig(),
    );
    addTearDown(controller.dispose);
    var repaints = 0;
    controller.addListener(() => repaints++);

    await controller.saveWindowSize(1440, 900);

    expect(repaints, 0);
    expect(controller.config.windowWidth, 1440);
    expect(controller.config.windowHeight, 900);
    final saved = AppConfig.load(configPath);
    expect(saved.windowWidth, 1440);
    expect(saved.windowHeight, 900);
  });

  test('a successful launch clears an earlier failure', () async {
    Launcher.logPathOverrideForTest = '${dir.path}/launch.log';
    addTearDown(() => Launcher.logPathOverrideForTest = null);
    final controller = LibraryController(
      configPath: configPath,
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      config: AppConfig(),
    );
    addTearDown(controller.dispose);
    const gone = Game(
      id: 'manual:gone',
      key: 'gone',
      name: 'Gone',
      source: SourceKind.manual,
      command: ['definitely-not-a-program-xyz'],
    );

    await controller.launch(gone);
    expect(controller.failure, contains('Could not launch Gone'));

    await controller.launch(game('manual:ok', 'Ok', SourceKind.manual));
    expect(controller.failure, isNull);
    expect(controller.notice, 'Launched Ok');
  });

  test('async work finishing after dispose does not notify', () async {
    final source = _GatedSource();
    final controller = LibraryController(
      configPath: configPath,
      cachePath: '${dir.path}/games.json',
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      config: AppConfig(appimageDirs: const []),
      sources: [source],
    );

    final scan = controller.rescan();
    expect(source.calls, 1);
    controller.dispose();
    source.gates.single.complete();

    // Without the dispose guard, the scan's closing notifyListeners would
    // complete this future with a "used after being disposed" error.
    await scan;
    expect(controller.status, LibraryStatus.ready);
  });

  test('recentlyPlayed takes a precomputed visible list', () {
    final controller = LibraryController(
      configPath: configPath,
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      config: AppConfig(),
    )..games = [game('steam:1', 'Alpha', SourceKind.steam)];
    addTearDown(controller.dispose);
    final at = DateTime(2026, 10, 20);
    controller.playtime.begin('steam:1', at);
    controller.playtime.end('steam:1', at.add(const Duration(hours: 1)));

    expect(controller.recentlyPlayed().map((entry) => entry.id), ['steam:1']);
    // A caller that already filtered the library hands its own list in.
    expect(controller.recentlyPlayed(visible: const []), isEmpty);
  });

  test('closing with the game is chosen per launcher and persisted', () {
    controller.setCloseWithGame(SourceKind.steam, true);
    expect(controller.config.closesWithGame(SourceKind.steam), isTrue);
    expect(controller.config.closesWithGame(SourceKind.lutris), isFalse);
    expect(AppConfig.load(configPath).closeWithGame, {'steam'});

    controller.setCloseWithGame(SourceKind.steam, false);
    expect(AppConfig.load(configPath).closeWithGame, isEmpty);

    // A direct source has no launcher window to close, so it cannot be set.
    controller.setCloseWithGame(SourceKind.flatpak, true);
    expect(controller.config.closesWithGame(SourceKind.flatpak), isFalse);
    expect(controller.config.closeWithGame, isEmpty);
    expect(AppConfig.load(configPath).closeWithGame, isEmpty);
  });

  test('a focus rescan is skipped while the library is fresh', () async {
    final source = _ListSource([game('steam:1', 'Alpha', SourceKind.steam)]);
    final scan = LibraryController(
      configPath: configPath,
      cachePath: '${dir.path}/focus-games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/focus-playtime.json'),
      sources: [source],
    );
    addTearDown(scan.dispose);

    scan.lastScan = DateTime.now();
    await scan.rescanIfStale();
    expect(source.discoveries, 0);

    scan.lastScan = DateTime.now().subtract(
      LibraryController.autoRescanAge + const Duration(seconds: 1),
    );
    await scan.rescanIfStale();
    expect(scan.status, LibraryStatus.ready);
    expect(scan.games.map((game) => game.id), ['steam:1']);
  });

  test(
    'a played game survives a missing source, and can be forgotten',
    () async {
      final source = _ListSource([game('steam:1', 'Alpha', SourceKind.steam)]);
      final scan = LibraryController(
        configPath: configPath,
        cachePath: '${dir.path}/missing-games.json',
        config: AppConfig(appimageDirs: const []),
        playtime: PlaytimeStore(path: '${dir.path}/missing-playtime.json'),
        sources: [source],
      );
      addTearDown(scan.dispose);
      await scan.load(refresh: true);
      final at = DateTime(2026, 1, 1);
      scan.playtime.begin('steam:1', at);
      scan.playtime.end('steam:1', at.add(const Duration(hours: 2)));

      source.games = [];
      await scan.rescan();

      expect(scan.games, hasLength(1));
      expect(scan.games.single.id, 'steam:1');
      expect(scan.games.single.missing, isTrue);
      expect(scan.games.single.launchable, isFalse);
      expect(scan.games.single.name, 'Alpha');

      scan.forget(scan.games.single);
      expect(scan.games, isEmpty);
      expect(AppConfig.load(configPath).forgotten, {'steam:1'});

      // The next scan does not bring it back.
      await scan.rescan();
      expect(scan.games, isEmpty);

      // Reinstalled: it returns, and the forgotten mark goes away so a later
      // uninstall keeps its history again.
      source.games = [game('steam:1', 'Alpha', SourceKind.steam)];
      await scan.rescan();
      expect(scan.games.single.missing, isFalse);
      expect(AppConfig.load(configPath).forgotten, isEmpty);

      source.games = [];
      await scan.rescan();
      expect(scan.games.single.missing, isTrue);
    },
  );

  group('steamgriddb misses', () {
    LibraryController artController(
      CoverStore covers, {
      AppConfig? config,
      Duration? artSaveDelay,
    }) => LibraryController(
      configPath: configPath,
      cachePath: '${dir.path}/games.json',
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      covers: covers,
      config:
          config ??
          AppConfig(
            steamgriddbKey: 'key',
            steamgriddbAuto: true,
            coverFetch: false,
          ),
      artSaveDelay: artSaveDelay,
    );

    test(
      'a game with no grids is not asked about again within the TTL',
      () async {
        final covers = _EmptySearchCovers();
        final controller = artController(covers);
        final artless = game('steam:1', 'Artless', SourceKind.steam);

        expect(await controller.requestCoverArt(artless), isNull);
        expect(covers.searches, 1);
        expect(controller.config.sgdbMisses.keys, ['steam:1']);

        // Asked again — another tile, another rebuild: no new lookup.
        expect(await controller.requestCoverArt(artless), isNull);
        expect(covers.searches, 1);

        // Disposing flushes the debounced write, so the next run skips the
        // lookup too.
        controller.dispose();
        expect(AppConfig.load(configPath).sgdbMisses.keys, ['steam:1']);
      },
    );

    test('a stale miss is asked about again, and remembered afresh', () async {
      final covers = _EmptySearchCovers();
      final stale = DateTime.now()
          .subtract(LibraryController.sgdbMissTtl + const Duration(days: 1))
          .millisecondsSinceEpoch;
      final controller = artController(
        covers,
        config: AppConfig(
          steamgriddbKey: 'key',
          steamgriddbAuto: true,
          coverFetch: false,
          sgdbMisses: {'steam:1': stale},
        ),
      );
      addTearDown(controller.dispose);

      expect(
        await controller.requestCoverArt(
          game('steam:1', 'Artless', SourceKind.steam),
        ),
        isNull,
      );
      expect(covers.searches, 1);
      expect(controller.config.sgdbMisses['steam:1'], greaterThan(stale));
    });

    test('a burst of automatic art saves the config once', () async {
      final covers = _FoundSearchCovers(dir.path);
      final controller = artController(
        covers,
        artSaveDelay: const Duration(milliseconds: 50),
      );
      addTearDown(controller.dispose);
      final saves = <FileSystemMoveEvent>[];
      final sub = Directory(dir.path).watch().listen((event) {
        if (event is FileSystemMoveEvent && event.destination == configPath) {
          saves.add(event);
        }
      });
      addTearDown(sub.cancel);

      final art = await Future.wait([
        controller.requestCoverArt(game('steam:11', 'One', SourceKind.steam)),
        controller.requestCoverArt(game('steam:12', 'Two', SourceKind.steam)),
        controller.requestCoverArt(game('steam:13', 'Three', SourceKind.steam)),
      ]);
      expect(
        art.map((entry) => entry?.kind).toList(),
        everyElement(ArtworkKind.cover),
      );
      // The picks are in the config at once…
      expect(controller.config.autoArt, hasLength(3));
      // …but the file is written only once the burst settles.
      expect(File(configPath).existsSync(), isFalse);

      await untilTrue(() => saves.isNotEmpty);
      expect(saves, hasLength(1));
      expect(AppConfig.load(configPath).autoArt, hasLength(3));
    });
  });
}

/// Artwork the launcher fetched itself: one cached path per game.
void _fetchedArtTests(Directory Function() dir) {
  Game steamGame(String cover) => Game(
    id: 'steam:424242',
    key: '424242',
    name: 'Fetched Test',
    source: SourceKind.steam,
    command: const ['steam', '-applaunch', '424242'],
    cover: cover,
    extra: const {'appid': '424242'},
  );

  test('fetched art is what the tile shows, until the file is gone', () {
    final fetched = File('${dir().path}/fetched.png')
      ..writeAsBytesSync([1, 2, 3]);
    final capsule = File('${dir().path}/capsule.png')
      ..writeAsBytesSync([1, 2, 3]);
    final store = CoverStore(
      settings: ArtSettings(autoArt: {'steam:424242': fetched.path}),
      coverDir: '${dir().path}/covers',
    );
    final game = steamGame(capsule.path);

    expect(store.autoArtFor(game), fetched.path);
    expect(store.resolve(game).value, fetched.path);

    fetched.deleteSync();
    expect(store.autoArtFor(game), isNull);
    expect(store.resolve(game).value, capsule.path);
  });

  test('auto_art round trips, and reads the old shape-keyed files', () {
    final path = '${dir().path}/a.png';
    final configPath = '${dir().path}/config.json';
    AppConfig(autoArt: {'steam:1': path}).save(configPath);
    expect(AppConfig.load(configPath).autoArt, {'steam:1': path});

    // Files written back when a fetch was keyed by poster shape: the portrait
    // entry is what the wall still shows, a square one has nowhere to go.
    File(configPath).writeAsStringSync(
      '{"auto_art": {"a": 5, "b": {"square": 5, "portrait": "p.png"}, '
      '"c": {"square": "s.png"}, "d": ""}}',
    );
    final loaded = AppConfig.load(configPath).autoArt;
    expect(loaded.containsKey('a'), isFalse);
    expect(loaded['b'], 'p.png');
    expect(loaded.containsKey('c'), isFalse);
    expect(loaded.containsKey('d'), isFalse);
  });

  test('one fetch per game, however many tiles are showing it', () async {
    final cover = File('${dir().path}/cover.png')..writeAsBytesSync([1, 2, 3]);
    final covers = _CountingCovers(
      Artwork(ArtworkKind.cover, value: cover.path),
    );
    final controller = LibraryController(
      configPath: '${dir().path}/config.json',
      cachePath: '${dir().path}/games.json',
      playtime: PlaytimeStore(path: '${dir().path}/playtime.json'),
      covers: covers,
    );
    addTearDown(controller.dispose);
    final game = Game(
      id: 'steam:424242',
      key: '424242',
      name: 'Fetched Test',
      source: SourceKind.steam,
      command: const ['steam', '-applaunch', '424242'],
      extra: const {'appid': '424242'},
    );

    // The wall tile and the recently played shelf tile ask in the same frame.
    final results = await Future.wait([
      controller.requestCoverArt(game),
      controller.requestCoverArt(game),
    ]);

    expect(covers.fetches, 1);
    // Both tiles get what the one fetch found: a tile told "nothing came back"
    // would keep its letter until it happened to be rebuilt.
    expect(results.map((artwork) => artwork?.value).toList(), [
      cover.path,
      cover.path,
    ]);

    // The entry lasts for the flight, not forever: a later tile may ask again.
    await controller.requestCoverArt(game);
    expect(covers.fetches, 2);
  });
}

/// Waits until [condition] holds, polling rather than sleeping a fixed time.
Future<void> untilTrue(bool Function() condition) async {
  for (var tick = 0; tick < 200 && !condition(); tick++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A source that yields a fixed list, replaceable between scans.
class _FixedSource extends GameSource {
  _FixedSource(this.kind, this.games);

  @override
  final SourceKind kind;

  List<Game> games;

  @override
  Future<List<Game>> discover(AppConfig cfg) async => games;
}

/// A source that fails with [error] until the error is cleared.
class _ThrowingSource extends GameSource {
  _ThrowingSource(this.kind, this.error);

  @override
  final SourceKind kind;

  Object? error;

  @override
  Future<List<Game>> discover(AppConfig cfg) =>
      error == null ? Future.value(const []) : Future.error(error!);
}

/// A source that waits on a gate it hands out, counting how often it was
/// asked, so overlapping scans can be watched.
class _GatedSource extends GameSource {
  final gates = <Completer<void>>[];
  int calls = 0;

  @override
  SourceKind get kind => SourceKind.manual;

  @override
  Future<List<Game>> discover(AppConfig cfg) {
    calls++;
    final gate = Completer<void>();
    gates.add(gate);
    return gate.future.then((_) => const <Game>[]);
  }
}

/// A controller whose first plugin round trip throws, so the lookup guard can
/// be watched clearing.
class _FailingLookupController extends LibraryController {
  _FailingLookupController({
    super.configPath,
    super.cachePath,
    super.config,
    super.pluginAnswers,
  });

  int lookups = 0;

  @override
  Future<PluginAnswer> askPlugin(Plugin plugin, PluginQuery query) {
    lookups++;
    if (lookups == 1) return Future.error(StateError('boom'));
    return Future.value(
      const PluginAnswer(
        fields: [PluginField(label: 'Main story', value: '3h')],
      ),
    );
  }
}

/// A cover store that counts what the controller asks it to fetch.
class _CountingCovers extends CoverStore {
  _CountingCovers(this.answer);

  /// What a fetch comes back with; `null` means "no artwork anywhere".
  final Artwork? answer;

  int fetches = 0;

  @override
  Future<Artwork?> fetchSteamCover(Game game) async {
    fetches++;
    return answer;
  }
}

/// A cover store whose SteamGridDB never has anything, counting the lookups.
class _EmptySearchCovers extends CoverStore {
  int searches = 0;

  @override
  Future<Artwork?> fetchSteamCover(Game game) async => null;

  @override
  Future<List<SgdbGrid>> searchArt(Game game) async {
    searches++;
    return const [];
  }
}

/// A cover store whose SteamGridDB always finds one grid, "downloaded" to a
/// local path without any network.
class _FoundSearchCovers extends CoverStore {
  _FoundSearchCovers(this.folder);

  final String folder;

  @override
  Future<Artwork?> fetchSteamCover(Game game) async => null;

  @override
  Future<List<SgdbGrid>> searchArt(Game game) async => [
    SgdbGrid(
      id: 1,
      url: 'https://example.invalid/${game.key}.jpg',
      thumb: 'https://example.invalid/${game.key}-thumb.jpg',
    ),
  ];

  @override
  Future<String?> downloadArt(Game game, SgdbGrid grid) async =>
      '$folder/${game.key}.jpg';
}

/// A source whose library a test can change between scans.
class _ListSource extends GameSource {
  _ListSource(this.games);

  List<Game> games;
  int discoveries = 0;

  @override
  SourceKind get kind => SourceKind.steam;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    discoveries++;
    return games;
  }
}
