import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/launcher.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/launch_log.dart';
import 'package:omni_launcher/src/ui/theme.dart';

const Game alpha = Game(
  id: 'steam:1',
  key: '1',
  name: 'Alpha',
  source: SourceKind.steam,
  command: ['true'],
);

const Game beta = Game(
  id: 'steam:2',
  key: '2',
  name: 'Beta',
  source: SourceKind.steam,
  command: ['true'],
);

void main() {
  late Directory dir;
  late LibraryController controller;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-launch-log');
    Launcher.logPathOverrideForTest = '${dir.path}/launch.log';
    controller = LibraryController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );
    controller.games = [alpha, beta];
  });

  tearDown(() {
    controller.dispose();
    Launcher.logPathOverrideForTest = null;
    dir.deleteSync(recursive: true);
  });

  Future<void> openLog(WidgetTester tester, Game game) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showLaunchLogDialog(
                context,
                controller: controller,
                game: game,
              ),
              child: const Text('Log'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Log'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  String body(WidgetTester tester) =>
      tester.widget<SelectableText>(find.byType(SelectableText)).data!;

  TextButton copyButton(WidgetTester tester) => tester.widget<TextButton>(
    find.ancestor(of: find.text('Copy'), matching: find.byType(TextButton)),
  );

  testWidgets('a game with a log shows its launch and what it printed', (
    tester,
  ) async {
    File('${dir.path}/launch.log').writeAsStringSync(
      '2026-10-28T09:00:00.000000 launched steam:1 pid=4242 :: '
      'steam -applaunch 1\n'
      'alpha says hello\n'
      '2026-10-28T09:05:00.000000 launched steam:2 pid=4343 :: '
      'steam -applaunch 2\n'
      'beta says hello\n',
    );

    await openLog(tester, alpha);
    expect(find.text('Launch log: Alpha'), findsOneWidget);
    expect(body(tester), contains('steam -applaunch 1'));
    expect(body(tester), contains('alpha says hello'));
    expect(copyButton(tester).onPressed, isNotNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    // Beta's tail starts at its own launch line, not before it.
    await openLog(tester, beta);
    expect(find.text('Launch log: Beta'), findsOneWidget);
    expect(body(tester), contains('beta says hello'));
    expect(body(tester), isNot(contains('alpha says hello')));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets('a game without a log gets the empty state and no Copy', (
    tester,
  ) async {
    await openLog(tester, alpha);

    expect(find.text('Launch log: Alpha'), findsOneWidget);
    expect(body(tester), 'Nothing logged for this game yet.');
    expect(copyButton(tester).onPressed, isNull);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
