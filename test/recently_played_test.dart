import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/game_tile.dart';
import 'package:omni_launcher/src/ui/library_page.dart';
import 'package:omni_launcher/src/ui/theme.dart';

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
  late String playtimePath;

  /// Write a playtime history: game id -> seconds played, and when it was last
  /// played. Anything not listed was never played.
  void seed(Map<String, (int, DateTime)> entries) =>
      File(playtimePath).writeAsStringSync(
        jsonEncode({
          for (final entry in entries.entries)
            entry.key: {
              'total': entry.value.$1,
              'played': entry.value.$2.millisecondsSinceEpoch,
            },
        }),
      );

  LibraryController build({AppConfig? config}) => LibraryController(
    configPath: configPath,
    cachePath: '${dir.path}/games.json',
    config: config ?? AppConfig(appimageDirs: const []),
    playtime: PlaytimeStore(path: playtimePath),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-recent');
    configPath = '${dir.path}/config.json';
    playtimePath = '${dir.path}/playtime.json';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('recentlyPlayed', () {
    test('newest first, and never a game that was not played', () {
      final now = DateTime(2026, 10, 15, 12);
      seed({
        'steam:1': (3600, now.subtract(const Duration(days: 3))),
        'steam:2': (60, now.subtract(const Duration(hours: 1))),
      });
      final controller = build();
      addTearDown(controller.dispose);
      controller.games = [
        game('steam:1', 'Alpha', SourceKind.steam),
        game('steam:2', 'Beta', SourceKind.steam),
        game('flatpak:gamma', 'Gamma', SourceKind.flatpak),
      ];

      expect(controller.recentlyPlayed().map((entry) => entry.id).toList(), [
        'steam:2',
        'steam:1',
      ]);
    });

    test('a caller that already computed the visible list hands it over', () {
      final now = DateTime(2026, 10, 15, 12);
      seed({
        'steam:1': (60, now.subtract(const Duration(hours: 1))),
        'steam:2': (60, now.subtract(const Duration(hours: 2))),
      });
      final controller = build();
      addTearDown(controller.dispose);
      controller.games = [
        game('steam:1', 'Alpha', SourceKind.steam),
        game('steam:2', 'Beta', SourceKind.steam),
      ];

      // The handed-over list is the one consulted: steam:1 was played more
      // recently, but it is not in it.
      expect(
        controller
            .recentlyPlayed(visible: [controller.games.last])
            .map((entry) => entry.id)
            .toList(),
        ['steam:2'],
      );
    });

    test(
      'history for a game that is no longer in the library is not offered',
      () {
        seed({'steam:9': (60, DateTime(2026, 10, 15))});
        final controller = build();
        addTearDown(controller.dispose);
        controller.games = [game('steam:1', 'Alpha', SourceKind.steam)];

        expect(controller.recentlyPlayed(), isEmpty);
      },
    );

    test('the shelf follows the wall: hidden games and the source filter', () {
      final now = DateTime(2026, 10, 15, 12);
      seed({
        'steam:1': (60, now.subtract(const Duration(hours: 1))),
        'steam:2': (60, now.subtract(const Duration(hours: 2))),
        'flatpak:gamma': (60, now.subtract(const Duration(hours: 3))),
      });
      final controller = build(config: AppConfig(hidden: {'steam:2'}));
      addTearDown(controller.dispose);
      controller.games = [
        game('steam:1', 'Alpha', SourceKind.steam),
        game('steam:2', 'Beta', SourceKind.steam),
        game('flatpak:gamma', 'Gamma', SourceKind.flatpak),
      ];

      expect(controller.recentlyPlayed().map((entry) => entry.id).toList(), [
        'steam:1',
        'flatpak:gamma',
      ]);

      controller.toggleSource(SourceKind.flatpak);
      expect(controller.recentlyPlayed().map((entry) => entry.id).toList(), [
        'flatpak:gamma',
      ]);

      controller.clearSources();
      controller.toggleShowHidden();
      expect(controller.recentlyPlayed().map((entry) => entry.id).toList(), [
        'steam:1',
        'steam:2',
        'flatpak:gamma',
      ]);
    });

    test('only the most recent handful, whatever the history holds', () {
      final now = DateTime(2026, 10, 15, 12);
      seed({
        for (var index = 0; index < 14; index++)
          'steam:$index': (60, now.subtract(Duration(hours: index))),
      });
      final controller = build();
      addTearDown(controller.dispose);
      controller.games = [
        for (var index = 0; index < 14; index++)
          game('steam:$index', 'Game $index', SourceKind.steam),
      ];

      final recent = controller.recentlyPlayed();
      expect(recent, hasLength(LibraryController.recentLimit));
      expect(recent.first.id, 'steam:0');
      expect(recent.last.id, 'steam:${LibraryController.recentLimit - 1}');

      expect(
        controller.recentlyPlayed(limit: 3).map((entry) => entry.id).toList(),
        ['steam:0', 'steam:1', 'steam:2'],
      );
    });
  });

  group('the shelf in the window', () {
    /// The page with two played games on the shelf and an unplayed one on the
    /// wall, in a window of [size].
    Future<LibraryController> pumpPage(
      WidgetTester tester, {
      Size size = const Size(1700, 1000),
      String newestName = 'Alpha',
    }) async {
      seed({
        'steam:1': (3600, DateTime.now()),
        'steam:2': (600, DateTime.now().subtract(const Duration(days: 2))),
      });
      final controller = build();
      addTearDown(controller.dispose);
      controller.games = [
        game('steam:1', newestName, SourceKind.steam),
        game('steam:2', 'Beta', SourceKind.steam),
        game('flatpak:gamma', 'Gamma', SourceKind.flatpak),
      ];

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

    testWidgets('shows the played games small, and steps aside for a search', (
      tester,
    ) async {
      final controller = await pumpPage(tester);

      expect(find.text('RECENTLY PLAYED'), findsOneWidget);
      // The two played games twice (shelf and wall), the unplayed one once.
      expect(find.byType(GameTile), findsNWidgets(5));

      final shelf = tester
          .widgetList<GameTile>(
            find.descendant(
              of: find.byType(ListView),
              matching: find.byType(GameTile),
            ),
          )
          .toList();
      expect(shelf.map((tile) => tile.game.id).toList(), [
        'steam:1',
        'steam:2',
      ]);
      expect(shelf.every((tile) => tile.compact), isTrue);
      // A shelf tile says how much and how recently, not which source.
      expect(find.text('1h · today'), findsOneWidget);
      expect(find.text('10m · 2 days ago'), findsOneWidget);

      controller.setQuery('gamma');
      await tester.pumpAndSettle();
      expect(find.text('RECENTLY PLAYED'), findsNothing);
    });

    testWidgets('grows with the platform text scale rather than clipping', (
      tester,
    ) async {
      // A large-text desktop: the labels grow, so the strip has to as well. An
      // overflow fails this test on its own.
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      await pumpPage(tester);

      expect(find.text('RECENTLY PLAYED'), findsOneWidget);
      expect(find.byType(GameTile), findsNWidgets(5));
    });

    testWidgets('a hovered shelf tile lifts inside the strip, ring and all', (
      tester,
    ) async {
      await pumpPage(tester);
      final shelfList = find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.horizontal,
      );
      final tile = find
          .descendant(of: shelfList, matching: find.byType(GameTile))
          .first;

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(tile));
      await tester.pumpAndSettle();

      final scale = tester
          .widget<AnimatedScale>(
            find.descendant(of: tile, matching: find.byType(AnimatedScale)),
          )
          .scale;
      expect(scale, greaterThan(1));
      final box = tester.getRect(tile);
      final lifted = Rect.fromCenter(
        center: box.center,
        width: box.width * scale,
        height: box.height * scale,
      );
      // The strip clips at its own bounds: a lift roomier than the strip took
      // the top of the cover and the selected cover's ring with it.
      final strip = tester.getRect(shelfList);
      expect(lifted.top, greaterThanOrEqualTo(strip.top));
      expect(lifted.bottom, lessThanOrEqualTo(strip.bottom));
    });

    testWidgets('steps aside in a window too short for it', (tester) async {
      // The strip and the wall cannot both have room here.
      await pumpPage(tester, size: const Size(1000, 380));

      expect(find.text('RECENTLY PLAYED'), findsNothing);
      expect(find.byType(GameTile), findsNWidgets(3));
    });

    testWidgets('a long name trails off instead of widening the tile', (
      tester,
    ) async {
      // The strip is a horizontal list, so a tile is handed as much width as it
      // asks for: a name that did not trail off made its tile wider than its
      // cover and pushed the next tile along, which is what made the row's
      // spacing uneven.
      const long = 'The Longest Game Title In The Whole Wide World';
      await pumpPage(tester, newestName: long);

      final shelf = tester
          .widgetList<GameTile>(
            find.descendant(
              of: find.byType(ListView),
              matching: find.byType(GameTile),
            ),
          )
          .toList();
      expect(shelf, hasLength(2));

      final lefts = <double>[];
      for (final tile in shelf) {
        final finder = find.byWidget(tile);
        expect(
          tester.getSize(finder).width,
          GameTile.compactWidth,
          reason: 'a shelf tile is no wider than its cover',
        );
        lefts.add(tester.getTopLeft(finder).dx);
      }
      // One gap between tiles, whatever the names are.
      expect(lefts[1] - lefts[0], GameTile.compactWidth + 16);

      // The name is ellipsized, not clipped: it takes the tile's width.
      expect(
        tester
            .getSize(
              find.descendant(
                of: find.byType(ListView),
                matching: find.text(long),
              ),
            )
            .width,
        GameTile.compactWidth,
      );
    });
  });
}
