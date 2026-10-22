import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/game_tile.dart';
import 'package:omni_launcher/src/ui/library_page.dart';
import 'package:omni_launcher/src/ui/theme.dart';

const Game alpha = Game(
  id: 'flatpak:alpha',
  key: 'alpha',
  name: 'Alpha',
  source: SourceKind.flatpak,
  command: ['true'],
);

class _LaunchSpy extends LibraryController {
  _LaunchSpy({
    required super.configPath,
    required super.cachePath,
    required super.playtime,
    super.config,
  });

  final List<String> launched = <String>[];

  @override
  Future<void> launch(Game game) async {
    launched.add(game.id);
  }
}

void main() {
  group('tile focus', () {
    late Directory dir;
    late _LaunchSpy controller;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omni-tile-focus');
      File('${dir.path}/games.json')
          .writeAsStringSync(jsonEncode([alpha.toJson()]));
      controller = _LaunchSpy(
        configPath: '${dir.path}/config.json',
        cachePath: '${dir.path}/games.json',
        config: AppConfig(appimageDirs: const []),
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      );
    });

    tearDown(() {
      controller.dispose();
      dir.deleteSync(recursive: true);
    });

    /// The cover's shadow: hover and focus lift it, and the lift is how a
    /// focused tile reads.
    double shadowBlur(WidgetTester tester) {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byType(GameTile),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final decoration = container.decoration as BoxDecoration;
      return decoration.boxShadow!.single.blurRadius;
    }

    testWidgets('a focused tile draws its hover state and Enter launches', (
      tester,
    ) async {
      await controller.load(refresh: false);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Center(
              child: GameTile(
                game: controller.games.single,
                controller: controller,
                selected: false,
                focusNode: focusNode,
              ),
            ),
          ),
        ),
      );

      final resting = shadowBlur(tester);
      focusNode.requestFocus();
      // Focus only draws for keyboard/gamepad focus: a bare requestFocus
      // leaves the highlight mode at touch, so the tile is focused but not
      // highlighted. A key event — the wall's real d-pad gesture — flips the
      // mode and lifts the cover.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(focusNode.hasFocus, isTrue);
      expect(shadowBlur(tester), greaterThan(resting));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.launched, [alpha.id]);
      expect(controller.selected, isNull);

      // The gamepad's B button selects instead.
      controller.select(null);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await tester.pump();
      expect(controller.selected?.id, alpha.id);
    });

    testWidgets('a tile without a node still takes focus and keys', (
      tester,
    ) async {
      await controller.load(refresh: false);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Center(
              child: GameTile(
                game: controller.games.single,
                controller: controller,
                selected: false,
              ),
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(GameTile),
          matching: find.byType(FocusableActionDetector),
        ),
        findsOneWidget,
      );

      // The only focusable widget here, so Tab lands on the tile.
      final resting = shadowBlur(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(shadowBlur(tester), greaterThan(resting));

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.selected?.id, alpha.id);
    });

    testWidgets(
      'an arrow walk past the built viewport scrolls the wall and moves focus',
      (tester) async {
        // A wall far taller than the window: the grid builds only the rows
        // on screen, so the walk below has to bring the destination in.
        controller.games = [
          for (var index = 0; index < 40; index++)
            Game(
              id: 'flatpak:g$index',
              key: 'g$index',
              name: 'Game ${index.toString().padLeft(2, '0')}',
              source: SourceKind.flatpak,
              command: const ['true'],
            ),
        ];

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(900, 600);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: LibraryPage(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        final wall = find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        );
        expect(wall, findsOneWidget);
        double offset() => tester.state<ScrollableState>(wall).position.pixels;
        expect(offset(), 0);

        // Only the first rows exist; the walk goes well past them.
        final builtBefore = tester
            .widgetList<GameTile>(find.byType(GameTile))
            .length;

        for (var step = 0; step < 12; step++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
        }

        // The walk reached a tile that was not built when it started...
        final focused = FocusManager.instance.primaryFocus;
        expect(focused, isNotNull);
        final focusedTile = tester
            .widgetList<GameTile>(find.byType(GameTile))
            .singleWhere((tile) => identical(tile.focusNode, focused));
        final focusedIndex = controller.visibleGames.indexWhere(
          (game) => game.id == focusedTile.game.id,
        );
        expect(focusedIndex, greaterThan(builtBefore - 1));
        // ...and the wall scrolled to bring it in.
        expect(offset(), greaterThan(0));
      },
    );
  });
}
