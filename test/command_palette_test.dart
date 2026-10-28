import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/command_palette.dart';
import 'package:omni_launcher/src/ui/theme.dart';

const Game portal = Game(
  id: 'steam:1',
  key: '1',
  name: 'Portal',
  source: SourceKind.steam,
  command: ['true'],
);

const Game transportal = Game(
  id: 'steam:2',
  key: '2',
  name: 'Transportal',
  source: SourceKind.steam,
  command: ['true'],
);

const Game accounting = Game(
  id: 'steam:3',
  key: '3',
  name: 'Accounting',
  source: SourceKind.steam,
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
  late Directory dir;
  late _LaunchSpy controller;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-palette');
    controller = _LaunchSpy(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );
    controller.games = [portal, transportal, accounting];
  });

  tearDown(() {
    controller.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> openPalette(
    WidgetTester tester, {
    VoidCallback? onSettings,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showCommandPalette(
                context,
                controller: controller,
                onSettings: onSettings ?? () {},
                onAddGame: () async {},
              ),
              child: const Text('Palette'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Palette'));
    await tester.pumpAndSettle();
  }

  List<String?> tileTitles(WidgetTester tester) => [
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
      (tile.title! as Text).data,
  ];

  String? highlightedTitle(WidgetTester tester) => [
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
      if (tile.selected) (tile.title! as Text).data,
  ].single;

  testWidgets(
    'the query ranks a substring match over a non-match and Escape closes',
    (tester) async {
      await openPalette(tester);
      expect(find.byType(Dialog), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'port');
      await tester.pumpAndSettle();

      // A prefix of the name beats a mid-word substring; a non-match is gone.
      expect(tileTitles(tester), ['Portal', 'Transportal']);
      expect(find.text('Accounting'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(controller.selected, isNull);
    },
  );

  testWidgets('the arrows move the highlight and Enter opens the selection', (
    tester,
  ) async {
    await openPalette(tester);
    await tester.enterText(find.byType(TextField), 'port');
    await tester.pumpAndSettle();
    expect(highlightedTitle(tester), 'Portal');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(highlightedTitle(tester), 'Transportal');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(highlightedTitle(tester), 'Portal');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // Enter opens the highlighted game: it is selected, not launched.
    expect(controller.selected?.id, transportal.id);
    expect(controller.launched, isEmpty);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('Ctrl+Enter launches instead of opening', (tester) async {
    await openPalette(tester);
    await tester.enterText(find.byType(TextField), 'port');
    await tester.pumpAndSettle();
    expect(highlightedTitle(tester), 'Portal');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(controller.launched, [portal.id]);
    expect(controller.selected, isNull);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('commands are entries too: Enter runs the highlighted one', (
    tester,
  ) async {
    var settingsOpened = false;
    await openPalette(tester, onSettings: () => settingsOpened = true);

    // An empty query lists no games, only the commands.
    expect(tileTitles(tester).first, 'Open settings');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(settingsOpened, isTrue);
    expect(find.byType(Dialog), findsNothing);
  });
}
