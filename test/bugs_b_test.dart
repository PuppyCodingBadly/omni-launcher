import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/art/steamgriddb.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/covers.dart';
import 'package:omni_launcher/src/launcher.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/sources/epic.dart';
import 'package:omni_launcher/src/sources/registry.dart';
import 'package:omni_launcher/src/sources/source.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/game_tile.dart';
import 'package:omni_launcher/src/ui/library_page.dart';
import 'package:omni_launcher/src/ui/theme.dart';
import 'package:omni_launcher/src/util/proc.dart';

Game game(String id, String name, SourceKind source, {List<String>? command}) => Game(
  id: id,
  key: id.split(':').last,
  name: name,
  source: source,
  command: command ?? const ['true'],
);

Game steamGame(String appid) => Game(
  id: 'steam:$appid',
  key: appid,
  name: 'Game $appid',
  source: SourceKind.steam,
  command: const ['steam', '-applaunch'],
  extra: {'appid': appid},
);

/// A controller that records what the UI asks the artwork layer for.
class ArtSpy extends LibraryController {
  ArtSpy({
    required super.configPath,
    required super.cachePath,
    required super.playtime,
    super.config,
  });

  /// Game ids the tiles asked to fetch covers for.
  final List<String> coverRequests = <String>[];

  /// Game ids the art picker asked SteamGridDB for.
  final List<String> searches = <String>[];

  /// Candidates [searchArt] hands back; empty means "nothing found".
  List<SgdbGrid> candidates = const [];

  @override
  Future<Artwork?> requestCoverArt(Game game) async {
    coverRequests.add(game.id);
    // Never resolves to artwork: the tile stays as it is, like a game whose
    // cover the CDN does not have.
    return null;
  }

  @override
  Future<List<SgdbGrid>> searchArt(Game game) async {
    searches.add(game.id);
    return candidates;
  }
}

