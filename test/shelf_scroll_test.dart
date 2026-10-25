import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/library_page.dart';
import 'package:omni_launcher/src/ui/theme.dart';

Game game(String id, String name) => Game(
  id: id,
  key: id.split(':').last,
  name: name,
  source: SourceKind.steam,
  command: const ['true'],
);

void main() {
  late Directory dir;
  late String configPath;
  late String playtimePath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-shelf-scroll');
    configPath = '${dir.path}/config.json';
    playtimePath = '${dir.path}/playtime.json';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  void seed(List<Game> games, {int played = 0}) {
    File(playtimePath).writeAsStringSync(
      jsonEncode({
        for (final entry in games.take(played))
          entry.id: {
            'total': 600,
            'played': DateTime.now().millisecondsSinceEpoch,
          },
      }),
    );
  }

  LibraryController build() => LibraryController(
    configPath: configPath,
    cachePath: '${dir.path}/games.json',
    config: AppConfig(appimageDirs: const []),
    playtime: PlaytimeStore(path: playtimePath),
  );

  Future<LibraryController> pumpPage(
    WidgetTester tester, {
    required List<Game> games,
    int played = 0,
    Size size = const Size(1400, 900),
  }) async {
    seed(games, played: played);
    final controller = build();
    addTearDown(controller.dispose);
    controller.games = games;

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => LibraryPage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  /// Tap [tile] and let the panel open, stopping just before the selection's
  /// reveal runs. A tile waits out the double-tap window before it selects.
  Future<void> selectAndOpenPanel(
    WidgetTester tester,
    Finder tile, {
    required String gameId,
    required LibraryController controller,
  }) async {
    await tester.tap(tile);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
    expect(controller.selected?.id, gameId);
    // The panel's width animation starts on the next frame.
    await tester.pump();
    // Stop at its end: the reveal starts as it settles, before the scroll has
    // moved the tile.
    await tester.pump(const Duration(milliseconds: 201));
  }

  Finder shelfTile(String gameId) => find.byKey(ValueKey('recent:$gameId'));

  Finder wallTile(String gameId) => find.byKey(ValueKey(gameId));

  Finder shelfList() => find.byWidgetPredicate(
    (widget) => widget is ListView && widget.scrollDirection == Axis.horizontal,
  );

  group('the shelf scrollbar', () {
    testWidgets('is not drawn when the row already fits', (tester) async {
      final games = [for (var i = 0; i < 3; i++) game('steam:$i', 'Game $i')];
      await pumpPage(tester, games: games, played: 2);

      final bar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      expect(bar.thumbVisibility, isFalse);
    });

    testWidgets('shows the rest of the row when it goes on', (tester) async {
      final games = [for (var i = 0; i < 12; i++) game('steam:$i', 'Game $i')];
      await pumpPage(tester, games: games, played: 10);

      final bar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      expect(bar.thumbVisibility, isTrue);

      // The bar is a way in, not just a hint: the row scrolls.
      final before = tester.getRect(shelfTile('steam:5'));
      await tester.drag(shelfList(), const Offset(-300, 0));
      await tester.pumpAndSettle();
      final after = tester.getRect(shelfTile('steam:5'));
      expect(after.left, lessThan(before.left));
      expect(
        tester.widget<Scrollbar>(find.byType(Scrollbar)).thumbVisibility,
        isTrue,
      );
    });
  });

  group('a selected tile when the detail panel opens', () {
    testWidgets('is brought back into the wall', (tester) async {
      final games = [for (var i = 0; i < 12; i++) game('steam:$i', 'Game $i')];
      final controller = await pumpPage(
        tester,
        games: games,
        size: const Size(1400, 900),
      );
      // Six columns without the panel, four with it: the ninth game moves
      // from the second row to the third, past the wall's viewport.
      final selected = games[8];

      await selectAndOpenPanel(
        tester,
        wallTile(selected.id),
        gameId: selected.id,
        controller: controller,
      );

      final wall = tester.getRect(find.byType(GridView));
      final clipped = tester.getRect(wallTile(selected.id));
      // The state the reveal exists for: the ring would be cut by the wall's
      // bottom edge here.
      expect(clipped.bottom, greaterThan(wall.bottom));

      await tester.pumpAndSettle();

      final tile = tester.getRect(wallTile(selected.id));
      expect(tile.top, greaterThanOrEqualTo(wall.top + 1));
      expect(tile.bottom, lessThanOrEqualTo(wall.bottom - 1));
    });

    testWidgets('is brought back into the shelf', (tester) async {
      final games = [for (var i = 0; i < 12; i++) game('steam:$i', 'Game $i')];
      final controller = await pumpPage(
        tester,
        games: games,
        played: 10,
        size: const Size(1100, 900),
      );
      // Ten recent games at this width: the fourth is still built, but once
      // the panel takes its share of the window its right edge — and the
      // ring on it — would be cut.
      final selected = games[3];

      await selectAndOpenPanel(
        tester,
        shelfTile(selected.id),
        gameId: selected.id,
        controller: controller,
      );

      final shelf = tester.getRect(shelfList());
      final clipped = tester.getRect(shelfTile(selected.id));
      expect(clipped.right, greaterThan(shelf.right));

      await tester.pumpAndSettle();

      final tile = tester.getRect(shelfTile(selected.id));
      expect(tile.left, greaterThanOrEqualTo(shelf.left));
      expect(tile.right, lessThanOrEqualTo(shelf.right));
    });
  });
}
