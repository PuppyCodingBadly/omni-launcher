import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/model/launch_options.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/launch_options_dialog.dart';
import 'package:omni_launcher/src/ui/theme.dart';

const Game alpha = Game(
  id: 'steam:1',
  key: '1',
  name: 'Alpha',
  source: SourceKind.steam,
  command: ['true'],
);

void main() {
  late Directory dir;
  late LibraryController controller;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-launch-options-dialog');
    controller = LibraryController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );
    controller.games = [alpha];
  });

  tearDown(() {
    controller.dispose();
    dir.deleteSync(recursive: true);
  });

  /// Opens the dialog and hands the answer to the controller, the same way
  /// the detail panel does.
  Future<void> openOptions(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                final options = await showLaunchOptionsDialog(
                  context,
                  game: alpha,
                  current: controller.config.launchOptionsFor(alpha.id),
                );
                if (options != null) {
                  controller.setLaunchOptions(alpha.id, options);
                }
              },
              child: const Text('Options'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  // Wrapper, extra arguments, working folder, environment: in build order.
  Finder field(int index) => find.byType(TextField).at(index);

  testWidgets('editing the fields and saving writes the options to the config', (
    tester,
  ) async {
    await openOptions(tester);

    await tester.enterText(field(0), 'gamemoderun');
    await tester.enterText(field(1), '--fullscreen -skipintro');
    await tester.enterText(field(2), '/games/alpha');
    await tester.enterText(field(3), 'DXVK_HUD=fps\nWINEFSYNC=1');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // The saved notice's timer must not outlive the widget test.
    controller.notice = null;

    final options = controller.config.launchOptionsFor(alpha.id);
    expect(options.wrapper, ['gamemoderun']);
    expect(options.args, ['--fullscreen', '-skipintro']);
    expect(options.cwd, '/games/alpha');
    expect(options.env, {'DXVK_HUD': 'fps', 'WINEFSYNC': '1'});

    final saved = AppConfig.load(
      '${dir.path}/config.json',
    ).launchOptionsFor(alpha.id);
    expect(saved.wrapper, ['gamemoderun']);
    expect(saved.args, ['--fullscreen', '-skipintro']);
    expect(saved.cwd, '/games/alpha');
    expect(saved.env, {'DXVK_HUD': 'fps', 'WINEFSYNC': '1'});
  });

  testWidgets('reopening shows the saved values and Cancel keeps them', (
    tester,
  ) async {
    controller.setLaunchOptions(
      alpha.id,
      const LaunchOptions(
        wrapper: ['gamemoderun'],
        args: ['--fullscreen'],
        env: {'DXVK_HUD': 'fps'},
        cwd: '/games/alpha',
      ),
    );
    controller.notice = null;

    await openOptions(tester);
    expect(
      tester.widget<TextField>(field(0)).controller!.text,
      'gamemoderun',
    );
    expect(tester.widget<TextField>(field(1)).controller!.text, '--fullscreen');
    expect(tester.widget<TextField>(field(2)).controller!.text, '/games/alpha');
    expect(tester.widget<TextField>(field(3)).controller!.text, 'DXVK_HUD=fps');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.config.launchOptionsFor(alpha.id).wrapper, [
      'gamemoderun',
    ]);
  });

  testWidgets('Clear empties the saved options', (tester) async {
    controller.setLaunchOptions(
      alpha.id,
      const LaunchOptions(wrapper: ['gamemoderun']),
    );
    controller.notice = null;

    await openOptions(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    controller.notice = null;

    expect(controller.config.launchOptionsFor(alpha.id).isEmpty, isTrue);
    expect(AppConfig.load('${dir.path}/config.json').launchOptions, isEmpty);
  });

  testWidgets('a broken environment line is rejected, not saved', (
    tester,
  ) async {
    await openOptions(tester);

    await tester.enterText(field(3), 'NOT A LINE');
    await tester.tap(find.text('Save'));
    await tester.pump();

    // The dialog stays open, says why, and nothing reaches the config.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('Environment lines need KEY=VALUE: "NOT A LINE"'),
      findsOneWidget,
    );
    expect(controller.config.launchOptionsFor(alpha.id).isEmpty, isTrue);
    expect(AppConfig.load('${dir.path}/config.json').launchOptions, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
