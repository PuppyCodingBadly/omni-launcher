import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/plugins/plugin.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/detail_panel.dart';
import 'package:omni_launcher/src/ui/game_tile.dart';
import 'package:omni_launcher/src/ui/library_page.dart';
import 'package:omni_launcher/src/ui/plugin_answer.dart';
import 'package:omni_launcher/src/ui/settings_view.dart';
import 'package:omni_launcher/src/ui/theme.dart';

const Game alpha = Game(
  id: 'steam:1',
  key: '1',
  name: 'Team Fortress 2',
  source: SourceKind.steam,
  command: ['true'],
);

const Game beta = Game(
  id: 'steam:2',
  key: '2',
  name: 'Accounting',
  source: SourceKind.steam,
  command: ['true'],
);

/// A source entry that outlived its files: not launchable any more.
const Game gone = Game(
  id: 'steam:3',
  key: '3',
  name: 'Gone Game',
  source: SourceKind.steam,
  command: ['true'],
  extra: {'missing': true},
);

/// A controller that pretends one game is running.
class _RunningController extends LibraryController {
  _RunningController({
    required super.configPath,
    required super.cachePath,
    required super.playtime,
    super.config,
  });

  final List<String> stopped = <String>[];

  @override
  bool isRunning(String gameId) => gameId == alpha.id;

  @override
  bool isStopping(String gameId) => false;

  @override
  void stop(Game game) => stopped.add(game.id);
}

void main() {
  late Directory dir;
  late LibraryController controller;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-features-ui');
    controller = LibraryController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );
    controller.games = [alpha, beta];
    controller.status = LibraryStatus.ready;
  });

  tearDown(() {
    controller.dispose();
    dir.deleteSync(recursive: true);
  });

  testWidgets('a running tile says so and offers Stop', (tester) async {
    final running = _RunningController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      config: AppConfig(appimageDirs: const []),
    );
    addTearDown(running.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: GameTile(game: alpha, controller: running, selected: false),
        ),
      ),
    );

    expect(find.text('PLAYING'), findsOneWidget);
  });

  testWidgets('a running game shows Stop in the detail panel', (tester) async {
    tester.view.physicalSize = const Size(420, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final running = _RunningController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      config: AppConfig(appimageDirs: const []),
    );
    addTearDown(running.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: ListenableBuilder(
            listenable: running,
            builder: (context, _) =>
                DetailPanel(controller: running, game: alpha),
          ),
        ),
      ),
    );

    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(running.stopped, [alpha.id]);
  });

  testWidgets('Ctrl+K opens the palette and Enter selects a game', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: LibraryPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'tf2');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Team Fortress 2'),
      ),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.selected?.id, alpha.id);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('the filter dialog toggles a tag filter', (tester) async {
    controller.setTags(beta.id, ['Puzzle']);
    // The saved notice's timer must not outlive the widget test.
    controller.notice = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: LibraryPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    expect(find.text('Puzzle'), findsOneWidget);

    await tester.tap(find.text('Puzzle'));
    await tester.pumpAndSettle();
    expect(controller.tagFilter, {'Puzzle'});
    expect(controller.visibleGames.map((game) => game.id).toList(), [beta.id]);
  });

  testWidgets('Settings switches hiding and tray on', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = LibraryController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      pluginDir: '${dir.path}/plugins',
    );
    addTearDown(settings.dispose);
    settings.catalogFailure = 'offline';

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => SettingsView(controller: settings),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hide the launcher while a game runs'));
    await tester.tap(find.text('Show a tray icon'));
    await tester.pumpAndSettle();

    expect(settings.config.minimizeOnLaunch, isTrue);
    expect(settings.config.trayIcon, isTrue);
    settings.notice = null;
  });

  testWidgets('a missing game tile offers no working Play', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: GameTile(game: gone, controller: controller, selected: false),
        ),
      ),
    );
    await tester.pump();

    // The cover still shows the button, but as a disabled target: the panel
    // is where the user learns the game is missing.
    final play = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Play'),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      ),
    );
    expect(play.onPressed, isNull);

    // And the actions menu does not pretend a launch is possible.
    final menu = tester.widget<PopupMenuButton<String>>(
      find.byType(PopupMenuButton<String>),
    );
    final entries = menu
        .itemBuilder(tester.element(find.byType(GameTile)))
        .whereType<PopupMenuItem<String>>()
        .map((item) => item.value);
    expect(entries, isNot(contains('launch')));
    expect(entries, contains('rename'));
  });

  testWidgets('a tag filter that matches nothing reads as filtered', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    controller.toggleTag('Nowhere');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: LibraryPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // An empty wall under an active filter is not an empty library: the
    // rescan hint would send the user after a problem they do not have.
    expect(find.text('No game matches these filters.'), findsOneWidget);
    expect(find.text('No games yet'), findsNothing);
    expect(find.text('Try Rescan, or add a game by hand.'), findsNothing);
  });

  testWidgets('a plugin result dialog scrolls a long answer', (tester) async {
    tester.view.physicalSize = const Size(700, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const plugin = Plugin(
      id: 'many',
      name: 'Many',
      description: '',
      action: 'Look up',
      command: ['true'],
      dir: '/tmp/many',
    );
    const action = PluginAction(id: 'show', name: 'Show');
    final answer = PluginAnswer(
      fields: [
        for (var i = 0; i < 30; i++)
          PluginField(label: 'Field $i', value: 'Value $i'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showPluginResultDialog(
                  context,
                  plugin: plugin,
                  action: action,
                  answer: answer,
                ),
                child: const Text('Show result'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show result'));
    await tester.pumpAndSettle();

    // Many fields must scroll inside the dialog, not overflow it.
    expect(tester.takeException(), isNull);
    expect(find.text('FIELD 0'), findsOneWidget);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
