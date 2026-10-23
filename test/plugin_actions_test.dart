import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/launcher.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/plugins/plugin.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';

const Game game = Game(
  id: 'steam:1',
  key: '1',
  name: 'Alpha',
  source: SourceKind.steam,
  command: ['true'],
);

const Plugin plugin = Plugin(
  id: 'beats',
  name: 'Beats',
  description: '',
  action: 'Look up',
  command: ['sh', 'run.sh'],
  dir: '/plugins/beats',
  capabilities: {
    PluginCapability.lookup,
    PluginCapability.actions,
    PluginCapability.hooks,
  },
  actions: [PluginAction(id: 'mark', name: 'Mark as done')],
  hooks: {PluginHook.preLaunch, PluginHook.postExit},
);

/// Records the requests the controller makes, and answers actions.
class _PluginSpy extends LibraryController {
  _PluginSpy({
    required super.configPath,
    required super.cachePath,
    required super.playtime,
    required super.config,
    super.pollInterval,
  });

  final List<Map<String, Object?>> requests = [];

  @override
  Future<PluginAnswer> askPluginRequest(
    Plugin plugin,
    Map<String, Object?> request, {
    bool requireAnswer = true,
  }) async {
    requests.add(request);
    if (request['action'] == 'action') {
      return const PluginAnswer(
        fields: [PluginField(label: 'Result', value: 'done')],
      );
    }
    return const PluginAnswer();
  }
}

void main() {
  late Directory dir;
  late _PluginSpy controller;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-plugin-actions');
    Launcher.logPathOverrideForTest = '${dir.path}/launch.log';
    controller = _PluginSpy(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      config: AppConfig(
        appimageDirs: const [],
        pluginGrants: {
          'beats': {'lookup', 'actions', 'hooks'},
        },
      ),
      pollInterval: const Duration(milliseconds: 20),
    );
    controller.plugins = const [plugin];
  });

  tearDown(() {
    controller.dispose();
    Launcher.logPathOverrideForTest = null;
    dir.deleteSync(recursive: true);
  });

  Future<bool> waitFor(bool Function() condition) async {
    for (var attempt = 0; attempt < 200; attempt++) {
      if (condition()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return false;
  }

  test('an action carries the game and returns its answer', () async {
    final answer = await controller.runPluginAction(
      plugin,
      plugin.actions.single,
      game,
    );

    expect(answer?.fields.single.value, 'done');
    final request = controller.requests.single;
    expect(request['action'], 'action');
    expect(request['id'], 'mark');
    expect((request['game'] as Map)['id'], game.id);
    expect((request['game'] as Map)['tags'], isEmpty);
  });

  test('pre-launch and post-exit hooks run around a real launch', () async {
    await controller.launch(game);

    expect(
      await waitFor(
        () => controller.requests.any((r) => r['action'] == 'pre_launch'),
      ),
      isTrue,
    );
    expect(
      await waitFor(
        () => controller.requests.any((r) => r['action'] == 'post_exit'),
      ),
      isTrue,
    );
  });

  test('refused actions and hooks are never called', () async {
    controller.setPluginGrant(plugin, PluginCapability.actions, false);
    controller.setPluginGrant(plugin, PluginCapability.hooks, false);

    final answer = await controller.runPluginAction(
      plugin,
      plugin.actions.single,
      game,
    );
    expect(answer?.ok, isFalse);
    expect(controller.requests, isEmpty);

    await controller.launch(game);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(controller.requests, isEmpty);
  });
}
