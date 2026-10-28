import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/tag_dialog.dart';
import 'package:omni_launcher/src/ui/theme.dart';

const Game alpha = Game(
  id: 'steam:1',
  key: '1',
  name: 'Alpha',
  source: SourceKind.steam,
  command: ['true'],
);

/// A page with one button that opens the tag dialog, the same way the detail
/// panel's cog menu opens it from a real route.
Widget dialogHost(
  Future<void> Function(BuildContext context) open, {
  ThemeData? theme,
}) => MaterialApp(
  theme: theme ?? AppTheme.dark,
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  late Directory dir;
  late LibraryController controller;
  late bool returned;
  List<String>? result;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-tag-dialog');
    controller = LibraryController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );
    controller.games = [alpha];
    returned = false;
    result = null;
  });

  tearDown(() {
    controller.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> openTags(
    WidgetTester tester, {
    required List<String> manual,
    List<String> sourceTags = const [],
  }) async {
    await tester.pumpWidget(
      dialogHost((context) async {
        result = await showTagDialog(
          context,
          manual: manual,
          sourceTags: sourceTags,
        );
        returned = true;
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  testWidgets('adding tags saves them into the config', (tester) async {
    await openTags(tester, manual: const []);

    await tester.enterText(find.byType(TextField), 'Backlog, Co-op');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(returned, isTrue);
    expect(result, ['Backlog', 'Co-op']);

    // The detail panel hands the answer to the controller the same way.
    controller.setTags(alpha.id, result!);
    // The saved notice's timer must not outlive the widget test.
    controller.notice = null;
    expect(controller.tagsFor(alpha), ['Backlog', 'Co-op']);
    expect(AppConfig.load('${dir.path}/config.json').tagsFor(alpha.id), [
      'Backlog',
      'Co-op',
    ]);
  });

  testWidgets('removing a tag leaves the rest, blanks are dropped', (
    tester,
  ) async {
    await openTags(tester, manual: const ['Backlog', 'Co-op']);

    // The field opens with the current tags, comma separated.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Backlog, Co-op',
    );

    await tester.enterText(find.byType(TextField), 'Co-op,,  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, ['Co-op']);
    controller.setTags(alpha.id, result!);
    controller.notice = null;
    expect(AppConfig.load('${dir.path}/config.json').tagsFor(alpha.id), [
      'Co-op',
    ]);
  });

  testWidgets('source tags show as chips and stay out of the answer', (
    tester,
  ) async {
    await openTags(
      tester,
      manual: const ['Mine'],
      sourceTags: const ['Steam Collection'],
    );

    expect(find.byType(Chip), findsOneWidget);
    expect(find.text('Steam Collection'), findsOneWidget);
    // The editable field holds only the user's own tags.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Mine',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, ['Mine']);
  });

  testWidgets('Clear empties the list and Cancel keeps nothing', (
    tester,
  ) async {
    await openTags(tester, manual: const ['Backlog']);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isEmpty);

    // Reopen from the same host rather than pumping a second app.
    returned = false;
    result = null;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isNull);
  });
}
