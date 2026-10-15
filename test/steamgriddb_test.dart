import 'dart:convert';

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
}