/// The page in a window of [width]x[height] logical pixels.
Future<void> pumpPage(WidgetTester tester, LibraryController controller, Size size) async {
  await resizeWindow(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      // The app rebuilds the page from the controller, so the test has to too.
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => LibraryPage(controller: controller),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Resize the window to [size] logical pixels.
Future<void> resizeWindow(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpAndSettle();
}

/// The artwork files the tiles and panels are showing, in tree order.
List<String> shownCoverPaths(WidgetTester tester) => [
  for (final image in tester.widgetList<Image>(find.byType(Image)))
    if (image.image is FileImage) (image.image as FileImage).file.path,
];

void main() {
  late Directory dir;

  setUp(() {
    // flutter_test answers every HttpClient with a canned 400; these tests use
    // local servers and closed ports instead, and never leave the machine.
    HttpOverrides.global = null;
    dir = Directory.systemTemp.createTempSync('omni-bugs-b');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('the games cache', () {
    String cachePath() => '${dir.path}/games.json';
    String configPath() => '${dir.path}/config.json';

    test('a hand edited cache never stops the start up', () async {
      // A half written or hand edited cache: the entries have the right shape
      // but fields of the wrong type, plus one that is not a game at all.
      File(cachePath()).writeAsStringSync(
        jsonEncode([
          {
            'id': 'steam:1',
            'key': '1',
            'name': 'Alpha',
            'source': 'steam',
            'command': ['steam', '-applaunch', '1'],
            'extra': {'appid': '1'},
          },
          {
            'id': 'steam:2',
            'name': 'Beta',
            'source': 'steam',
            'command': 'steam -applaunch 2', // not a list
          },
          {
            'id': 'steam:3',
            'name': 'Gamma',
            'source': 'steam',
            'command': ['steam'],
            'extra': ['appid', '3'], // not a map
          },
          {
            'id': 'steam:4',
            'name': 'Delta',
            'source': 'steam',
            'command': ['steam'],
            'cwd': 4, // not a string
          },
          {'name': 'no id'},
          'not an object',
        ]),
      );

      final controller = LibraryController(
        configPath: configPath(),
        cachePath: cachePath(),
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
        config: AppConfig(),
      );
      await controller.load(refresh: false);

      expect(controller.status, LibraryStatus.ready);
      expect(controller.games.map((entry) => entry.id).toList(), [
        'steam:1',
        'steam:2',
        'steam:3',
        'steam:4',
      ]);
      expect(controller.games.first.command, ['steam', '-applaunch', '1']);
      expect(controller.games[1].command, ['steam -applaunch 2']);
      expect(controller.games[2].extra, isEmpty);
      expect(controller.games[3].cwd, isNull);
    });

    test('a cache that is not a list of games is ignored', () async {
      File(cachePath()).writeAsStringSync('{"games": []}');
      final controller = LibraryController(
        configPath: configPath(),
        cachePath: cachePath(),
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
        config: AppConfig(),
      );
      await controller.load(refresh: false);
      expect(controller.games, isEmpty);
    });

    test('the cache is written beside the target and renamed into place', () async {
      final controller = LibraryController(
        configPath: configPath(),
        cachePath: cachePath(),
        config: AppConfig(appimageDirs: const []),
      );
      await controller.load();

      final file = File(cachePath());
      expect(file.existsSync(), isTrue);
      final decoded = jsonDecode(file.readAsStringSync());
      expect(decoded, isA<List>());
      expect(
        (decoded as List).map((entry) => (entry as Map)['id']).toList(),
        controller.games.map((entry) => entry.id).toList(),
      );
      // No half written leftover next to the cache.
      expect(File('${cachePath()}.tmp').existsSync(), isFalse);
    });
  });

  group('manual entries', () {
    test('adding a name twice replaces the entry instead of hiding it', () async {
      final controller = LibraryController(
        configPath: '${dir.path}/config.json',
        cachePath: '${dir.path}/games.json',
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
        config: AppConfig(appimageDirs: const []),
      );

      await controller.addManual('Solitair', const ['old-runner']);
      await controller.addManual('Solitair', const ['new-runner'], cwd: '/tmp');

      expect(controller.config.manual, hasLength(1));
      expect(AppConfig.load('${dir.path}/config.json').manual.single.command, [
        'new-runner',
      ]);

      final manual = controller.games.where((entry) => entry.source == SourceKind.manual);
      expect(manual, hasLength(1));
      expect(manual.single.command, ['new-runner']);

      await controller.removeManual('Solitair');
      expect(controller.config.manual, isEmpty);
      expect(
        controller.games.where((entry) => entry.source == SourceKind.manual),
        isEmpty,
      );
    });
  });

  group('launching', () {
    test('the program is resolved the way the shell would', () {
      expect(Launcher.resolveProgram(const ['/bin/sh']), '/bin/sh');
      expect(Launcher.resolveProgram(const ['sh']), which('sh'));
      expect(Launcher.resolveProgram(const ['definitely-not-a-program-xyz']), isNull);
      expect(Launcher.resolveProgram(const ['/no/such/path/at/all']), isNull);
      expect(Launcher.resolveProgram(const []), isNull);
      expect(Launcher.resolveProgram(const ['/tmp']), isNull);

      final plain = File('${dir.path}/not-executable')
        ..writeAsStringSync('#!/bin/sh\n');
      expect(Launcher.resolveProgram([plain.path]), isNull);
      Process.runSync('chmod', ['+x', plain.path]);
      expect(Launcher.resolveProgram([plain.path]), plain.path);

      // A relative command belongs to the game's own folder, not to ours.
      expect(Launcher.resolveProgram(const ['./run.sh'], cwd: dir.path), isNull);
      expect(
        Launcher.resolveProgram(['./not-executable'], cwd: dir.path),
        '${dir.path}/./not-executable',
      );
      // `~` and `$VAR` are the shell's to expand: never refuse those.
      expect(Launcher.resolveProgram(const ['~/nowhere-at-all']), '~/nowhere-at-all');
      expect(Launcher.resolveProgram(const [r'$HOME/nowhere']), r'$HOME/nowhere');
    });

    test('a missing binary fails the launch instead of reporting success', () async {
      final missing = game(
        'manual:gone',
        'Gone',
        SourceKind.manual,
        command: const ['definitely-not-a-program-xyz'],
      );
      await expectLater(Launcher.launch(missing), throwsA(isA<StateError>()));
    });

    test('the library reports the failure to the user', () async {
      final controller = LibraryController(
        configPath: '${dir.path}/config.json',
        cachePath: '${dir.path}/games.json',
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
        config: AppConfig(appimageDirs: const []),
      );
      final missing = game(
        'manual:gone',
        'Gone',
        SourceKind.manual,
        command: const ['definitely-not-a-program-xyz'],
      );

      await controller.launch(missing);

      expect(controller.notice, contains('Could not launch Gone'));
    });
  });

  group('cover art', () {
    CoverStore storeWith({bool steamCovers = true, bool sgdbAuto = false}) => CoverStore(
      settings: ArtSettings(
        steamCovers: steamCovers,
        sgdbKey: sgdbAuto ? 'key' : '',
        sgdbAuto: sgdbAuto,
      ),
      coverDir: '${dir.path}/covers',
    );

    test('a cover remembered as missing is not pending', () {
      final store = storeWith();
      final game = steamGame('900090009');
      expect(store.resolve(game).pending, isTrue);

      Directory('${dir.path}/covers').createSync(recursive: true);
      File('${dir.path}/covers/steam_900090009.missing').writeAsStringSync('');

      final artwork = store.resolve(game);
      expect(artwork.kind, ArtworkKind.letter);
      expect(artwork.pending, isFalse);
      expect(store.resolve(steamGame('424243')).pending, isTrue);
    });

    test('a known missing Steam cover is not fetched again', () async {
      final store = storeWith();
      Directory('${dir.path}/covers').createSync(recursive: true);
      File('${dir.path}/covers/steam_900090009.missing').writeAsStringSync('');
      // No network is reachable from here; the marker has to short circuit it.
      expect(await store.fetchSteamCover(steamGame('900090009')), isNull);
    });

    test('SteamGridDB art is still looked for when only the CDN is missing', () {
      final store = storeWith(sgdbAuto: true);
      Directory('${dir.path}/covers').createSync(recursive: true);
      File('${dir.path}/covers/steam_900090009.missing').writeAsStringSync('');
      expect(store.resolve(steamGame('900090009')).pending, isTrue);
    });

    test('games the Steam CDN never covers are not pending either', () {
      expect(storeWith().resolve(game('flatpak:x', 'X', SourceKind.flatpak)).pending, isFalse);
      expect(
        storeWith(steamCovers: false, sgdbAuto: true)
            .resolve(game('flatpak:x', 'X', SourceKind.flatpak))
            .pending,
        isTrue,
      );
    });

    test('a grid of missing covers does not open a connection per tile', () async {
      const tiles = 12;
      var active = 0;
      var peak = 0;
      final gates = <Completer<void>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        active++;
        if (active > peak) peak = active;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        request.response
          ..headers.contentType = ContentType.binary
          ..add(List<int>.filled(8192, 7));
        await request.response.close();
        active--;
      });

      final store = CoverStore(
        settings: const ArtSettings(),
        coverDir: '${dir.path}/covers',
        cdnBase: 'http://127.0.0.1:${server.port}',
      );
      var completed = 0;
      final downloads = [
        for (var i = 0; i < tiles; i++)
          store.fetchSteamCover(steamGame('${900000 + i}')).then((artwork) {
            completed++;
            return artwork;
          }),
      ];

      // Let the tiles reach the server; the rest has to wait for a free slot.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(gates, hasLength(4));
      expect(peak, 4);

      var guard = 0;
      while (completed < tiles && guard++ < 500) {
        for (final gate in [...gates]) {
          if (!gate.isCompleted) gate.complete();
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final results = await Future.wait(downloads);
      await server.close(force: true);

      expect(completed, tiles);
      expect(results.whereType<Artwork>(), hasLength(tiles));
      expect(peak, 4);
      // The capsules were cached as they arrived.
      expect(File('${dir.path}/covers/steam_900000.jpg').existsSync(), isTrue);
    });
  });

  group('SteamGridDB grids', () {
    test('a lookup asks for the portrait dimensions the wall shows', () async {
      final queries = <Uri>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        queries.add(request.uri);
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"success":true,"data":[]}');
        await request.response.close();
      });
      final client = SteamGridDb(
        apiKey: 'key',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      await client.gridsForSteamApp(1234);
      await client.gridsForGame(5678);
      client.close();
      await server.close(force: true);

      expect(queries.map((uri) => uri.path).toList(), [
        '/grids/steam/1234',
        '/grids/game/5678',
      ]);
      expect(
        queries.map((uri) => uri.queryParameters['dimensions']).toSet(),
        {SteamGridDb.defaultDimensions},
      );
    });

    test('searchArt looks a Steam game up by app id, anything else by name', () async {
      final queries = <Uri>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        queries.add(request.uri);
        final path = request.uri.path;
        final body = path.startsWith('/grids/steam/')
            ? '{"success":true,"data":[{"id":1,"url":"https://cdn.example/1.png"}]}'
            : path.startsWith('/search/')
            ? '{"success":true,"data":[{"id":7,"name":"Terraria"}]}'
            : '{"success":true,"data":[]}';
        request.response
          ..headers.contentType = ContentType.json
          ..write(body);
        await request.response.close();
      });
      final store = CoverStore(
        settings: const ArtSettings(sgdbKey: 'key', sgdbAuto: true),
        coverDir: '${dir.path}/covers',
        sgdbBase: 'http://127.0.0.1:${server.port}',
      );

      await store.searchArt(steamGame('1234'));
      expect(queries.single.path, '/grids/steam/1234');
      expect(queries.single.queryParameters['dimensions'], SteamGridDb.defaultDimensions);

      // No app id: autocomplete first, then the grids of the best match.
      queries.clear();
      await store.searchArt(game('flatpak:x', 'Terraria', SourceKind.flatpak));
      expect(queries.map((uri) => uri.path).toList(), [
        '/search/autocomplete/Terraria',
        '/grids/game/7',
      ]);
      expect(queries.last.queryParameters['dimensions'], SteamGridDb.defaultDimensions);
      await server.close(force: true);
    });
  });

  group('SteamGridDB failures', () {
    /// A port nothing is listening on: connecting to it is refused at once.
    Future<String> unreachableBaseUrl() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final url = 'http://127.0.0.1:${server.port}';
      await server.close(force: true);
      return url;
    }

    test('an unreachable host is reported like any other failure', () async {
      final client = SteamGridDb(apiKey: 'key', baseUrl: await unreachableBaseUrl());

      // The settings screen, the tile auto fetch and the art picker all only
      // handle SteamGridDbException; a raw socket error walks past them.
      await expectLater(
        client.searchGames('portal'),
        throwsA(
          isA<SteamGridDbException>().having(
            (error) => error.message,
            'message',
            contains('unreachable'),
          ),
        ),
      );
      await expectLater(
        client.testKey(),
        throwsA(isA<SteamGridDbException>()),
      );
      client.close();
    });

    test('the API key goes to the API, not to the image host', () async {
      final headers = <String, String?>{};
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        headers[request.uri.path] = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        final isImage = request.uri.path == '/grid/1.png';
        request.response
          ..headers.contentType = isImage ? ContentType.binary : ContentType.json
          ..add(
            isImage
                ? List<int>.filled(64, 7)
                : utf8.encode('{"success":true,"data":[]}'),
          );
        await request.response.close();
      });
      final client = SteamGridDb(
        apiKey: 'secret-key',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      await client.searchGames('portal');
      final path = await client.downloadGrid(
        SgdbGrid(
          id: 1,
          url: 'http://127.0.0.1:${server.port}/grid/1.png',
          thumb: '',
        ),
        '${dir.path}/grid.png',
      );
      client.close();
      await server.close(force: true);

      // The key authenticates the API; the public CDN needs no credentials.
      expect(headers['/search/autocomplete/portal'], 'Bearer secret-key');
      expect(headers['/grid/1.png'], isNull);
      expect(path, '${dir.path}/grid.png');
    });

    test('a grid that cannot be downloaded is reported as no artwork', () async {
      final client = SteamGridDb(apiKey: 'key', baseUrl: await unreachableBaseUrl());
      final path = await client.downloadGrid(
        SgdbGrid(id: 1, url: '${await unreachableBaseUrl()}/grid.png', thumb: ''),
        '${dir.path}/grid.png',
      );
      expect(path, isNull);
      expect(File('${dir.path}/grid.png').existsSync(), isFalse);
      client.close();
    });
  });

  group('SteamGridDB pacing', () {
    test('simultaneous lookups are spread out instead of bursting', () async {
      final arrivals = <int>[];
      final watch = Stopwatch()..start();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        arrivals.add(watch.elapsedMilliseconds);
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"success":true,"data":[]}');
        await request.response.close();
      });

      final client = SteamGridDb(
        apiKey: 'key',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      await Future.wait([
        for (var i = 0; i < 5; i++) client.searchGames('game $i'),
      ]);
      client.close();
      await server.close(force: true);

      expect(arrivals, hasLength(5));
      arrivals.sort();
      // 5 requests at 250ms apart cannot all fit in a shorter window.
      expect(
        Duration(milliseconds: arrivals.last - arrivals.first),
        greaterThan(const Duration(milliseconds: 900)),
      );
      for (var i = 1; i < arrivals.length; i++) {
        expect(arrivals[i] - arrivals[i - 1], greaterThan(100));
      }
    });
  });

  // ------------------------------------------------------------ rename

  group('rename under attack', () {
    String configPath() => '${dir.path}/config.json';
    String cachePath() => '${dir.path}/games.json';
    String playtimePath() => '${dir.path}/playtime.json';
    const String id = 'manual:Alpha';

    /// A library with one hand added game, so the scan finds something that
    /// does not depend on what is installed here.
    AppConfig library({
      Map<String, String> names = const {},
      Map<String, String> art = const {},
      Set<String> hidden = const {},
    }) => AppConfig(
      appimageDirs: const [],
      manual: [ManualEntry(name: 'Alpha', command: const ['true'])],
      nameOverrides: names,
      artOverrides: art,
      hidden: hidden,
    );

    LibraryController controller({AppConfig? config}) => LibraryController(
      configPath: configPath(),
      cachePath: cachePath(),
      playtime: PlaytimeStore(path: playtimePath()),
      config: config,
    );

    /// A controller that reads back what the last one saved.
    LibraryController reopened() => LibraryController(
      configPath: configPath(),
      cachePath: cachePath(),
      playtime: PlaytimeStore(path: playtimePath()),
    );

    Game foundIn(LibraryController controller) =>
        controller.games.firstWhere((entry) => entry.id == id);

    test('a scan caches the discovered name and re-applies the rename', () async {
      final first = controller(config: library());
      addTearDown(first.dispose);
      await first.rescan();
      expect(foundIn(first).name, 'Alpha');

      first.setName(id, 'Beta');
      expect(foundIn(first).name, 'Beta');

      // A second scan must not write the rename into the cache, or the reset
      // could never find the discovered name again.
      await first.rescan();
      expect(foundIn(first).name, 'Beta');
      final cached = jsonDecode(File(cachePath()).readAsStringSync()) as List;
      final entry = cached.cast<Map>().firstWhere((row) => row['id'] == id);
      expect(entry['name'], 'Alpha');

      // The next start shows the rename before its own scan has run.
      final second = reopened();
      addTearDown(second.dispose);
      await second.load(refresh: false);
      expect(foundIn(second).name, 'Beta');
      expect(second.discoveredNameFor(id), 'Alpha');

      // And resetting goes back to what the launcher found, not to the cache.
      second.setName(id, null);
      expect(foundIn(second).name, 'Alpha');
      expect(AppConfig.load(configPath()).nameOverrides, isEmpty);
    });

    test('a rename keeps the identity, the hidden flag, the art and the time', () async {
      final art = File('${dir.path}/pinned.png')..writeAsBytesSync([1, 2, 3]);
      final first = controller(
        config: library(art: {id: art.path}, hidden: {id}),
      );
      addTearDown(first.dispose);
      await first.rescan();
      final before = foundIn(first);
      final start = DateTime.now().subtract(const Duration(minutes: 5));
      first.playtime.begin(id, start);
      first.playtime.end(id, DateTime.now());
      final played = first.playtimeOf(id);
      expect(played, greaterThan(Duration.zero));
      expect(first.hiddenCount, 1);

      first.setName(id, 'Beta');

      final after = foundIn(first);
      expect(after.name, 'Beta');
      expect(after.id, before.id);
      expect(after.key, before.key);
      expect(after.command, before.command);
      expect(after.extra, before.extra);
      expect(after.path, before.path);
      // Everything keyed by identity follows the game, not its name.
      expect(first.hiddenCount, 1);
      expect(first.visibleGames.any((entry) => entry.id == id), isFalse);
      expect(first.covers.overrideFor(after), art.path);
      expect(first.covers.resolve(after).kind, ArtworkKind.cover);
      expect(first.playtimeOf(id), played);
      expect(first.lastPlayedFor(id), isNotNull);
    });

    test('a rename cannot merge two games that end up with one name', () async {
      final controllerWithBoth = LibraryController(
        configPath: configPath(),
        cachePath: cachePath(),
        playtime: PlaytimeStore(path: playtimePath()),
        config: AppConfig(
          appimageDirs: const [],
          manual: [
            ManualEntry(name: 'Alpha', command: const ['true']),
            ManualEntry(name: 'Beta', command: const ['true']),
          ],
        ),
      );
      addTearDown(controllerWithBoth.dispose);
      await controllerWithBoth.rescan();

      controllerWithBoth.setName('manual:Alpha', 'Beta');

      final both = controllerWithBoth.games.where((entry) => entry.name == 'Beta');
      expect(both, hasLength(2));
      expect(
        both.map((entry) => entry.id).toSet(),
        {'manual:Alpha', 'manual:Beta'},
      );
      // ... and the override never reaches the scan: identity is untouched.
      expect(
        controllerWithBoth.games
            .firstWhere((entry) => entry.id == 'manual:Alpha')
            .key,
        'Alpha',
      );
    });

    test('a rename cannot change what de-duplication compares', () async {
      final steam = Game(
        id: 'steam:440',
        key: '440',
        name: 'Team Fortress 2',
        source: SourceKind.steam,
        command: const ['steam', '-applaunch', '440'],
      );
      final shortcut = Game(
        id: 'desktop:team-fortress-2.desktop',
        key: 'team-fortress-2.desktop',
        name: 'Team Fortress 2',
        source: SourceKind.desktop,
        command: const ['gtk-launch', 'team-fortress-2.desktop'],
        extra: const {'dedupe': 'steam:440'},
      );

      final renamed = applyNameOverrides(
        [steam],
        const {'steam:440': 'TF2 (modded)'},
      ).single;
      expect(renamed.name, 'TF2 (modded)');
      expect(dedupeKey(renamed), dedupeKey(steam));

      // The scan drops the shortcut either way, and the survivor is the
      // renamed game: overrides are applied after de-duplication.
      final scanned = await discoverAll(
        AppConfig(nameOverrides: const {'steam:440': 'TF2 (modded)'}),
        sources: [_FixedSource(SourceKind.steam, [steam]), _FixedSource(SourceKind.desktop, [shortcut])],
      );
      expect(scanned, hasLength(1));
      expect(scanned.single.id, 'steam:440');
      expect(scanned.single.name, 'TF2 (modded)');
    });
  });

  // ----------------------------------------------------- poster geometry

  group('poster geometry in the window', () {
    late ArtSpy spy;

    ArtSpy buildSpy({Map<String, String> art = const {}}) {
      spy = ArtSpy(
        configPath: '${dir.path}/config.json',
        cachePath: '${dir.path}/games.json',
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
        config: AppConfig(
          appimageDirs: const [],
          artOverrides: art,
          // A key with automatic fetching makes a coverless game pending, so
          // the tiles really do ask for artwork.
          steamgriddbKey: 'key',
          steamgriddbAuto: true,
        ),
      );
      addTearDown(spy.dispose);
      spy.games = [
        game('flatpak:a', 'Alpha', SourceKind.flatpak),
        game('flatpak:b', 'Beta', SourceKind.flatpak),
        game('flatpak:c', 'Gamma', SourceKind.flatpak),
      ];
      return spy;
    }

    List<GameTile> tiles(WidgetTester tester) =>
        tester.widgetList<GameTile>(find.byType(GameTile)).toList();

    double gridAspect(WidgetTester tester) {
      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      return delegate.childAspectRatio;
    }

    /// The first tile's cover box.
    Size coverBox(WidgetTester tester) => tester.getSize(
      find
          .descendant(
            of: find.byType(GameTile).first,
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );

    testWidgets('the wall is portrait posters whatever the window shape', (tester) async {
      final controller = buildSpy();
      await pumpPage(tester, controller, const Size(1600, 900));

      expect(tiles(tester), isNotEmpty);
      expect(gridAspect(tester), GameTile.width / (GameTile.coverHeight + 68));
      expect(coverBox(tester), const Size(GameTile.width, GameTile.coverHeight));
      expect(controller.coverRequests, isNotEmpty);

      // A square window used to turn the whole wall into square posters; that
      // experiment is gone, so the geometry has to hold here too.
      await resizeWindow(tester, const Size(1000, 1000));
      expect(gridAspect(tester), GameTile.width / (GameTile.coverHeight + 68));
      expect(coverBox(tester), const Size(GameTile.width, GameTile.coverHeight));
    });

    testWidgets('resizing does not re-ask for artwork tile by tile', (tester) async {
      final controller = buildSpy();
      await pumpPage(tester, controller, const Size(1600, 900));
      final asked = controller.coverRequests.length;
      expect(asked, greaterThan(0));

      // Every window is a portrait wall now, so nothing about the posters
      // changes and no tile has a reason to ask again.
      await resizeWindow(tester, const Size(1500, 900));
      await resizeWindow(tester, const Size(1400, 880));
      await resizeWindow(tester, const Size(900, 900));
      expect(controller.coverRequests.length, asked);
    });

  });

  // ------------------------------------------------------------- sidebar

  group('sidebar', () {
    ArtSpy buildSpy() {
      final spy = ArtSpy(
        configPath: '${dir.path}/config.json',
        cachePath: '${dir.path}/games.json',
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
        config: AppConfig(appimageDirs: const []),
      );
      addTearDown(spy.dispose);
      spy.games = [
        game('flatpak:a', 'Alpha', SourceKind.flatpak),
        game('flatpak:b', 'Beta', SourceKind.flatpak),
        steamGame('7'),
      ];
      return spy;
    }

    /// Text inside the sidebar (the tiles carry the same source labels).
    Finder sidebarText(String text) =>
        find.descendant(of: find.byType(ListView), matching: find.text(text));

    testWidgets('folds to an icon rail, gives the wall the width, and remembers', (
      tester,
    ) async {
      final controller = buildSpy();
      await pumpPage(tester, controller, const Size(1400, 900));

      expect(sidebarText('All games'), findsOneWidget);
      expect(sidebarText('Flatpak'), findsOneWidget);
      final wide = tester.getSize(find.byType(GridView)).width;

      await tester.tap(find.byTooltip('Collapse the sidebar'));
      await tester.pumpAndSettle();

      // The labels go, the filters stay.
      expect(find.byTooltip('Expand the sidebar'), findsOneWidget);
      expect(sidebarText('All games'), findsNothing);
      expect(sidebarText('Flatpak'), findsNothing);
      expect(find.byIcon(Icons.apps), findsOneWidget);
      expect(find.byTooltip('Flatpak · 2'), findsOneWidget);
      expect(
        tester.getSize(find.byType(GridView)).width - wide,
        168,
        reason: 'the 232px sidebar folds to a 64px rail',
      );
      expect(AppConfig.load('${dir.path}/config.json').sidebarCollapsed, isTrue);

      await tester.tap(find.byTooltip('Expand the sidebar'));
      await tester.pumpAndSettle();

      expect(sidebarText('All games'), findsOneWidget);
      expect(tester.getSize(find.byType(GridView)).width, wide);
      expect(AppConfig.load('${dir.path}/config.json').sidebarCollapsed, isFalse);
    });

    testWidgets('a source is still pickable from the rail', (tester) async {
      final controller = buildSpy();
      await pumpPage(tester, controller, const Size(1400, 900));
      await tester.tap(find.byTooltip('Collapse the sidebar'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Flatpak · 2'));
      await tester.pumpAndSettle();

      expect(controller.sourceFilter, {SourceKind.flatpak});
      expect(
        controller.visibleGames.map((game) => game.id).toSet(),
        {'flatpak:a', 'flatpak:b'},
      );
    });

    testWidgets('Show hidden is reachable while folded', (tester) async {
      final controller = buildSpy();
      controller.setHidden(controller.games.first, hidden: true);
      await pumpPage(tester, controller, const Size(1400, 900));
      await tester.tap(find.byTooltip('Collapse the sidebar'));
      await tester.pumpAndSettle();

      expect(controller.visibleGames.length, 2);
      await tester.tap(find.byTooltip('Show hidden games (1)'));
      await tester.pumpAndSettle();

      expect(controller.config.showHidden, isTrue);
      expect(controller.visibleGames.length, 3);
    });
  });

  // ------------------------------------------------------------ art pick

  group('art pick in the window', () {
    testWidgets('a failed pick is shown in the dialog and leaves it usable', (tester) async {
      final spy = ArtSpy(
        configPath: '${dir.path}/config.json',
        cachePath: '${dir.path}/games.json',
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
        config: AppConfig(appimageDirs: const [], steamgriddbKey: 'key'),
      );
      addTearDown(spy.dispose);
      spy.games = [game('flatpak:a', 'Alpha', SourceKind.flatpak)];
      spy.candidates = [
        // Nothing is listening on port 1, so the download cannot succeed.
        const SgdbGrid(
          id: 7,
          url: 'http://127.0.0.1:1/grid.png',
          thumb: 'http://127.0.0.1:1/thumb.png',
        ),
      ];
      // Wide enough for the panel and the status bar next to each other.
      await pumpPage(tester, spy, const Size(1700, 1700));
      spy.select(spy.games.first);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Game actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find art (SteamGridDB)'));
      await tester.pumpAndSettle();

      final candidate = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Image),
      );
      expect(candidate, findsOneWidget);
      await tester.tap(candidate);
      await tester.pumpAndSettle();

      // The status bar is behind the modal, so the dialog has to say it.
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.textContaining('artwork download failed'),
        ),
        findsOneWidget,
      );
      // And "applying" is over: no spinner, candidates clickable again.
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      final ink = tester.widget<InkWell>(
        find.ancestor(of: candidate, matching: find.byType(InkWell)),
      );
      expect(ink.onTap, isNotNull);
    });

    testWidgets('a pick reaches the tile and the panel at once', (tester) async {
      final art = File('${dir.path}/cover.png')..writeAsBytesSync([1, 2, 3]);
      final controller = LibraryController(
        configPath: '${dir.path}/config.json',
        cachePath: '${dir.path}/games.json',
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
        config: AppConfig(appimageDirs: const [], artOverrides: {'flatpak:a': art.path}),
      );
      addTearDown(controller.dispose);
      controller.games = [game('flatpak:a', 'Alpha', SourceKind.flatpak)];
      await pumpPage(tester, controller, const Size(1600, 900));
      controller.select(controller.games.first);
      await tester.pumpAndSettle();

      // Both the tile and the panel preview show the pinned file.
      expect(shownCoverPaths(tester), [art.path, art.path]);

      // Resetting is the override change a pick makes, without the download.
      controller.clearArt(controller.games.first);
      await tester.pumpAndSettle();
      expect(shownCoverPaths(tester), isEmpty);

      // And the other way round: art pinned after the tile was built. This is
      // the state a successful pick leaves behind.
      controller.covers.settings = ArtSettings(overrides: {'flatpak:a': art.path});
      controller.select(controller.games.first);
      await tester.pumpAndSettle();
      expect(shownCoverPaths(tester), [art.path, art.path]);
    });
  });

  // ------------------------------------------------------------ epic source

  group('epic source', () {
    String root() => '${dir.path}/eglv2';

    String folderFor(String artifactId) => '${dir.path}/games/$artifactId';


    Map<String, Object?> install({
      String installationId = 'ID-1',
      String namespace = 'c4763f236d08423eb47b4c3008779c84',
      String itemId = '93f2a8c3547846eda966cb3c152a026e',
      String artifactId = 'dc9d2e595d0e4650b35d659f90d41059',
      String? dir,
      String executable = 'AlanWake2.exe',
      bool complete = true,
    }) => {
      'installationId': installationId,
      'namespace': namespace,
      'itemId': itemId,
      'artifactId': artifactId,
      'dir': dir ?? folderFor(artifactId),
      'launchExecutable': executable,
      'platform': 'Windows',
      'complete': complete,
    };

    /// The launcher's append-only log: a header line, then one line per change.
    void writeLog(List<Object?> lines) {
      File('${root()}/installations.jsonl')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync([
          '{"version":1,"writtenAt":"2026-10-14T18:09:05Z","entries":${lines.length}}',
          for (final line in lines) line is String ? line : jsonEncode(line),
          '',
        ].join('\n'));
    }

    void writeCatalog(Map<String, String> titles) {
      File('${root()}/cache/prod/catalog-cache.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'items': {
              for (final entry in titles.entries)
                entry.key: {
                  'item': {'title': entry.value},
                },
            },
          }),
        );
    }

    Future<List<Game>> discover() => EpicSource(dataRoot: root()).discover(AppConfig());

    test('takes the last state per installation and names it from the catalog', () async {
      writeCatalog({'93f2a8c3547846eda966cb3c152a026e': 'Alan Wake 2'});
      writeLog([
        install(complete: false, executable: 'Installing.exe'),
        // A half written append must not take the record down with it.
        '{"installationId":"ID-1","complete":',
        install(complete: true),
      ]);

      final games = await discover();

      expect(games, hasLength(1));
      final game = games.single;
      expect(game.id, 'epic:dc9d2e595d0e4650b35d659f90d41059');
      expect(game.key, 'dc9d2e595d0e4650b35d659f90d41059');
      expect(game.source, SourceKind.epic);
      expect(game.name, 'Alan Wake 2');
      expect(game.subtitle, SourceKind.epic.label);
      expect(game.command, [
        'xdg-open',
        'com.epicgames.launcher://apps/'
            'c4763f236d08423eb47b4c3008779c84%3A93f2a8c3547846eda966cb3c152a026e%3A'
            'dc9d2e595d0e4650b35d659f90d41059?action=launch&silent=true',
      ]);
      expect(game.extra['complete'], isTrue);
      expect(game.extra['itemId'], '93f2a8c3547846eda966cb3c152a026e');
      expect(game.extra['platform'], 'Windows');
      // The folder is only offered when it is really there.
      expect(game.path, isNull);
      final folder = folderFor('dc9d2e595d0e4650b35d659f90d41059');
      Directory(folder).createSync(recursive: true);
      expect((await discover()).single.path, folder);
    });

    test('names a game without a catalog title from what the record has', () async {
      writeLog([
        install(installationId: 'A', artifactId: 'alpha', executable: ''),
        install(installationId: 'B', artifactId: 'beta', executable: 'Beta.exe'),
        install(installationId: 'C', artifactId: 'gamma', executable: '', dir: ''),
      ]);

      final names = {
        for (final game in await discover()) game.key: game.name,
      };

      expect(names, {
        'alpha': 'alpha', // no title and no executable: the app name itself
        'beta': 'Beta', // the executable without its extension
        'gamma': 'gamma', // no folder either, so the app name again
      });
    });

    test('keeps one entry per app and skips what it cannot launch', () async {
      writeLog([
        install(installationId: 'A', artifactId: 'same'),
        install(installationId: 'B', artifactId: 'same'),
        install(artifactId: ''), // nothing to launch
        {'installationId': 'C'}, // a record with no fields at all
        'not json at all',
        '[]', // a line that is not an object
        '${jsonEncode(install(installationId: 'D', artifactId: 'crlf'))}\r',
      ]);

      final games = await discover();

      // One entry per app name, and a Windows line ending does not hide one.
      expect(games.map((game) => game.key), ['same', 'crlf']);
    });

    test('an installation with no namespace falls back to the short uri', () async {
      writeLog([install(namespace: '', itemId: '', artifactId: 'shortname')]);

      final games = await discover();

      expect(games.single.command, [
        'xdg-open',
        'com.epicgames.launcher://apps/shortname?action=launch',
      ]);
    });

    test('nothing installed, or nothing readable, is no games at all', () async {
      expect(await discover(), isEmpty);

      writeLog([install()]);
      File('${root()}/cache/prod/catalog-cache.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{ not json');
      expect(await discover(), hasLength(1));
    });

    test('the registry and the source kind are wired up', () {
      expect(SourceKind.epic.id, 'epic');
      expect(SourceKind.epic.label, isNotEmpty);
      expect(
        buildSources().map((source) => source.kind),
        contains(SourceKind.epic),
      );
      // The real launcher state lives under the XDG data home.
      expect(EpicSource().dataRoot, endsWith('/com.epicgames.eglv2'));
      expect(EpicSource().dataRoot, contains('share'));
    });
  });
}

/// A source that hands back a fixed list, for scan tests that must not depend
/// on what is installed.
class _FixedSource extends GameSource {
  _FixedSource(this.kind, this.games);

  @override
  final SourceKind kind;

  final List<Game> games;

  @override
  Future<List<Game>> discover(AppConfig cfg) async => games;
}
