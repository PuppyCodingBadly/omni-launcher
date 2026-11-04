import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/filter_dialog.dart';
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
    dir = Directory.systemTemp.createTempSync('omni-filter-dialog');
    controller = LibraryController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );
    controller.games = [alpha, beta];
    controller.setTags(alpha.id, ['Puzzle']);
    controller.setTags(beta.id, ['Puzzle', 'Co-op']);
    // The saved notice's timer must not outlive the widget test.
    controller.notice = null;
  });

  tearDown(() {
    controller.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> openFilters(WidgetTester tester, LibraryController owner) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showFilterDialog(context, controller: owner),
              child: const Text('Filters'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  List<String> visibleIds() => [
    for (final game in controller.visibleGames) game.id,
  ];

  testWidgets('tag filters stack as AND and Clear all resets', (tester) async {
    await openFilters(tester, controller);
    expect(visibleIds(), ['steam:1', 'steam:2']);

    await tester.tap(find.text('Puzzle'));
    await tester.pumpAndSettle();
    expect(controller.tagFilter, {'Puzzle'});
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Puzzle'),
          )
          .value,
      isTrue,
    );
    expect(visibleIds(), ['steam:1', 'steam:2']);

    // A second tag narrows further: only Beta carries both.
    await tester.tap(find.text('Co-op'));
    await tester.pumpAndSettle();
    expect(controller.tagFilter, {'Puzzle', 'Co-op'});
    expect(visibleIds(), ['steam:2']);

    // Toggling one back off widens the wall again.
    await tester.tap(find.text('Co-op'));
    await tester.pumpAndSettle();
    expect(controller.tagFilter, {'Puzzle'});
    expect(visibleIds(), ['steam:1', 'steam:2']);

    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();
    expect(controller.tagFilter, isEmpty);
    expect(visibleIds(), ['steam:1', 'steam:2']);
  });

  testWidgets('a smart filter stacks with the tag filters', (tester) async {
    await openFilters(tester, controller);

    await tester.tap(find.text('Not played in 90 days'));
    await tester.pumpAndSettle();
    expect(controller.smartFilters, {SmartFilter.notRecent});
    expect(visibleIds(), ['steam:1', 'steam:2']);

    // The tag narrows the status filter: only Beta carries both.
    await tester.tap(find.text('Co-op'));
    await tester.pumpAndSettle();
    expect(controller.tagFilter, {'Co-op'});
    expect(visibleIds(), ['steam:2']);

    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();
    expect(controller.smartFilters, isEmpty);
    expect(controller.tagFilter, isEmpty);
    expect(visibleIds(), ['steam:1', 'steam:2']);
  });

  testWidgets('a library without tags says so and offers nothing to clear', (
    tester,
  ) async {
    final plain = LibraryController(
      configPath: '${dir.path}/plain-config.json',
      cachePath: '${dir.path}/plain-games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/plain-playtime.json'),
    );
    addTearDown(plain.dispose);
    plain.games = [alpha];

    await openFilters(tester, plain);

    expect(find.text('No tags yet. Add them from a game’s cog.'), findsOneWidget);
    expect(find.text('Clear all'), findsNothing);

    // A smart filter alone is enough to offer the reset.
    await tester.tap(find.text('Unplayed'));
    await tester.pumpAndSettle();
    expect(plain.smartFilters, {SmartFilter.unplayed});
    expect(find.text('Clear all'), findsOneWidget);
  });
}
