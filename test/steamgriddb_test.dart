import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/art/steamgriddb.dart';

/// A real `/grids/steam/<appid>` response body, trimmed to the fields we read.
const String gridResponse = '''
{
  "success": true,
  "data": [
    {
      "id": 372951,
      "score": 100,
      "style": "alternate",
      "url": "https://cdn2.steamgriddb.com/grid/0f0d0f0d.png",
      "thumb": "https://cdn2.steamgriddb.com/thumb/0f0d0f0d.jpg",
      "width": 600,
      "height": 900,
      "mime": "image/png",
      "author": {"name": "someone", "steam64": "7656119"}
    },
    {
      "id": 372952,
      "url": "https://cdn2.steamgriddb.com/grid/abcdef.jpeg",
      "thumb": "",
      "width": 460,
      "height": 215,
      "mime": "image/jpeg"
    }
  ]
}
''';

void main() {
  group('SteamGridDB payloads', () {
    test('parses grids, preferring the real thumb and keeping mime/author', () {
      final decoded = jsonDecode(gridResponse) as Map<String, Object?>;
      final grids = (decoded['data'] as List)
          .cast<Map<String, Object?>>()
          .map(SgdbGrid.fromJson)
          .whereType<SgdbGrid>()
          .toList();

      expect(grids, hasLength(2));
      expect(grids.first.id, 372951);
      expect(grids.first.thumb, 'https://cdn2.steamgriddb.com/thumb/0f0d0f0d.jpg');
      expect(grids.first.width, 600);
      expect(grids.first.height, 900);
      expect(grids.first.style, 'alternate');
      expect(grids.first.author, 'someone');
      expect(grids.first.extension, '.png');

      // An empty thumb falls back to the full image, the extension to the mime.
      expect(grids[1].thumb, 'https://cdn2.steamgriddb.com/grid/abcdef.jpeg');
      expect(grids[1].extension, '.jpg');
    });

    test('skips records without an id or url', () {
      expect(SgdbGrid.fromJson(const {'url': 'https://x/y.png'}), isNull);
      expect(SgdbGrid.fromJson(const {'id': 1}), isNull);
      expect(SgdbGrid.fromJson(const {'id': 1, 'url': ''}), isNull);
      expect(SgdbGrid.fromJson(const {'id': 1, 'url': 'https://x/y'}), isNotNull);
    });

    test('parses autocomplete hits', () {
      final data = jsonDecode(
        '{"success":true,"data":[{"id":5,"name":"Terraria","verified":true},'
        '{"name":"no id"}]}',
      ) as Map<String, Object?>;
      final games = (data['data'] as List)
          .cast<Map<String, Object?>>()
          .map(SgdbGame.fromJson)
          .whereType<SgdbGame>()
          .toList();
      expect(games, hasLength(1));
      expect(games.single.id, 5);
      expect(games.single.name, 'Terraria');
    });

    test('extension falls back from the url when the mime is unknown', () {
      const grid = SgdbGrid(
        id: 1,
        url: 'https://cdn.example/grid/thing.PNG',
        thumb: 'https://cdn.example/grid/thing.PNG',
      );
      expect(grid.extension, '.png');
      expect(
        const SgdbGrid(id: 2, url: 'https://cdn.example/grid/thing', thumb: '')
            .extension,
        '.jpg',
      );
    });

    test('a missing key is refused before any request', () async {
      final client = SteamGridDb(apiKey: '   ');
      expect(client.configured, isFalse);
      await expectLater(
        client.searchGames('terraria'),
        throwsA(isA<SteamGridDbException>()),
      );
      client.close();
    });
  });

  group('over the wire', () {
    setUp(() {
      // flutter_test answers every HttpClient with a canned 400; these tests
      // use a loopback server instead, and never leave the machine.
      HttpOverrides.global = null;
    });

    /// A server that answers with [answer], plus the requests it saw.
    Future<(HttpServer, List<HttpRequest>)> serve(
      void Function(HttpRequest request) answer,
    ) async {
      final seen = <HttpRequest>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        seen.add(request);
        answer(request);
      });
      addTearDown(() => server.close(force: true));
      return (server, seen);
    }

    test('a redirect is followed, but the API key stays behind', () async {
      final (server, seen) = await serve((request) {
        if (request.uri.path.startsWith('/grids')) {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/real');
        } else {
          request.response.write('{"success":true,"data":[]}');
        }
        request.response.close();
      });
      final client = SteamGridDb(
        apiKey: 'secret-key',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(client.close);

      final grids = await client.gridsForSteamApp(427410);

      expect(grids, isEmpty);
      expect(seen, hasLength(2));
      // The first request is the API and carries the key; the redirect target
      // is not www.steamgriddb.com, so the key does not follow it.
      expect(seen.first.headers.value('authorization'), 'Bearer secret-key');
      expect(seen.last.uri.path, '/real');
      expect(seen.last.headers.value('authorization'), isNull);
    });

    test('a redirect that never ends is refused', () async {
      var hops = 0;
      final (server, seen) = await serve((request) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/again/${++hops}',
        );
        request.response.close();
      });
      final client = SteamGridDb(
        apiKey: 'secret-key',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(client.close);

      await expectLater(
        client.gridsForSteamApp(427410),
        throwsA(isA<SteamGridDbException>()),
      );
      // The first request and the five redirects it was willing to follow.
      expect(seen, hasLength(6));
    });
  });
}
