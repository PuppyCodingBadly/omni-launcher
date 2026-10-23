import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/launcher.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/model/launch_options.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-launch-options');
    Launcher.logPathOverrideForTest = '${dir.path}/launch.log';
  });

  tearDown(() {
    Launcher.logPathOverrideForTest = null;
    dir.deleteSync(recursive: true);
  });

  test('the effective command is wrapper, game, extra arguments', () {
    const game = Game(
      id: 'steam:1',
      key: '1',
      name: 'Alpha',
      source: SourceKind.steam,
      command: ['steam', '-applaunch', '1'],
    );
    const options = LaunchOptions(
      wrapper: ['gamemoderun', 'mangohud'],
      args: ['-fullscreen', 'two words'],
    );

    expect(Launcher.effectiveCommand(game, options: options), [
      'gamemoderun',
      'mangohud',
      'steam',
      '-applaunch',
      '1',
      '-fullscreen',
      'two words',
    ]);
    expect(
      Launcher.formatCommand(game, options: options),
      contains("'two words'"),
    );
  });

  test(
    'the environment, working folder and arguments reach the game',
    () async {
      final script = File('${dir.path}/run.sh')
        ..writeAsStringSync(
          'printf \'%s|%s|%s\' "\$FOO" "\$PWD" "\$*" > ${dir.path}/out.txt\n',
        );
      final cwd = Directory('${dir.path}/working')..createSync();
      final game = Game(
        id: 'manual:alpha',
        key: 'alpha',
        name: 'Alpha',
        source: SourceKind.manual,
        command: ['sh', script.path],
      );

      final pid = await Launcher.launch(
        game,
        options: LaunchOptions(
          args: const ['--flag', 'two words'],
          env: const {'FOO': 'bar'},
          cwd: cwd.path,
        ),
      );
      expect(pid, isNotNull);

      final out = File('${dir.path}/out.txt');
      for (var attempt = 0; attempt < 100 && !out.existsSync(); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(out.existsSync(), isTrue);
      expect(out.readAsStringSync(), 'bar|${cwd.path}|--flag two words');
    },
  );

  test('an explicit working folder that is not there is an error', () async {
    const game = Game(
      id: 'manual:alpha',
      key: 'alpha',
      name: 'Alpha',
      source: SourceKind.manual,
      command: ['true'],
    );

    await expectLater(
      Launcher.launch(
        game,
        options: const LaunchOptions(cwd: '/no/such/folder/omni-test'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('a wrapper runs before the game', () async {
    final wrapper = File('${dir.path}/wrap.sh')
      ..writeAsStringSync(
        '#!/bin/sh\necho wrapped >> ${dir.path}/wrap.txt\nexec "\$@"\n',
      );
    final game = Game(
      id: 'manual:alpha',
      key: 'alpha',
      name: 'Alpha',
      source: SourceKind.manual,
      command: ['true'],
    );

    await Launcher.launch(
      game,
      options: LaunchOptions(wrapper: ['sh', wrapper.path]),
    );
    final out = File('${dir.path}/wrap.txt');
    for (var attempt = 0; attempt < 100 && !out.existsSync(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(out.existsSync(), isTrue);
    expect(out.readAsStringSync().trim(), 'wrapped');
  });

  test('a missing game binary is reported even with a wrapper', () async {
    const game = Game(
      id: 'manual:alpha',
      key: 'alpha',
      name: 'Alpha',
      source: SourceKind.manual,
      command: ['/no/such/omni-game-binary'],
    );

    // The wrapper resolves, so only the game's own program is missing; the
    // error must name it rather than the wrapper that runs first.
    await expectLater(
      Launcher.launch(game, options: const LaunchOptions(wrapper: ['true'])),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('command not found: /no/such/omni-game-binary'),
        ),
      ),
    );
  });

  test('a missing wrapper is an error', () async {
    const game = Game(
      id: 'manual:alpha',
      key: 'alpha',
      name: 'Alpha',
      source: SourceKind.manual,
      command: ['true'],
    );

    await expectLater(
      Launcher.launch(
        game,
        options: const LaunchOptions(wrapper: ['/no/such/omni-wrapper']),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('wrapper not found: /no/such/omni-wrapper'),
        ),
      ),
    );
  });
}
