import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/model/launch_options.dart';
import 'package:omni_launcher/src/sources/manual.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-config');
    path = '${dir.path}/config.json';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  AppConfig loadJson(Map<String, Object?> json) {
    File(path).writeAsStringSync(jsonEncode(json));
    return AppConfig.load(path);
  }

  test('a pre-version config loads with defaults', () {
    final loaded = loadJson({
      'hidden': ['steam:1'],
      'manual': [
        {
          'name': 'Alpha',
          'command': ['/opt/run'],
        },
      ],
    });

    expect(loaded.hidden, {'steam:1'});
    expect(loaded.favorites, isEmpty);
    expect(loaded.sortMode, 'name');
    expect(loaded.windowWidth, isNull);
    expect(loaded.windowHeight, isNull);
    // Entries written before keys existed get one derived from the name.
    expect(loaded.manual.single.key, 'alpha');
  });

  test(
    'a renamed manual entry keeps its key, so the game id is stable',
    () async {
      final loaded = loadJson({
        'manual': [
          {
            'name': 'Alpha',
            'key': 'alpha-1a2b3c',
            'command': ['/opt/run'],
          },
        ],
      });
      final before = await ManualSource().discover(loaded);
      expect(before.single.id, 'manual:alpha-1a2b3c');
      expect(before.single.key, 'alpha-1a2b3c');

      // The rename changes the name but not the key; the id follows the key.
      final renamed = loaded.copyWith(
        manual: [loaded.manual.single.copyWith(name: 'Beta')],
      );
      final after = await ManualSource().discover(renamed);
      expect(after.single.name, 'Beta');
      expect(after.single.id, before.single.id);
      expect(after.single.key, before.single.key);
    },
  );

  test('new manual entries get a generated key, unique per entry', () {
    final a = ManualEntry(name: 'Alpha', command: const ['/opt/run']);
    final b = ManualEntry(name: 'Alpha', command: const ['/opt/run']);
    expect(a.key, startsWith('alpha-'));
    expect(a.key, hasLength('alpha-'.length + 6));
    expect(a.key, isNot(b.key));
  });

  test('two entries with the same name load with distinct keys', () {
    final loaded = loadJson({
      'manual': [
        {
          'name': 'Alpha',
          'command': ['/opt/a'],
        },
        {
          'name': 'Alpha',
          'command': ['/opt/b'],
        },
      ],
    });
    expect(loaded.manual.map((entry) => entry.key).toSet(), hasLength(2));
  });

  test('a string command is split into words', () {
    final loaded = loadJson({
      'manual': [
        {
          'name': 'Alpha',
          'command': 'retroarch -L "nestopia_libretro.so" \'Super Mario.nes\'',
        },
      ],
    });
    expect(loaded.manual.single.command, [
      'retroarch',
      '-L',
      'nestopia_libretro.so',
      'Super Mario.nes',
    ]);
  });

  test('saving writes a schema version and leaves no temporary file', () {
    AppConfig(
      manual: [
        ManualEntry(name: 'Alpha', key: 'alpha-1a2b3c', command: ['/opt/run']),
      ],
    ).save(path);

    final saved =
        jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    expect(saved['version'], 2);
    expect(File('$path.tmp').existsSync(), isFalse);
    // The key survives the round trip.
    expect(AppConfig.load(path).manual.single.key, 'alpha-1a2b3c');
  });

  test('close with game is per launcher, and old game ids migrate', () {
    // Version 1 stored game ids; the prefix is the launcher they share.
    final migrated = loadJson({
      'version': 1,
      'close_with_game': [
        'steam:440',
        'lutris:foo',
        'flatpak:alpha',
        'manual:mine',
        'nonsense:1',
        42,
      ],
    });
    expect(migrated.closeWithGame, {'steam', 'lutris'});
    expect(migrated.closesWithGame(SourceKind.steam), isTrue);
    expect(migrated.closesWithGame(SourceKind.flatpak), isFalse);

    // A file with no version at all is version 1 too.
    expect(
      loadJson({
        'close_with_game': ['heroic:abc'],
      }).closeWithGame,
      {'heroic'},
    );

    AppConfig(closeWithGame: {'steam', 'heroic'}).save(path);
    final decoded =
        jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    expect(decoded['version'], 2);
    expect(decoded['close_with_game'], ['heroic', 'steam']);
    expect(AppConfig.load(path).closeWithGame, {'steam', 'heroic'});

    // Version 2 holds launcher ids; anything that is not a game launcher is
    // dropped, so a file from the per-source experiment loses its direct
    // sources instead of pretending they have a window to close.
    expect(
      loadJson({
        'version': 2,
        'close_with_game': ['steam', 'flatpak', 'nonsense', 'steam:440'],
      }).closeWithGame,
      {'steam'},
    );
  });

  test('the saved config is readable by the owner alone', () {
    AppConfig().save(path);
    if (Platform.isLinux || Platform.isMacOS) {
      expect(File(path).statSync().mode & 0x3F, 0);
    }
  });

  test('saving over a permissive config restricts the replacement', () {
    // A hand edit might leave the config group-readable; the save must not
    // carry those permissions over the rename.
    File(path).writeAsStringSync('{}');
    if (Platform.isLinux || Platform.isMacOS) {
      Process.runSync('chmod', ['644', path]);
      expect(File(path).statSync().mode & 0x3F, isNot(0));
    }
    AppConfig().save(path);
    if (Platform.isLinux || Platform.isMacOS) {
      expect(File(path).statSync().mode & 0x3F, 0);
    }
  });

  test('steamgriddb misses round trip, and malformed entries are dropped', () {
    final now = DateTime(2026, 10, 22).millisecondsSinceEpoch;
    AppConfig(sgdbMisses: {'steam:1': now}).save(path);
    expect(AppConfig.load(path).sgdbMisses, {'steam:1': now});

    final loaded = loadJson({
      'sgdb_misses': {
        'steam:1': now,
        'steam:2': 'junk',
        'steam:3': -5,
        'steam:4': 1.9,
      },
    });
    expect(loaded.sgdbMisses, {'steam:1': now, 'steam:4': 1});
    // A wholly wrong type loads as empty rather than failing the load.
    expect(loadJson({'sgdb_misses': 'junk'}).sgdbMisses, isEmpty);
  });

  test('an unknown sort mode falls back to name', () {
    expect(loadJson({'sort': 'sideways'}).sortMode, 'name');
    expect(loadJson({'sort': 42}).sortMode, 'name');
    expect(loadJson({'sort': 'lastPlayed'}).sortMode, 'lastPlayed');
    expect(loadJson({'sort': 'mostPlayed'}).sortMode, 'mostPlayed');
  });

  test('favorites, sort and window size round trip', () {
    AppConfig(
      favorites: ['steam:1', 'manual:alpha-1a2b3c'],
      sortMode: 'mostPlayed',
      windowWidth: 1280,
      windowHeight: 720,
    ).save(path);

    final loaded = AppConfig.load(path);
    expect(loaded.favorites, ['steam:1', 'manual:alpha-1a2b3c']);
    expect(loaded.sortMode, 'mostPlayed');
    expect(loaded.windowWidth, 1280.0);
    expect(loaded.windowHeight, 720.0);

    // And absent stays absent, so the key is not written.
    AppConfig().save(path);
    final saved =
        jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    expect(saved.containsKey('window'), isFalse);
  });

  test('tags, launch options, grants and window choices round trip', () {
    AppConfig(
      tags: {
        'steam:1': ['Backlog', 'Co-op'],
      },
      launchOptions: {
        'steam:1': const LaunchOptions(
          wrapper: ['gamemoderun'],
          args: ['-fullscreen'],
          env: {'MANGOHUD': '1'},
          cwd: '/tmp/game',
        ),
      },
      forgotten: {'steam:2'},
      pluginGrants: {
        'beats': {'lookup', 'actions'},
      },
      minimizeOnLaunch: true,
      trayIcon: true,
    ).save(path);

    final loaded = AppConfig.load(path);
    expect(loaded.tagsFor('steam:1'), ['Backlog', 'Co-op']);
    final options = loaded.launchOptionsFor('steam:1');
    expect(options.wrapper, ['gamemoderun']);
    expect(options.args, ['-fullscreen']);
    expect(options.env, {'MANGOHUD': '1'});
    expect(options.cwd, '/tmp/game');
    expect(options.summary, contains('gamemoderun'));
    expect(loaded.isForgotten('steam:2'), isTrue);
    expect(loaded.pluginGrantsFor('beats'), {'lookup', 'actions'});
    expect(loaded.minimizeOnLaunch, isTrue);
    expect(loaded.trayIcon, isTrue);

    // Unknown games and plugins get the defaults, not stale entries.
    expect(loaded.tagsFor('steam:9'), isEmpty);
    expect(loaded.launchOptionsFor('steam:9').isEmpty, isTrue);
    expect(loaded.pluginGrantsFor('unknown'), {'lookup'});

    // A hand edited file cannot take the load down, and duplicate tags
    // (whatever their case) are kept once.
    final rough = loadJson({
      'tags': {
        'steam:1': [' Backlog ', 'backlog', '', 7],
      },
      'launch_options': {
        'steam:1': {'args': 'not a list'},
      },
      'plugin_grants': {
        'beats': ['lookup', '', 3],
      },
      'forgotten': 'not a list',
    });
    expect(rough.tagsFor('steam:1'), ['Backlog']);
    expect(rough.launchOptionsFor('steam:1').isEmpty, isTrue);
    expect(rough.pluginGrantsFor('beats'), {'lookup'});
    expect(rough.forgotten, isEmpty);
  });

  test('a malformed plugin grant keeps the default grants', () {
    final loaded = loadJson({
      'plugin_grants': {
        'beats': 'lookup',
        'hooks': {'lookup': true},
        'empty': <Object?>[],
      },
    });

    // A value that is not a list cannot describe a grant set, so the plugin
    // is treated as unconfigured and keeps the defaults.
    expect(loaded.pluginGrantsFor('beats'), {'lookup'});
    expect(loaded.pluginGrantsFor('hooks'), {'lookup'});
    // An empty list is a real choice: no capabilities granted.
    expect(loaded.pluginGrantsFor('empty'), isEmpty);
  });

  test('a numeric string version is read as that version', () {
    // Version 2 stores launcher ids; under version 1 a bare `steam` would be
    // dropped as a malformed game id.
    final loaded = loadJson({
      'version': '2',
      'close_with_game': ['steam', 'steam:440'],
    });
    expect(loaded.closeWithGame, {'steam'});
  });

  test('launch option arguments round trip verbatim', () {
    AppConfig(
      launchOptions: {
        'steam:1': const LaunchOptions(args: ['', ' two ']),
      },
    ).save(path);

    // Argv words are significant: an empty word and its surrounding spaces
    // must survive the round trip.
    expect(AppConfig.load(path).launchOptionsFor('steam:1').args, [
      '',
      ' two ',
    ]);
  });

  test('environment entries that are not strings are dropped', () {
    final loaded = loadJson({
      'launch_options': {
        'steam:1': {
          'env': {'GOOD': ' one ', 'NULL': null, 'BAD': 2, '': 'x'},
        },
      },
    });

    // Values stay exactly as written; nulls and numbers are not env values.
    expect(loaded.launchOptionsFor('steam:1').env, {'GOOD': ' one '});
  });
}
