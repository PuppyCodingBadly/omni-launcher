import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/covers.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';

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
    controller = LibraryController(
      configPath: configPath,
      config: AppConfig(hidden: {'steam:2'}),
    )..games = [
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
    expect(controller.visibleGames.map((entry) => entry.id).toList(), ['flatpak:gamma']);

    controller.setQuery('steam:1');
    expect(controller.visibleGames.map((entry) => entry.id).toList(), ['steam:1']);

    controller.setQuery('flatpak');
    expect(controller.visibleGames.map((entry) => entry.id).toList(), ['flatpak:gamma']);

    controller.setQuery('nothing-here');
    expect(controller.visibleGames, isEmpty);
  });

  test('source filters toggle on and off', () {
    controller.toggleSource(SourceKind.steam);
    expect(controller.visibleGames.map((entry) => entry.id).toList(), ['steam:1']);

    controller.toggleSource(SourceKind.flatpak);
    expect(controller.visibleGames.map((entry) => entry.id).toList(), [
      'steam:1',
      'flatpak:gamma',
    ]);

    controller.toggleSource(SourceKind.steam);
    expect(controller.visibleGames.map((entry) => entry.id).toList(), ['flatpak:gamma']);

    controller.clearSources();
    expect(controller.visibleGames, hasLength(2));
  });

  test('hiding a game persists and updates the counts', () {
    final gamma = controller.games.last;
    controller.setHidden(gamma, hidden: true);
    expect(controller.hiddenCount, 2);
    expect(controller.visibleGames.map((entry) => entry.id).toList(), ['steam:1']);
    expect(AppConfig.load(configPath).hidden, {'steam:2', 'flatpak:gamma'});

    controller.setHidden(gamma, hidden: false);
    expect(controller.hiddenCount, 1);
    expect(controller.visibleGames, hasLength(2));
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
    AppConfig(artOverrides: {gamma.id: '${dir.path}/gone.png'}).save(configPath);
    final reloaded = LibraryController(configPath: configPath);
    expect(reloaded.covers.overrideFor(gamma), isNull);
    expect(reloaded.covers.resolve(gamma).kind, ArtworkKind.letter);
  });

  test('no artwork is requested when both sources are off', () async {
    final off = LibraryController(
      configPath: configPath,
      config: AppConfig(coverFetch: false, steamgriddbKey: '', steamgriddbAuto: false),
    );
    expect(await off.requestCoverArt(game('flatpak:x', 'X', SourceKind.flatpak)), isNull);
    expect(await off.searchArt(game('flatpak:x', 'X', SourceKind.flatpak)), isEmpty);
  });

  group('fetched artwork', () => _fetchedArtTests(() => dir));

  test('source counts follow the library', () {
    expect(controller.countsBySource, {SourceKind.steam: 2, SourceKind.flatpak: 1});
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
    final fetched = File('${dir().path}/fetched.png')..writeAsBytesSync([1, 2, 3]);
    final capsule = File('${dir().path}/capsule.png')..writeAsBytesSync([1, 2, 3]);
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
    AppConfig(
      autoArt: {'steam:1': path},
    ).save(configPath);
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
    final covers = _CountingCovers();
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
    expect(results, everyElement(isNull));

    // The guard lasts for the flight, not forever: a later tile may try again.
    await controller.requestCoverArt(game);
    expect(covers.fetches, 2);
  });
}

/// A cover store that counts what the controller asks it to fetch.
class _CountingCovers extends CoverStore {
  int fetches = 0;

  @override
  Future<Artwork?> fetchSteamCover(Game game) async {
    fetches++;
    return null;
  }
}
