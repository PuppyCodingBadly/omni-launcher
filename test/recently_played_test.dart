import 'dart:convert';
import 'dart:io';

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
  void seed(Map<String, (int, DateTime)> entries) => File(playtimePath)
      .writeAsStringSync(
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

    test('history for a game that is no longer in the library is not offered', () {
      seed({'steam:9': (60, DateTime(2026, 10, 15))});
      final controller = build();
      addTearDown(controller.dispose);
      controller.games = [game('steam:1', 'Alpha', SourceKind.steam)];

      expect(controller.recentlyPlayed(), isEmpty);
    });

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
    testWidgets('shows the played games small, and steps aside for a search', (
      tester,
    ) async {
      seed({
        'steam:1': (3600, DateTime.now()),
        'steam:2': (600, DateTime.now().subtract(const Duration(days: 2))),
      });
      final controller = build();
      addTearDown(controller.dispose);
      controller.games = [
        game('steam:1', 'Alpha', SourceKind.steam),
        game('steam:2', 'Beta', SourceKind.steam),
        game('flatpak:gamma', 'Gamma', SourceKind.flatpak),
      ];

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1700, 1000);
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
      expect(shelf.map((tile) => tile.game.id).toList(), ['steam:1', 'steam:2']);
      expect(shelf.every((tile) => tile.compact), isTrue);
      // A shelf tile says how much and how recently, not which source.
      expect(find.text('1h · today'), findsOneWidget);
      expect(find.text('10m · 2 days ago'), findsOneWidget);

      controller.setQuery('gamma');
      await tester.pumpAndSettle();
      expect(find.text('RECENTLY PLAYED'), findsNothing);
    });
  });
}
