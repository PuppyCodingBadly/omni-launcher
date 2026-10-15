import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/art/steamgriddb.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/covers.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';

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

  group('square posters', () => _squareArtTests(() => dir));

  test('source counts follow the library', () {
    expect(controller.countsBySource, {SourceKind.steam: 2, SourceKind.flatpak: 1});
  });
}

/// Square windows must show square posters, not cropped portrait capsules.
void _squareArtTests(Directory Function() dir) {
  Game steamGame(String cover) => Game(
    id: 'steam:424242',
    key: '424242',
    name: 'Square Test',
    source: SourceKind.steam,
    command: const ['steam', '-applaunch', '424242'],
    cover: cover,
    extra: const {'appid': '424242'},
  );

  test('a square window ignores the portrait capsule and asks for square art', () {
    final portrait = File('${dir().path}/portrait.png')..writeAsBytesSync([1, 2, 3]);
    final store = CoverStore(
      settings: const ArtSettings(steamCovers: false, sgdbKey: 'key'),
      coverDir: '${dir().path}/covers',
    );
    final game = steamGame(portrait.path);

    // Portrait keeps using the capsule.
    expect(store.resolve(game).kind, ArtworkKind.cover);
    expect(store.resolve(game).value, portrait.path);

    // Square refuses it and reports that a fetch could still fill the tile.
    final square = store.resolve(game, shape: GridShape.square);
    expect(square.kind, ArtworkKind.letter);
    expect(square.pending, isTrue);
  });

  test('without a key a square window cannot fetch, so nothing is pending', () {
    final store = CoverStore(
      settings: const ArtSettings(steamCovers: false),
      coverDir: '${dir().path}/covers',
    );
    final game = steamGame('${dir().path}/missing.png');
    expect(store.resolve(game, shape: GridShape.square).pending, isFalse);
  });

  test('fetched art is used for the shape it was fetched for', () {
    final square = File('${dir().path}/square.png')..writeAsBytesSync([1, 2, 3]);
    final portrait = File('${dir().path}/portrait.png')..writeAsBytesSync([1, 2, 3]);
    final store = CoverStore(
      settings: ArtSettings(
        autoArt: {
          'steam:424242': {'square': square.path},
        },
      ),
      coverDir: '${dir().path}/covers',
    );
    final game = steamGame(portrait.path);

    expect(store.autoArtFor(game, GridShape.square), square.path);
    expect(store.autoArtFor(game, GridShape.portrait), isNull);
    expect(store.resolve(game, shape: GridShape.square).value, square.path);
    expect(store.resolve(game).value, portrait.path);
  });

  test('fetched art that disappeared falls back', () {
    final store = CoverStore(
      settings: ArtSettings(
        autoArt: {
          'steam:424242': {'square': '${dir().path}/gone.png'},
        },
      ),
      coverDir: '${dir().path}/covers',
    );
    expect(store.autoArtFor(steamGame('${dir().path}/x.png'), GridShape.square), isNull);
  });

  test('auto_art round trips and tolerates junk', () {
    final path = '${dir().path}/a.png';
    final configPath = '${dir().path}/config.json';
    AppConfig(autoArt: {
      'steam:1': {'square': path},
    }).save(configPath);
    expect(AppConfig.load(configPath).autoArt, {
      'steam:1': {'square': path},
    });

    File(configPath).writeAsStringSync(
      '{"auto_art": {"a": "not a map", "b": {"square": 5, "portrait": "p.png"}, "c": {}}}',
    );
    final loaded = AppConfig.load(configPath).autoArt;
    expect(loaded.containsKey('a'), isFalse);
    expect(loaded['b'], {'portrait': 'p.png'});
    expect(loaded.containsKey('c'), isFalse);
  });
}
