import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/covers.dart';
import 'package:omni_launcher/src/host.dart';
import 'package:omni_launcher/src/model/game.dart';

Game steamGame(String appid) => Game(
  id: 'steam:$appid',
  key: appid,
  name: 'Game $appid',
  source: SourceKind.steam,
  command: const ['steam', '-applaunch'],
  extra: {'appid': appid},
);

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-covers');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('cached capsules', () {
    test('a cached capsule is returned without touching the network', () async {
      Directory('${dir.path}/covers').createSync(recursive: true);
      final cached = File('${dir.path}/covers/steam_900401.jpg')
        // Big enough to pass the truncated-cache check.
        ..writeAsBytesSync(List<int>.filled(8192, 7));
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests++;
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      final store = CoverStore(
        settings: const ArtSettings(),
        coverDir: '${dir.path}/covers',
        cdnBase: 'http://127.0.0.1:${server.port}',
      );

      final artwork = await store.fetchSteamCover(steamGame('900401'));
      store.close();
      await server.close(force: true);

      expect(artwork?.kind, ArtworkKind.cover);
      expect(artwork?.value, cached.path);
      // The cache hit short circuited before any request was made.
      expect(requests, 0);
    });

    test('a second fetch while one is in flight asks the CDN once', () async {
      final gate = Completer<void>();
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests++;
        await gate.future;
        request.response
          ..headers.contentType = ContentType.binary
          ..add(List<int>.filled(8192, 7));
        await request.response.close();
      });
      final store = CoverStore(
        settings: const ArtSettings(),
        coverDir: '${dir.path}/covers',
        cdnBase: 'http://127.0.0.1:${server.port}',
      );
      final game = steamGame('900402');

      final first = store.fetchSteamCover(game);
      // Let the first fetch reach the server before the second is asked.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, 1);

      // The download is already in flight, so the second call is a no-op
      // rather than a duplicate request.
      expect(await store.fetchSteamCover(game), isNull);
      expect(requests, 1);

      gate.complete();
      final artwork = await first;
      store.close();
      await server.close(force: true);

      expect(artwork?.kind, ArtworkKind.cover);
      expect(
        File('${dir.path}/covers/steam_900402.jpg').existsSync(),
        isTrue,
      );
      expect(requests, 1);
    });
  });

  group('theme icons', () {
    late Directory mount;

    setUp(() {
      mount = Directory.systemTemp.createTempSync('omni-covers-icons');
      // The icon themes are read through the host mount, so a stand-in tree
      // keeps the test out of the machine's real icons.
      Host.setInFlatpakForTest(true);
      Host.setMountForTest(mount.path);
    });

    tearDown(() {
      Host.setInFlatpakForTest(null);
      Host.setMountForTest(null);
      mount.deleteSync(recursive: true);
    });

    test('an icon theme name resolves to its raster file', () {
      final png = File(
        '${mount.path}/usr/share/icons/hicolor/256x256/apps/omnitesticon.png',
      )
        ..createSync(recursive: true)
        ..writeAsBytesSync([137, 80, 78, 71]);
      // A vector icon cannot be drawn, so it must not resolve.
      File('${mount.path}/usr/share/icons/hicolor/scalable/apps/omnitestvec.svg')
        ..createSync(recursive: true)
        ..writeAsStringSync('<svg/>');

      final store = CoverStore(coverDir: '${mount.path}/covers');

      expect(store.themeIconPath('omnitesticon'), png.path);
      expect(store.themeIconPath('omnitestvec'), isNull);
      expect(store.themeIconPath('omnitest-not-there'), isNull);
    });

    test('a game whose icon is a theme name resolves as a named icon', () {
      final store = CoverStore(coverDir: '${mount.path}/covers');
      final game = Game(
        id: 'desktop:x',
        key: 'x',
        name: 'X',
        source: SourceKind.desktop,
        command: const ['true'],
        icon: 'omnitesticon',
        iconIsName: true,
      );

      final artwork = store.resolve(game);
      expect(artwork.kind, ArtworkKind.icon);
      expect(artwork.isName, isTrue);
      // resolve hands the name through; themeIconPath turns it into a path.
      expect(artwork.value, 'omnitesticon');
    });
  });

  group('SteamGridDB pins', () {
    test('a pinned pick survives re-resolve while its file exists', () {
      Directory('${dir.path}/covers').createSync(recursive: true);
      final pin = File('${dir.path}/covers/sgdb_steam_5_77.png')
        ..writeAsBytesSync([1, 2, 3]);
      final store = CoverStore(
        settings: ArtSettings(
          sgdbKey: 'key',
          overrides: {'steam:5': pin.path},
        ),
        coverDir: '${dir.path}/covers',
      );
      final game = steamGame('5');

      final first = store.resolve(game);
      expect(first.kind, ArtworkKind.cover);
      expect(first.value, pin.path);
      // The same answer comes back on the next resolve.
      expect(store.resolve(game).value, pin.path);
      // The pin is parsed as the grid it was downloaded from.
      expect(store.pinnedArtPath(game), pin.path);
      expect(store.pinnedGridId(game), 77);
      expect(store.canRefetchPin(game), isTrue);
    });

    test('a pin whose file went missing is fetched again', () async {
      final pinPath = '${dir.path}/covers/sgdb_steam_6_42.png';
      // The pin names a file that is no longer there.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/grid/42.png') {
          request.response
            ..headers.contentType = ContentType.binary
            ..add(List<int>.filled(64, 7));
        } else {
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              '{"success":true,"data":[{"id":42,'
              '"url":"http://127.0.0.1:${server.port}/grid/42.png"}]}',
            );
        }
        await request.response.close();
      });
      final store = CoverStore(
        settings: ArtSettings(
          sgdbKey: 'key',
          overrides: {'steam:6': pinPath},
        ),
        coverDir: '${dir.path}/covers',
        sgdbBase: 'http://127.0.0.1:${server.port}',
      );
      final game = steamGame('6');

      // The pin is a fact about the game, not about the file: with the file
      // gone the tile is pending again rather than the pick being forgotten.
      final before = store.resolve(game);
      expect(before.kind, ArtworkKind.letter);
      expect(before.pending, isTrue);
      expect(store.canRefetchPin(game), isTrue);

      final art = await store.refetchPinned(game);

      expect(art?.kind, ArtworkKind.cover);
      expect(art?.value, pinPath);
      // The grid came back at the path the pin has always named.
      expect(File(pinPath).existsSync(), isTrue);
      final after = store.resolve(game);
      expect(after.kind, ArtworkKind.cover);
      expect(after.value, pinPath);
      expect(after.pending, isFalse);

      store.close();
      await server.close(force: true);
    });

    test('a pin is not refetched without an API key', () async {
      final pinPath = '${dir.path}/covers/sgdb_steam_7_9.png';
      final store = CoverStore(
        settings: ArtSettings(overrides: {'steam:7': pinPath}),
        coverDir: '${dir.path}/covers',
      );
      final game = steamGame('7');

      expect(store.pinnedGridId(game), 9);
      expect(store.canRefetchPin(game), isFalse);
      expect(await store.refetchPinned(game), isNull);
    });
  });
}
