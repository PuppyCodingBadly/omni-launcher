import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/plugins/plugin.dart';
import 'package:omni_launcher/src/plugins/plugin_runner.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-plugin-runner');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// A plugin whose program is [script], in a folder of its own.
  Plugin pluginWith(String name, String script) {
    final folder = Directory('${dir.path}/$name')..createSync(recursive: true);
    File('${folder.path}/run.sh').writeAsStringSync(script);
    return Plugin(
      id: name,
      name: name,
      description: '',
      action: 'Look up',
      command: const ['/bin/sh', 'run.sh'],
      dir: folder.path,
    );
  }

  /// The pid files left in [folder]; a finished run must leave none.
  List<String> pidFiles(String folder) => Directory(folder)
      .listSync()
      .map((entry) => entry.path.split('/').last)
      .where((name) => name.startsWith('.run') && name.endsWith('.pid'))
      .toList();

  test('a hung plugin is killed at the timeout, and cleans up', () async {
    // The injected timeout keeps the test fast; the plugin would sleep for a
    // full minute otherwise.
    final plugin = pluginWith('sleeper', 'cat > /dev/null\nsleep 60\n');

    final started = DateTime.now();
    final answer = await runPlugin(
      plugin,
      PluginQuery.byName('Foo'),
      timeout: const Duration(milliseconds: 400),
    );
    final elapsed = DateTime.now().difference(started);

    expect(answer.ok, isFalse);
    expect(answer.error, contains('did not answer within'));
    // The sixty second sleep did not run its course.
    expect(elapsed, lessThan(const Duration(seconds: 10)));
    // The pid file is not left behind.
    expect(pidFiles(plugin.dir), isEmpty);
  });

  test('output past 256 KiB is refused, even with an answer after it', () async {
    // The plugin floods stdout and then prints a valid answer; the cap must
    // win over the answer.
    final plugin = pluginWith(
      'toomuch',
      'cat > /dev/null\n'
      'yes x | head -c 300000\n'
      'printf \'%s\' \'{"fields":[{"label":"A","value":"B"}]}\'\n',
    );

    final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

    expect(answer.ok, isFalse);
    expect(answer.error, contains('printed more than 256 KiB'));
  });

  test('output that is not JSON at all is refused', () async {
    final plugin = pluginWith(
      'garbled',
      'cat > /dev/null\nprintf \'%s\' \'this is not json\'\n',
    );

    final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

    expect(answer.ok, isFalse);
    expect(answer.error, contains('the answer was not JSON'));
  });

  test('an answer that is JSON but not an answer is refused', () async {
    final plugin = pluginWith(
      'odd',
      'cat > /dev/null\nprintf \'%s\' \'[1,2,3]\'\n',
    );

    final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

    expect(answer.ok, isFalse);
    expect(answer.error, contains('the answer made no sense'));
  });

  test('a non-zero exit reports the last line of stderr', () async {
    // A traceback ends with the actual complaint; the lines above it are
    // context, not the message to show.
    final plugin = pluginWith(
      'crasher',
      'cat > /dev/null\n'
      'echo "Traceback (most recent call last):" >&2\n'
      'echo "RuntimeError: no database" >&2\n'
      'exit 3\n',
    );

    final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

    expect(answer.ok, isFalse);
    expect(answer.error, contains('RuntimeError: no database'));
    expect(answer.error, isNot(contains('Traceback')));
  });

  test('a non-zero exit without stderr reports the exit code', () async {
    final plugin = pluginWith('silentfail', 'cat > /dev/null\nexit 7\n');

    final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

    expect(answer.ok, isFalse);
    expect(answer.error, contains('exited with 7'));
  });
}
