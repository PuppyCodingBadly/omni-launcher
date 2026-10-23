import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/plugins/plugin.dart';
import 'package:omni_launcher/src/plugins/plugin_runner.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/plugin_answer.dart';
import 'package:omni_launcher/src/ui/theme.dart';

const Game game = Game(
  id: 'steam:1',
  key: '1',
  name: 'Alpha',
  source: SourceKind.steam,
  command: ['true'],
);

const Plugin plugin = Plugin(
  id: 'howlongtobeat',
  name: 'HowLongToBeat',
  description: '',
  action: 'Look up on HowLongToBeat',
  command: ['python3', 'hltb.py'],
  dir: '/plugins/howlongtobeat',
);

/// The controller seams the section reads: what it was told, and whether it is
/// still looking.
class _AnswerSpy extends LibraryController {
  _AnswerSpy({
    required super.configPath,
    required super.cachePath,
    required super.playtime,
  });

  PluginAnswer? answer;
  bool running = false;

  @override
  PluginAnswer? pluginAnswer(String pluginId, String queryId) => answer;

  @override
  bool isLookingUp(String pluginId, String queryId) => running;

  @override
  Future<void> lookUp(Plugin plugin, PluginQuery query) async {}
}

void main() {
  late Directory dir;
  late _AnswerSpy controller;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-plugin-answer');
    controller = _AnswerSpy(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );
  });

  tearDown(() {
    controller.dispose();
    dir.deleteSync(recursive: true);
  });

  testWidgets('a failed lookup keeps the button, so it can be retried', (
    tester,
  ) async {
    // A successful answer hides the button (see `plugin_test`); a failure is
    // the one answer that must leave the way to ask again.
    controller.answer = PluginAnswer.failure('No match');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: PluginSection(
            controller: controller,
            game: game,
            plugin: plugin,
          ),
        ),
      ),
    );

    expect(find.text(plugin.action), findsOneWidget);
    expect(find.text('No match'), findsOneWidget);
  });
}
