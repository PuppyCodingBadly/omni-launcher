import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/detail_panel.dart';
import 'package:omni_launcher/src/ui/game_tile.dart';
import 'package:omni_launcher/src/ui/rename_dialog.dart';
import 'package:omni_launcher/src/ui/theme.dart';

const Game alpha = Game(
  id: 'flatpak:alpha',
  key: 'alpha',
  name: 'Alpha',
  source: SourceKind.flatpak,
  command: ['true'],
);

/// A page with one button that opens the rename dialog.
Widget dialogHost(
  Future<void> Function(BuildContext context) open, {
  ThemeData? theme,
}) => MaterialApp(
  theme: theme ?? AppTheme.dark,
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(onPressed: () => open(context), child: const Text('open')),
      ),
    ),
  ),
);

void main() {
  group('renaming', () {
    late Directory dir;
    late String configPath;
    late String cachePath;
    late LibraryController controller;

    LibraryController build() => LibraryController(
      configPath: configPath,
      cachePath: cachePath,
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omni-rename');
      configPath = '${dir.path}/config.json';
      cachePath = '${dir.path}/games.json';
      // The cache is the list of games the launcher discovered.
      File(cachePath).writeAsStringSync(jsonEncode([alpha.toJson()]));
      controller = build();
    });

    tearDown(() {
      controller.dispose();
      dir.deleteSync(recursive: true);
    });

    test('renaming updates the library and the config', () async {
      await controller.load(refresh: false);
      expect(controller.games.single.name, 'Alpha');
      expect(controller.discoveredNameFor(alpha.id), 'Alpha');

      controller.setName(alpha.id, '  Beta  ');

      expect(controller.games.single.name, 'Beta');
      expect(controller.notice, 'Renamed to Beta');
      expect(AppConfig.load(configPath).nameOverrides, {alpha.id: 'Beta'});
      // What the launcher found stays known, for the reset hint.
      expect(controller.discoveredNameFor(alpha.id), 'Alpha');

      // The next start shows the rename before its rescan has finished.
      final again = LibraryController(
        configPath: configPath,
        cachePath: cachePath,
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      );
      addTearDown(again.dispose);
      await again.load(refresh: false);
      expect(again.games.single.name, 'Beta');
    });

    test('resetting restores the discovered name', () async {
      await controller.load(refresh: false);
      controller.setName(alpha.id, 'Beta');

      controller.setName(alpha.id, null);

      expect(controller.games.single.name, 'Alpha');
      expect(controller.notice, 'Name reset');
      expect(AppConfig.load(configPath).nameOverrides, isEmpty);
    });

    test('a blank name resets as well', () async {
      await controller.load(refresh: false);
      controller.setName(alpha.id, 'Beta');

      controller.setName(alpha.id, '   ');

      expect(controller.games.single.name, 'Alpha');
      expect(AppConfig.load(configPath).nameOverrides, isEmpty);
    });

    test('the selected game follows the rename', () async {
      await controller.load(refresh: false);
      controller.select(controller.games.single);

      controller.setName(alpha.id, 'Beta');

      expect(controller.selected?.name, 'Beta');
    });

    test('an unknown game has no discovered name', () {
      expect(controller.discoveredNameFor('nope:missing'), isNull);
    });
  });

  group('rename dialog', () {
    testWidgets('is prefilled with the effective name and saves it', (tester) async {
      RenameChoice? result;
      await tester.pumpWidget(
        dialogHost((context) async {
          result = await showRenameGameDialog(
            context,
            currentName: 'Alpha',
            discoveredName: 'Alpha',
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Alpha');
      expect(find.text('Reset'), findsNothing);

      await tester.enterText(find.byType(TextField), 'Beta');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result?.name, 'Beta');
      expect(result?.reset, isFalse);
    });

    testWidgets('says what the launcher found and offers a reset', (tester) async {
      RenameChoice? result;
      await tester.pumpWidget(
        dialogHost(
          (context) async {
            result = await showRenameGameDialog(
              context,
              currentName: 'Beta',
              discoveredName: 'Alpha',
            );
          },
          theme: AppTheme.light,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('found this game as "Alpha"'), findsOneWidget);

      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();

      expect(result?.reset, isTrue);
    });

    testWidgets('cancel chooses nothing', (tester) async {
      RenameChoice? result;
      await tester.pumpWidget(
        dialogHost((context) async {
          result = await showRenameGameDialog(
            context,
            currentName: 'Beta',
            discoveredName: 'Alpha',
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('an empty name is refused', (tester) async {
      RenameChoice? result;
      await tester.pumpWidget(
        dialogHost((context) async {
          result = await showRenameGameDialog(
            context,
            currentName: 'Alpha',
            discoveredName: 'Alpha',
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('A name is required'), findsOneWidget);
      expect(result, isNull);
      expect(find.byType(TextField), findsOneWidget);
    });
  });

  group('rename from the tile menu', () {
    late Directory dir;
    late String configPath;
    late String cachePath;
    late LibraryController controller;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omni-rename-tile');
      configPath = '${dir.path}/config.json';
      cachePath = '${dir.path}/games.json';
      File(cachePath).writeAsStringSync(jsonEncode([alpha.toJson()]));
      controller = LibraryController(
        configPath: configPath,
        cachePath: cachePath,
        config: AppConfig(appimageDirs: const []),
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      );
    });

    tearDown(() {
      controller.dispose();
      dir.deleteSync(recursive: true);
    });

    testWidgets('the hover menu renames the game', (tester) async {
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

      // The actions live in the hover overlay.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.byType(GameTile)));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);

      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.text('Rename game'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Beta');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(AppConfig.load(configPath).nameOverrides, {alpha.id: 'Beta'});
      expect(controller.games.single.name, 'Beta');
    });
  });

  group('rename in the panel', () {
    late Directory dir;
    late String configPath;
    late String cachePath;
    late LibraryController controller;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omni-rename-panel');
      configPath = '${dir.path}/config.json';
      cachePath = '${dir.path}/games.json';
      File(cachePath).writeAsStringSync(jsonEncode([alpha.toJson()]));
      controller = LibraryController(
        configPath: configPath,
        cachePath: cachePath,
        config: AppConfig(appimageDirs: const []),
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      );
    });

    tearDown(() {
      controller.dispose();
      dir.deleteSync(recursive: true);
    });

    testWidgets('the Rename button renames the game', (tester) async {
      // The panel scrolls; give it room so the buttons are laid out.
      tester.view.physicalSize = const Size(420, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await controller.load(refresh: false);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: DetailPanel(controller: controller, game: controller.games.single),
          ),
        ),
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(find.text('Rename game'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Alpha');

      await tester.enterText(find.byType(TextField), 'Beta');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(AppConfig.load(configPath).nameOverrides, {alpha.id: 'Beta'});
      expect(controller.games.single.name, 'Beta');
      expect(controller.notice, 'Renamed to Beta');
    });
  });
}
