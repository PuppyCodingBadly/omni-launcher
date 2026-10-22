import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/host.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/plugins/bundled.dart';
import 'package:omni_launcher/src/plugins/catalog.dart';
import 'package:omni_launcher/src/plugins/plugin.dart';
import 'package:omni_launcher/src/plugins/plugin_runner.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/state/plugin_store.dart';
import 'package:omni_launcher/src/ui/detail_panel.dart';
import 'package:omni_launcher/src/ui/settings_view.dart';
import 'package:omni_launcher/src/ui/theme.dart';

import 'zip_fixture.dart';

/// Whether this host can run python3, so a test that needs it is a visible
/// skip rather than a silent pass.
final bool hasPython3 = _detectPython3();

bool _detectPython3() {
  try {
    return Process.runSync('python3', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Game game(String id, String name, SourceKind source) => Game(
  id: id,
  key: id.split(':').last,
  name: name,
  source: source,
  command: const ['true'],
);

/// The assets the launcher ships, as the app's bundle would hand them over.
Future<String> shippedAssets(String asset) async {
  const files = <String, String>{
    'plugins/howlongtobeat/plugin.json':
        '{"id":"howlongtobeat","name":"HowLongToBeat",'
        '"description":"How long the game is.",'
        '"action":"Look up on HowLongToBeat",'
        '"command":["python3","hltb.py"],"version":2}',
    'plugins/howlongtobeat/hltb.py': 'print("{}")\n',
  };
  final file = files[asset];
  if (file == null) throw StateError('no such asset: $asset');
  return file;
}

/// Wait for work a widget started that runs outside the test: a plugin lookup
/// or a download.
///
/// It needs real time, because it is a process or a socket; the machinery
/// around it waits on timers, which need the widget test's clock to move. So:
/// both, in turn.
Future<void> settleWhile(WidgetTester tester, bool Function() busy) async {
  for (var tick = 0; tick < 200; tick++) {
    if (!busy()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// The archive's SHA-256, the same way the launcher computes it: the
/// catalogue's checksum has to be the real one, or the install it lists is
/// refused for the wrong reason.
String sha256Of(List<int> bytes) {
  final folder = Directory.systemTemp.createTempSync('omni-sum');
  try {
    final file = File('${folder.path}/archive.zip')..writeAsBytesSync(bytes);
    final result = Process.runSync('sha256sum', [file.path]);
    return '${result.stdout}'.split(RegExp(r'\s+')).first;
  } finally {
    folder.deleteSync(recursive: true);
  }
}

/// A reader that answers from memory: a catalogue holding one plugin, and the
/// archive it points at.
///
/// The widget tests use this rather than a socket: a widget test's clock cannot
/// wait for a connection, but it can wait for a future that is already done.
UrlReader memoryStore({
  required String id,
  required String name,
  int version = 1,
  String description = 'Answers with a fixed time.',
  List<Entry>? files,
}) {
  final manifest = jsonEncode({
    'id': id,
    'name': name,
    'description': description,
    'command': ['/bin/sh', 'run.sh'],
    'version': version,
  });
  final zip = archive(
    files ??
        [
          Entry('plugin.json', manifest),
          Entry(
            'run.sh',
            'cat > /dev/null\nprintf \'%s\' \'{"fields":[{"label":"Main story","value":"3h"}]}\'\n',
          ),
        ],
  );
  final index = utf8.encode(
    jsonEncode({
      'plugins': [
        {
          'id': id,
          'name': name,
          'description': description,
          'author': 'Someone',
          'version': version,
          'file': '$id.zip',
          'sha256': sha256Of(zip),
        },
      ],
    }),
  );
  return (url, {required int limit}) async =>
      url.path.endsWith('.zip') ? zip : index;
}

/// A store over loopback: an index listing one plugin, and its archive.
Future<HttpServer> storeServer({
  required String id,
  required String name,
  int version = 1,
  String description = 'Answers with a fixed time.',
  List<Entry>? files,
  String? sha256,
}) async {
  final manifest = jsonEncode({
    'id': id,
    'name': name,
    'description': description,
    'command': ['/bin/sh', 'run.sh'],
    'version': version,
  });
  final zip = archive(
    files ??
        [
          Entry('plugin.json', manifest),
          Entry(
            'run.sh',
            'cat > /dev/null\nprintf \'%s\' \'{"fields":[{"label":"Main story","value":"3h"}]}\'\n',
          ),
        ],
  );
  final index = utf8.encode(
    jsonEncode({
      'plugins': [
        {
          'id': id,
          'name': name,
          'description': description,
          'author': 'Someone',
          'version': version,
          'file': '$id.zip',
          'sha256': sha256 ?? sha256Of(zip),
        },
      ],
    }),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = request.uri.path == '/index.json'
        ? index
        : request.uri.path == '/$id.zip'
        ? zip
        : null;
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.add(body);
    }
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

void main() {
  late Directory dir;

  setUp(() {
    // flutter_test answers every HttpClient with a canned 400; these tests use
    // a loopback server instead, and never leave the machine.
    HttpOverrides.global = null;
    dir = Directory.systemTemp.createTempSync('omni-plugins');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('a manifest', () {
    test('carries what a plugin needs, and defaults the rest', () {
      final plugin = Plugin.fromManifest('/plugins/x', {
        'id': 'howlongtobeat',
        'name': 'HowLongToBeat',
        'command': ['python3', 'hltb.py'],
      });

      expect(plugin, isNotNull);
      expect(plugin!.id, 'howlongtobeat');
      expect(plugin.name, 'HowLongToBeat');
      expect(plugin.command, ['python3', 'hltb.py']);
      expect(plugin.dir, '/plugins/x');
      // A manifest without an action still gets one to show.
      expect(plugin.action, 'Look up with HowLongToBeat');
      expect(plugin.description, '');
    });

    test('is refused when the launcher could not run it', () {
      expect(Plugin.fromManifest('/plugins/x', null), isNull);
      expect(Plugin.fromManifest('/plugins/x', 'not a map'), isNull);
      expect(
        Plugin.fromManifest('/plugins/x', {
          'name': 'X',
          'command': ['x'],
        }),
        isNull,
      );
      expect(
        Plugin.fromManifest('/plugins/x', {
          'id': 'Not An Id',
          'name': 'X',
          'command': ['x'],
        }),
        isNull,
      );
      expect(
        Plugin.fromManifest('/plugins/x', {'id': 'x', 'name': 'X'}),
        isNull,
      );
      expect(
        Plugin.fromManifest('/plugins/x', {
          'id': 'x',
          'name': 'X',
          'command': [],
        }),
        isNull,
      );
      expect(
        Plugin.fromManifest('/plugins/x', {
          'id': 'x',
          'name': 'X',
          'command': ['x', 7],
        }),
        isNull,
      );
    });

    test('has a version, which is what replaces an installed copy', () {
      expect(Plugin.versionOf({'version': 3}), 3);
      expect(Plugin.versionOf({'version': '3'}), 0);
      expect(Plugin.versionOf({'version': -1}), 0);
      expect(Plugin.versionOf(null), 0);
    });
  });

  group('the plugin folder', () {
    /// Write a plugin folder; [manifest] `null` means a folder with no
    /// manifest at all.
    void write(String name, Object? manifest) {
      final folder = Directory('${dir.path}/$name')
        ..createSync(recursive: true);
      if (manifest == null) return;
      File(
        '${folder.path}/plugin.json',
      ).writeAsStringSync(manifest is String ? manifest : jsonEncode(manifest));
    }

    test('finds every folder that describes a plugin', () {
      write('alpha', {
        'id': 'alpha',
        'name': 'Alpha',
        'command': ['/bin/true'],
      });
      write('beta', {
        'id': 'beta',
        'name': 'Beta',
        'command': ['/bin/true'],
      });
      write('empty', null);
      File('${dir.path}/stray.json').writeAsStringSync('{}');

      final problems = <String>[];
      final plugins = discoverPlugins(
        dir.path,
        onError: (folder, error) => problems.add('$folder: $error'),
      );

      expect(plugins.map((plugin) => plugin.id).toList(), ['alpha', 'beta']);
      expect(plugins.first.dir, '${dir.path}/alpha');
      expect(problems, isEmpty);
    });

    test('reports a plugin it cannot read, and keeps the others', () {
      write('alpha', {
        'id': 'alpha',
        'name': 'Alpha',
        'command': ['/bin/true'],
      });
      write('broken', '{not json');
      write('nameless', {
        'command': ['/bin/true'],
      });

      final problems = <String>[];
      final plugins = discoverPlugins(
        dir.path,
        onError: (folder, error) => problems.add('$folder: $error'),
      );

      expect(plugins.map((plugin) => plugin.id).toList(), ['alpha']);
      expect(problems, hasLength(2));
      expect(problems.first, contains('broken'));
      expect(problems.last, contains('nameless'));
    });

    test('a folder that is not there holds no plugins', () {
      expect(discoverPlugins('${dir.path}/gone'), isEmpty);
    });

    test('an install\'s staging and backup folders are not plugins', () {
      write('alpha', {
        'id': 'alpha',
        'name': 'Alpha',
        'command': ['/bin/true'],
      });
      write('.alpha.new', {
        'id': 'alpha',
        'name': 'Alpha',
        'command': ['/bin/true'],
      });
      write('.alpha.old', null);

      final problems = <String>[];
      final plugins = discoverPlugins(
        dir.path,
        onError: (folder, error) => problems.add('$folder: $error'),
      );

      expect(plugins.map((plugin) => plugin.id).toList(), ['alpha']);
      expect(problems, isEmpty);
    });
  });

  group('running a plugin', () {
    /// A plugin whose program is [script], in a folder of its own.
    Plugin pluginWith(String script, {String name = 'Test'}) {
      final folder = Directory('${dir.path}/$name')
        ..createSync(recursive: true);
      File('${folder.path}/plugin.json').writeAsStringSync(
        jsonEncode({
          'id': name,
          'name': name,
          'command': ['/bin/sh', 'run.sh'],
        }),
      );
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

    test('the request goes in and the answer comes back', () async {
      final plugin = pluginWith(
        'cat > request.json\n'
        'printf \'%s\' \'{"fields":[{"label":"Main story","value":"54h 32m"}],'
        '"url":"https://example.com/game/1"}\'\n',
      );

      final answer = await runPlugin(
        plugin,
        PluginQuery.forGame(
          game('steam:427410', 'Abiotic Factor', SourceKind.steam),
        ),
      );

      expect(answer.ok, isTrue);
      expect(answer.url, 'https://example.com/game/1');
      expect(answer.fields.single.label, 'Main story');
      expect(answer.fields.single.value, '54h 32m');
      // The program runs in the plugin's own folder, and the request says
      // which game it is about.
      final request = File('${plugin.dir}/request.json').readAsStringSync();
      expect(jsonDecode(request), {
        'action': 'lookup',
        'game': {
          'id': 'steam:427410',
          'key': '427410',
          'name': 'Abiotic Factor',
          'source': 'steam',
          'path': null,
          'cwd': null,
          'command': ['true'],
          'extra': <String, Object?>{},
        },
      });
    });

    test('a plugin that says why it failed is taken at its word', () async {
      final plugin = pluginWith(
        'cat > /dev/null\nprintf \'%s\' \'{"error":"No match for \\"Foo\\"."}\'\n',
      );

      final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

      expect(answer.ok, isFalse);
      expect(answer.error, 'No match for "Foo".');
    });

    test('a plugin that exits badly reports what it said', () async {
      final plugin = pluginWith(
        'cat > /dev/null\necho "could not reach the site" >&2\nexit 3\n',
      );

      final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

      expect(answer.ok, isFalse);
      expect(answer.error, contains('could not reach the site'));
    });

    test('a plugin that answers with something else is refused', () async {
      final plugin = pluginWith(
        'cat > /dev/null\nprintf \'%s\' \'not json\'\n',
      );

      final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

      expect(answer.ok, isFalse);
      expect(answer.error, contains('was not JSON'));
    });

    test('an answer with nothing in it says so', () async {
      final plugin = pluginWith('cat > /dev/null\nprintf \'%s\' \'{}\'\n');

      final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

      expect(answer.ok, isFalse);
      expect(answer.error, contains('found nothing'));
    });

    test('a plugin that never answers is stopped', () async {
      final plugin = pluginWith('cat > /dev/null\nsleep 30\n');

      final answer = await runPlugin(
        plugin,
        PluginQuery.byName('Foo'),
        timeout: const Duration(milliseconds: 400),
      );

      expect(answer.ok, isFalse);
      expect(answer.error, contains('did not answer within'));
    });

    test('a process the plugin leaves behind is stopped with it', () async {
      final marker = '${dir.path}/survivor';
      // The child outlives the plugin's own timeout by design: only killing
      // the whole process group keeps it from touching the disk.
      final plugin = pluginWith(
        'cat > /dev/null\n(sleep 1; touch "$marker") &\nsleep 30\n',
      );

      final answer = await runPlugin(
        plugin,
        PluginQuery.byName('Foo'),
        timeout: const Duration(milliseconds: 400),
      );

      expect(answer.ok, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(File(marker).existsSync(), isFalse);
    });

    test('under Flatpak the host-side plugin is killed, not just the '
        'wrapper', () async {
      final marker = '${dir.path}/survived-flatpak';
      final plugin = pluginWith(
        'cat > /dev/null\n(sleep 0.8; touch "$marker") &\nsleep 30\n',
      );
      // flatpak-spawn hands the plugin to the host and waits for it. The
      // wrapper is the launcher's direct child; the plugin is neither its
      // descendant nor in its process group, exactly as in a sandbox.
      final spawn = File('${dir.path}/flatpak-spawn')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'while [ \$# -gt 0 ]; do\n'
          '  case "\$1" in\n'
          '    --host) shift ;;\n'
          '    --directory=*) shift ;;\n'
          '    *) break ;;\n'
          '  esac\n'
          'done\n'
          '"\$@" &\n'
          'child=\$!\n'
          'wait "\$child"\n',
        );
      Process.runSync('chmod', ['+x', spawn.path]);
      Host.setInFlatpakForTest(true);
      Host.setHostSpawnForTest(spawn.path);
      addTearDown(() {
        Host.setInFlatpakForTest(null);
        Host.setHostSpawnForTest(null);
      });

      final answer = await runPlugin(
        plugin,
        PluginQuery.byName('Foo'),
        timeout: const Duration(milliseconds: 400),
      );

      expect(answer.ok, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        File(marker).existsSync(),
        isFalse,
        reason: 'the host-side plugin outlived the timeout',
      );
    });

    test('a plugin that floods its output is stopped', () async {
      final plugin = pluginWith('cat > /dev/null\nyes omni-launcher\n');

      final answer = await runPlugin(
        plugin,
        PluginQuery.byName('Foo'),
        timeout: const Duration(seconds: 10),
      );

      expect(answer.ok, isFalse);
      expect(answer.error, contains('printed more than'));
    });

    test('a program that is not there is reported, not thrown', () async {
      const plugin = Plugin(
        id: 'gone',
        name: 'Gone',
        description: '',
        action: 'Look up',
        command: ['omni-launcher-no-such-program'],
        dir: '/tmp',
      );

      final answer = await runPlugin(plugin, PluginQuery.byName('Foo'));

      expect(answer.ok, isFalse);
      expect(answer.error, startsWith('Gone: '));
    });
  });

  group('the answer cache', () {
    test('answers survive a restart, and a broken cache is ignored', () {
      final path = '${dir.path}/plugin_answers.json';
      PluginStore(path: path).put(
        'howlongtobeat',
        'steam:1',
        const PluginAnswer(
          fields: [PluginField(label: 'Main story', value: '54h 32m')],
          url: 'https://example.com/game/1',
        ),
      );

      final reloaded = PluginStore(path: path);
      expect(
        reloaded.answer('howlongtobeat', 'steam:1')?.fields.single.value,
        '54h 32m',
      );
      expect(
        reloaded.answer('howlongtobeat', 'steam:1')?.url,
        'https://example.com/game/1',
      );
      // One game, two plugins: two entries.
      expect(reloaded.answer('other', 'steam:1'), isNull);

      File(path).writeAsStringSync('not json at all');
      expect(
        PluginStore(path: path).answer('howlongtobeat', 'steam:1'),
        isNull,
      );
    });
  });

  group('the controller', () {
    late String configPath;
    late String pluginDir;

    LibraryController build() => LibraryController(
      configPath: configPath,
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      pluginAnswers: PluginStore(path: '${dir.path}/plugin_answers.json'),
      pluginDir: '${dir.path}/plugins',
      pluginAssets: shippedAssets,
    );

    setUp(() {
      configPath = '${dir.path}/config.json';
      pluginDir = '${dir.path}/plugins';
    });

    test('reloading installs the shipped plugin and finds it', () async {
      final controller = build();
      addTearDown(controller.dispose);

      await controller.reloadPlugins();

      expect(controller.plugins.map((plugin) => plugin.id).toList(), [
        'howlongtobeat',
      ]);
      expect(File('$pluginDir/howlongtobeat/hltb.py').existsSync(), isTrue);
      expect(
        controller.plugin('howlongtobeat')?.action,
        'Look up on HowLongToBeat',
      );
      expect(controller.plugin('nothing'), isNull);
    });

    test('a newer shipped copy replaces the installed one', () async {
      final controller = build();
      addTearDown(controller.dispose);
      Directory('$pluginDir/howlongtobeat').createSync(recursive: true);
      File('$pluginDir/howlongtobeat/hltb.py').writeAsStringSync('mine');
      File('$pluginDir/howlongtobeat/plugin.json').writeAsStringSync(
        jsonEncode({
          'id': 'howlongtobeat',
          'name': 'HowLongToBeat',
          'command': ['python3', 'hltb.py'],
          'version': 9,
        }),
      );

      await controller.reloadPlugins();

      // The installed copy is newer than the shipped one, so it stays.
      expect(
        File('$pluginDir/howlongtobeat/hltb.py').readAsStringSync(),
        'mine',
      );
    });

    test('a lookup is remembered, and shown to the panel', () async {
      final controller = build();
      addTearDown(controller.dispose);
      final folder = Directory('$pluginDir/answer')
        ..createSync(recursive: true);
      File('${folder.path}/plugin.json').writeAsStringSync(
        jsonEncode({
          'id': 'answer',
          'name': 'Answer',
          'command': ['/bin/sh', 'run.sh'],
        }),
      );
      File('${folder.path}/run.sh').writeAsStringSync(
        'cat > /dev/null\nprintf \'%s\' \'{"fields":[{"label":"Main story","value":"3h"}]}\'\n',
      );
      await controller.reloadPlugins();
      final plugin = controller.plugin('answer')!;
      final query = PluginQuery.forGame(
        game('steam:1', 'Alpha', SourceKind.steam),
      );

      expect(controller.pluginAnswer(plugin.id, query.id), isNull);
      final notified = <int>[];
      controller.addListener(() => notified.add(1));

      await controller.lookUp(plugin, query);

      // One notification to say "asking", one to say "answered".
      expect(notified.length, 2);
      expect(controller.isLookingUp(plugin.id, query.id), isFalse);
      expect(
        controller.pluginAnswer(plugin.id, query.id)?.fields.single.value,
        '3h',
      );
      // And it is on disk, so the next start shows it without asking again.
      expect(
        PluginStore(path: '${dir.path}/plugin_answers.json')
            .answer(plugin.id, query.id)
            ?.fields
            .single
            .value,
        '3h',
      );
    });

    test('a name lookup is remembered under the name', () async {
      final controller = build();
      addTearDown(controller.dispose);
      final folder = Directory('$pluginDir/answer')
        ..createSync(recursive: true);
      File('${folder.path}/plugin.json').writeAsStringSync(
        jsonEncode({
          'id': 'answer',
          'name': 'Answer',
          'command': ['/bin/sh', 'run.sh'],
        }),
      );
      File('${folder.path}/run.sh').writeAsStringSync(
        'cat > request.json\nprintf \'%s\' \'{"fields":[{"label":"Main story","value":"3h"}]}\'\n',
      );
      await controller.reloadPlugins();
      final plugin = controller.plugin('answer')!;

      await controller.lookUp(plugin, PluginQuery.byName('Abiotic Factor'));

      expect(
        controller.pluginAnswer(plugin.id, 'name:Abiotic Factor')?.ok,
        isTrue,
      );
      expect(
        File('${folder.path}/request.json').readAsStringSync(),
        contains('"source":"search"'),
      );
    });
  });

  group('the plugin store', () {
    LibraryController build() => LibraryController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      pluginAnswers: PluginStore(path: '${dir.path}/plugin_answers.json'),
      pluginDir: '${dir.path}/plugins',
      pluginAssets: shippedAssets,
    );

    Future<PluginEntry> entryFrom(HttpServer server) async {
      final entries = await fetchCatalog(
        index: Uri.parse('http://127.0.0.1:${server.port}/index.json'),
      );
      return entries.single;
    }

    test(
      'a catalogue is read, with its archives resolved against it',
      () async {
        final server = await storeServer(
          id: 'answer',
          name: 'Answer',
          version: 4,
        );

        final entry = await entryFrom(server);

        expect(entry.id, 'answer');
        expect(entry.name, 'Answer');
        expect(entry.author, 'Someone');
        expect(entry.version, 4);
        expect(
          entry.url.toString(),
          'http://127.0.0.1:${server.port}/answer.zip',
        );
        expect(entry.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      },
    );

    test('an entry that makes no sense is left out', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.add(
          utf8.encode(
            jsonEncode({
              'plugins': [
                {'name': 'No id', 'file': 'x.zip', 'sha256': '0' * 64},
                {
                  'id': 'Not An Id',
                  'name': 'X',
                  'file': 'x.zip',
                  'sha256': '0' * 64,
                },
                // An entry without a checksum cannot be verified, so it is
                // not offered either.
                {'id': 'no-hash', 'name': 'X', 'file': 'x.zip'},
                {
                  'id': 'fine',
                  'name': 'Fine',
                  'file': 'fine.zip',
                  'sha256': '0' * 64,
                },
              ],
            }),
          ),
        );
        await request.response.close();
      });

      final entries = await fetchCatalog(
        index: Uri.parse('http://127.0.0.1:${server.port}/index.json'),
      );

      expect(entries.map((entry) => entry.id).toList(), ['fine']);
    });

    test('a catalogue that is not there is reported, not thrown', () async {
      final server = await storeServer(id: 'answer', name: 'Answer');

      await expectLater(
        fetchCatalog(
          index: Uri.parse('http://127.0.0.1:${server.port}/nothing.json'),
        ),
        throwsA(
          isA<PluginStoreException>().having(
            (error) => error.message,
            'message',
            contains('404'),
          ),
        ),
      );
    });

    test(
      'an archive whose checksum does not match the catalogue is refused',
      () async {
        final server = await storeServer(
          id: 'answer',
          name: 'Answer',
          sha256: '0' * 64,
        );
        final controller = build();
        addTearDown(controller.dispose);

        await controller.installPlugin(await entryFrom(server));

        expect(controller.failure, contains('checksum'));
        expect(Directory('${dir.path}/plugins/answer').existsSync(), isFalse);
        expect(File('${dir.path}/plugins/.answer.new').existsSync(), isFalse);
      },
    );

    test('a plain http address away from the loopback is refused', () async {
      await expectLater(
        readUrl(Uri.parse('http://example.com/index.json'), limit: 1024),
        throwsA(
          isA<PluginStoreException>().having(
            (error) => error.message,
            'message',
            contains('https'),
          ),
        ),
      );
    });

    test('a redirect to plain http is refused', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://example.com/stolen.zip',
        );
        await request.response.close();
      });

      await expectLater(
        readUrl(
          Uri.parse('http://127.0.0.1:${server.port}/index.json'),
          limit: 1024,
        ),
        throwsA(
          isA<PluginStoreException>().having(
            (error) => error.message,
            'message',
            contains('https'),
          ),
        ),
      );
    });

    test('a redirect on the loopback is followed', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/moved.json') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/here.json',
          );
        } else {
          request.response.add(utf8.encode('found it'));
        }
        await request.response.close();
      });

      final body = await readUrl(
        Uri.parse('http://127.0.0.1:${server.port}/moved.json'),
        limit: 1024,
      );

      expect(utf8.decode(body), 'found it');
    });

    test(
      'a server that stalls in the middle of its answer is given up on',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          // The first chunk arrives, and then nothing ever again: the response
          // is deliberately never closed.
          request.response.add(utf8.encode('partial'));
          await request.response.flush();
        });

        await expectLater(
          readUrl(
            Uri.parse('http://127.0.0.1:${server.port}/stalled.json'),
            limit: 1024,
            timeout: const Duration(milliseconds: 300),
          ),
          throwsA(
            isA<PluginStoreException>().having(
              (error) => error.message,
              'message',
              contains('took too long'),
            ),
          ),
        );
      },
    );

    test('a server that never answers is given up on', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      // The connection is taken and then ignored entirely.
      server.listen((request) async {});

      await expectLater(
        readUrl(
          Uri.parse('http://127.0.0.1:${server.port}/silent.json'),
          limit: 1024,
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(
          isA<PluginStoreException>().having(
            (error) => error.message,
            'message',
            contains('took too long'),
          ),
        ),
      );
    });

    test('installing unpacks the archive into the plugin folder', () async {
      final server = await storeServer(id: 'answer', name: 'Answer');
      final controller = build();
      addTearDown(controller.dispose);

      await controller.installPlugin(await entryFrom(server));

      expect(File('${dir.path}/plugins/answer/run.sh').existsSync(), isTrue);
      expect(
        File('${dir.path}/plugins/answer/plugin.json').existsSync(),
        isTrue,
      );
      // The launcher picks it up as part of the install, which is what makes it
      // apply to the panel.
      expect(controller.plugins.map((plugin) => plugin.id), [
        'answer',
        'howlongtobeat',
      ]);
      expect(controller.plugin('answer')?.version, 1);
      expect(controller.failure, isNull);
    });

    test('an archive that holds another plugin is refused', () async {
      final server = await storeServer(
        id: 'answer',
        name: 'Answer',
        files: [
          Entry(
            'plugin.json',
            jsonEncode({
              'id': 'other',
              'name': 'Other',
              'command': ['/bin/true'],
            }),
          ),
        ],
      );
      final controller = build();
      addTearDown(controller.dispose);

      await controller.installPlugin(await entryFrom(server));

      expect(controller.failure, contains('other'));
      expect(Directory('${dir.path}/plugins/answer').existsSync(), isFalse);
    });

    test(
      'an install that goes wrong leaves the installed copy alone',
      () async {
        final controller = build();
        addTearDown(controller.dispose);
        Directory('${dir.path}/plugins/answer').createSync(recursive: true);
        File('${dir.path}/plugins/answer/plugin.json').writeAsStringSync(
          jsonEncode({
            'id': 'answer',
            'name': 'Answer',
            'command': ['/bin/true'],
            'version': 1,
          }),
        );
        final server = await storeServer(
          id: 'answer',
          name: 'Answer',
          version: 2,
          files: [Entry('plugin.json', 'not json')],
        );

        await controller.installPlugin(await entryFrom(server));

        expect(controller.failure, contains('not JSON'));
        expect(
          File('${dir.path}/plugins/answer/plugin.json').readAsStringSync(),
          contains('"version":1'),
        );
        expect(
          File('${dir.path}/plugins/answer/../.answer.new').existsSync(),
          isFalse,
        );
      },
    );

    test('removing a plugin takes its folder with it', () async {
      final server = await storeServer(id: 'answer', name: 'Answer');
      final controller = build();
      addTearDown(controller.dispose);
      await controller.installPlugin(await entryFrom(server));

      await controller.removePlugin(controller.plugin('answer')!);

      expect(Directory('${dir.path}/plugins/answer').existsSync(), isFalse);
      expect(controller.plugins.map((plugin) => plugin.id), ['howlongtobeat']);
    });
  });

  group('in the window', () {
    /// A controller with one plugin that answers with a fixed time, and
    /// optionally a store to browse.
    Future<LibraryController> build(
      WidgetTester tester, {
      UrlReader? reader,
    }) async {
      final pluginDir = '${dir.path}/plugins';
      final folder = Directory('$pluginDir/answer')
        ..createSync(recursive: true);
      File('${folder.path}/plugin.json').writeAsStringSync(
        jsonEncode({
          'id': 'answer',
          'name': 'Answer',
          'description': 'Answers with a fixed time.',
          'action': 'Look up on Answer',
          'command': ['/bin/sh', 'run.sh'],
        }),
      );
      File('${folder.path}/run.sh').writeAsStringSync(
        'cat > /dev/null\n'
        'printf \'%s\' \'{"fields":[{"label":"Main story","value":"54h 32m"}],'
        '"url":"https://example.com/game/1"}\'\n',
      );
      final controller = LibraryController(
        configPath: '${dir.path}/config.json',
        cachePath: '${dir.path}/games.json',
        config: AppConfig(appimageDirs: const []),
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
        pluginAnswers: PluginStore(path: '${dir.path}/plugin_answers.json'),
        pluginDir: pluginDir,
        pluginAssets: shippedAssets,
        pluginReader: reader,
      );
      addTearDown(controller.dispose);
      await controller.reloadPlugins();
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(900, 2000);
      addTearDown(tester.view.reset);
      return controller;
    }

    testWidgets('the panel asks the plugin about the game', (tester) async {
      final controller = await build(tester);
      final alpha = game('steam:1', 'Alpha', SourceKind.steam);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) =>
                  DetailPanel(controller: controller, game: alpha),
            ),
          ),
        ),
      );

      expect(find.text('ANSWER'), findsOneWidget);
      expect(find.text('Look up on Answer'), findsOneWidget);
      expect(find.text('54h 32m'), findsNothing);

      await tester.tap(find.text('Look up on Answer'));
      await tester.pump();
      expect(find.text('Looking up…'), findsOneWidget);
      expect(controller.isLookingUp('answer', 'steam:1'), isTrue);

      await settleWhile(
        tester,
        () => controller.isLookingUp('answer', 'steam:1'),
      );
      expect(find.text('MAIN STORY'), findsOneWidget);
      expect(find.text('54h 32m'), findsOneWidget);
      expect(find.text('Open the page'), findsOneWidget);

      // addTearDown runs after the pending-timer check, so the notice's
      // auto-expire timer is put out here instead.
      controller.notice = null;
    });

    testWidgets('the settings page installs what the store offers', (
      tester,
    ) async {
      final controller = await build(
        tester,
        reader: memoryStore(id: 'beats', name: 'Beats'),
      );
      // The store reads its list when it is first shown; give it one, so the
      // test never reaches the real catalogue.
      await controller.refreshCatalog();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => SettingsView(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Beats'), findsOneWidget);
      expect(find.textContaining('by Someone · version 1'), findsOneWidget);
      // The plugin this test made by hand is listed beside the catalogue's,
      // and the one the launcher ships is not offered for removal: it would be
      // installed again at the next start.
      expect(find.text('Installed here, and not in the list'), findsOneWidget);
      expect(find.text('Ships with the launcher'), findsOneWidget);
      expect(find.byTooltip('Remove HowLongToBeat'), findsNothing);

      await tester.ensureVisible(find.text('Install'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install'));
      // A store plugin runs unsandboxed, so the install asks first; the
      // dialog's own Install is the second match, the row's button is still
      // in the tree behind it.
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install').last);
      await tester.pump();
      await settleWhile(tester, () => controller.isPluginBusy('beats'));
      // The dialog's pop animation needs real frames to leave the tree.
      await tester.pumpAndSettle();

      // The plugin is unpacked, and the launcher is already using it.
      expect(File('${dir.path}/plugins/beats/run.sh').existsSync(), isTrue);
      expect(controller.plugins.map((plugin) => plugin.id), [
        'answer',
        'beats',
        'howlongtobeat',
      ]);
      expect(find.text('Install'), findsNothing);
      expect(find.byTooltip('Remove Beats'), findsOneWidget);

      // And taking it away deletes the folder, once the dialog is answered.
      await tester.tap(find.byTooltip('Remove Beats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pump();
      await settleWhile(tester, () => controller.isPluginBusy('beats'));

      expect(Directory('${dir.path}/plugins/beats').existsSync(), isFalse);
      expect(controller.plugins.map((plugin) => plugin.id), [
        'answer',
        'howlongtobeat',
      ]);
      expect(find.text('Install'), findsOneWidget);

      // addTearDown runs after the pending-timer check, so the notice's
      // auto-expire timer is put out here instead.
      controller.notice = null;
    });
  });

  group('the answer cache', () {
    test('is versioned, atomic, and reads the old bare map', () {
      final dir = Directory.systemTemp.createTempSync('omni-answers');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/answers.json';

      // The first format was the answer map itself, with no envelope.
      File(path).writeAsStringSync(
        jsonEncode({
          'plugin/game': const PluginAnswer(
            fields: [PluginField(label: 'Main', value: '1h')],
          ).toJson(),
        }),
      );
      final store = PluginStore(path: path);
      expect(store.answer('plugin', 'game')?.fields.single.value, '1h');

      store.put(
        'plugin',
        'other',
        const PluginAnswer(
          fields: [PluginField(label: 'Main', value: '2h')],
        ),
      );
      final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(decoded['version'], PluginStore.schemaVersion);
      expect(decoded['answers'], isA<Map>());
      expect(File('$path.tmp').existsSync(), isFalse);
      expect(
        PluginStore(path: path).answer('plugin', 'other')?.fields.single.value,
        '2h',
      );
    });

    test(
      'keeps only so many answers, forgetting the one untouched the longest',
      () {
        final dir = Directory.systemTemp.createTempSync('omni-answers');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/answers.json';
        const answer = PluginAnswer(
          fields: [PluginField(label: 'Main', value: '1h')],
        );
        final store = PluginStore(path: path);

        for (var index = 0; index < PluginStore.maxEntries + 10; index++) {
          store.put('plugin', 'game$index', answer);
        }

        // The ten oldest are gone, and looking one survivor up keeps it alive.
        expect(store.answer('plugin', 'game9'), isNull);
        expect(store.answer('plugin', 'game10'), isNotNull);
        store.put('plugin', 'another', answer);
        expect(store.answer('plugin', 'game11'), isNull);
        expect(store.answer('plugin', 'game10'), isNotNull);

        // And the bound holds across a restart.
        final reloaded = PluginStore(path: path);
        expect(reloaded.answer('plugin', 'another'), isNotNull);
        expect(reloaded.answer('plugin', 'game10'), isNotNull);
        expect(reloaded.answer('plugin', 'game11'), isNull);
        var kept = 0;
        for (var index = 0; index < PluginStore.maxEntries + 10; index++) {
          if (reloaded.answer('plugin', 'game$index') != null) kept++;
        }
        expect(kept, PluginStore.maxEntries - 1);
      },
    );

    test('writing the same answer again does not touch the file', () {
      final dir = Directory.systemTemp.createTempSync('omni-answers');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/answers.json';
      const answer = PluginAnswer(
        fields: [PluginField(label: 'Main', value: '1h')],
      );
      final store = PluginStore(path: path);

      store.put('plugin', 'game', answer);
      File(path).writeAsStringSync('sentinel');
      store.put('plugin', 'game', answer);

      // A second save would have replaced the sentinel with the answers file.
      expect(File(path).readAsStringSync(), 'sentinel');
      expect(store.answer('plugin', 'game')?.fields.single.value, '1h');
    });
  });

  group('the shipped plugins', () {
    test('are on disk, with the manifest and the files they name', () {
      for (final bundled in bundledPlugins) {
        final folder = 'plugins/${bundled.id}';
        final manifest = File('$folder/plugin.json');
        expect(manifest.existsSync(), isTrue, reason: '$folder/plugin.json');

        final plugin = Plugin.fromManifest(
          folder,
          jsonDecode(manifest.readAsStringSync()),
        );
        expect(plugin, isNotNull, reason: '$folder/plugin.json');
        expect(plugin!.id, bundled.id);
        expect(plugin.name, isNotEmpty);
        expect(plugin.action, isNotEmpty);

        for (final file in bundled.files) {
          expect(
            File('$folder/$file').existsSync(),
            isTrue,
            reason: '$folder/$file',
          );
        }
        // Everything the command names is part of the plugin.
        for (final argument in plugin.command.skip(1)) {
          expect(bundled.files, contains(argument), reason: argument);
        }
      }
    });

    test('the HowLongToBeat plugin is valid python', () async {
      final result = await Process.run('python3', [
        '-c',
        'import ast, sys; ast.parse(open(sys.argv[1]).read())',
        'plugins/howlongtobeat/hltb.py',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }, skip: !hasPython3 ? 'no python3 on this host' : false);

    test(
      'the HowLongToBeat plugin answers a malformed request in JSON',
      () async {
        Future<Object?> ask(String request) async {
          final process = await Process.start('python3', [
            'plugins/howlongtobeat/hltb.py',
          ]);
          process.stdin.write(request);
          await process.stdin.close();
          final out = await process.stdout.transform(utf8.decoder).join();
          expect(await process.exitCode, 0, reason: request);
          return jsonDecode(out);
        }

        // Not JSON at all, JSON that is not an object, and an object whose
        // game is not one: each gets a JSON error answer, not a traceback.
        for (final raw in [
          'not json',
          '[1, 2]',
          '"just a name"',
          '{"game": "Celeste"}',
        ]) {
          final answer = await ask(raw);
          expect(answer, isA<Map>(), reason: raw);
          expect((answer as Map)['error'], isA<String>(), reason: raw);
        }
      },
      skip: !hasPython3 ? 'no python3 on this host' : false,
    );
  });
}
