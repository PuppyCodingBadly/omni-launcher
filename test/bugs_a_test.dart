// Regression tests for the discovery/parsing/config bugs fixed in this file's
// scope (lib/src/sources, lib/src/util, lib/src/model, config.dart, paths.dart).
//
// Every fix has a test that fails on the pre-fix code; the remaining tests
// guard behaviour that must not change while fixing it. All of them are
// deterministic and use temp directories, never this machine's games.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/paths.dart';
import 'package:omni_launcher/src/sources/appimage.dart';
import 'package:omni_launcher/src/sources/epic.dart';
import 'package:omni_launcher/src/sources/heroic.dart';
import 'package:omni_launcher/src/sources/manual.dart';
import 'package:omni_launcher/src/sources/registry.dart';
import 'package:omni_launcher/src/sources/source.dart';
import 'package:omni_launcher/src/util/desktop.dart';
import 'package:omni_launcher/src/util/files.dart';
import 'package:omni_launcher/src/util/proc.dart';
import 'package:omni_launcher/src/util/shell.dart';

/// A directory that is removed again when the test ends.
Directory tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Nothing useful to do about a failing cleanup.
    }
  });
  return dir;
}

void main() {
  group('shell word splitting', () {
    test('keeps backslashes that are not escaping a quote or a backslash', () {
      // shlex (and POSIX shells) only treat `\` as an escape inside double
      // quotes when it precedes `"` or `\`; every other backslash is literal,
      // so a Wine path survives the round trip.
      expect(
        desktopExecArgv(
          r'env WINEPREFIX="/home/u/.wine" wine "C:\Program Files\Game\game.exe"',
        ),
        [
          'env',
          'WINEPREFIX=/home/u/.wine',
          'wine',
          r'C:\Program Files\Game\game.exe',
        ],
      );
      expect(splitShellWords(r'"a\nb"'), [r'a\nb']);
      expect(splitShellWords(r'"a\qb"'), [r'a\qb']);
      expect(splitShellWords(r'"a\ b"'), [r'a\ b']);
      // The two escapes shlex does honour inside double quotes still work.
      expect(splitShellWords(r'"a\"b"'), ['a"b']);
      expect(splitShellWords(r'"a\\b"'), [r'a\b']);
      // Single quotes never escape, inside or outside.
      expect(splitShellWords(r"'a\nb'"), [r'a\nb']);
      expect(splitShellWords(r'a\nb'), ['anb']);
    });

    test('treats a carriage return as whitespace', () {
      expect(splitShellWords('a\rb'), ['a', 'b']);
      expect(splitShellWords('a\r\nb'), ['a', 'b']);
      expect(desktopExecArgv('/opt/a\r/opt/b'), ['/opt/a', '/opt/b']);
      expect(splitShellWords('a\rb c'), ['a', 'b', 'c']);
    });

    test('still round trips through quoteCommand', () {
      final argv = [
        r'C:\Program Files\Game\game.exe',
        "it's",
        '',
        r'back\slash',
        'a b',
      ];
      expect(splitShellWords(quoteCommand(argv)), argv);
    });
  });

  group('desktop entry files', () {
    test('an entry with non-UTF-8 bytes is read, not dropped', () {
      final dir = tempDir('omni-latin1');
      final file = File('${dir.path}/latin1.desktop');
      file.writeAsBytesSync([
        ...utf8.encode('[Desktop Entry]\nName=Caf'),
        0xE9, // 'é' in latin-1: not valid UTF-8
        ...utf8.encode(' Game\nCategories=Game;\nExec=/opt/game/run\n'),
      ]);

      final entry = readDesktopFile(file.path);
      expect(entry, isNotEmpty);
      expect(entry['Name'], 'Caf\uFFFD Game');
      expect(desktopCategories(entry), ['Game']);
      expect(desktopExecArgv(entry['Exec']!), ['/opt/game/run']);
    });

    test('a directory that cannot be listed yields nothing', () {
      final dir = tempDir('omni-locked');
      final locked = Directory('${dir.path}/locked')..createSync();
      final chmod = Process.runSync('chmod', ['000', locked.path]);
      expect(chmod.exitCode, 0);
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));

      expect(() => iterDesktopFiles([locked.path]), returnsNormally);
      expect(iterDesktopFiles([locked.path]), isEmpty);
      // The unreadable directory must not stop the readable ones either.
      final good = File('${dir.path}/good.desktop')
        ..writeAsStringSync('[Desktop Entry]\nName=Good\n');
      expect(
        iterDesktopFiles([locked.path, dir.path]).map((f) => f.path),
        [good.path],
      );
    });

    test('first directory wins a duplicated file name', () {
      final first = tempDir('omni-apps-first');
      final second = tempDir('omni-apps-second');
      for (final dir in [first, second]) {
        File('${dir.path}/game.desktop').writeAsStringSync('Name=x\n');
      }
      File('${second.path}/only.desktop').writeAsStringSync('Name=y\n');
      Directory('${first.path}/not-a-file.desktop').createSync();
      File('${first.path}/ignored.txt').writeAsStringSync('Name=z\n');

      expect(
        iterDesktopFiles([first.path, second.path]).map((f) => f.path),
        [
          '${first.path}/game.desktop',
          '${second.path}/only.desktop',
        ],
      );
    });
  });

  group('config with wrong value types', () {
    String writeConfig(Directory dir, String json) {
      final file = File('${dir.path}/config.json')..writeAsStringSync(json);
      return file.path;
    }

    test('a key with the wrong type falls back instead of throwing', () {
      final dir = tempDir('omni-config-types');
      final path = writeConfig(dir, '''
{
  "hidden": {"steam:1": true},
  "appimage_dirs": "/opt",
  "manual": {"Quake": {"command": ["quake"]}},
  "art_overrides": ["a.png"],
  "theme_mode": 3,
  "steamgriddb_key": 12345,
  "cover_fetch": "no",
  "show_hidden": "yes"
}
''');

      late AppConfig config;
      expect(() => config = AppConfig.load(path), returnsNormally);
      expect(config.hidden, isEmpty);
      expect(config.appimageDirs, AppConfig.defaultAppimageDirs);
      expect(config.manual, isEmpty);
      expect(config.artOverrides, isEmpty);
      expect(config.themeMode, AppThemeMode.dark);
      expect(config.steamgriddbKey, '12345');
      // Anything that is not exactly `false` keeps fetching on.
      expect(config.coverFetch, isTrue);
      expect(config.showHidden, isFalse);
    });

    test('a manual entry with odd value types is normalised', () {
      final dir = tempDir('omni-config-manual');
      final path = writeConfig(dir, '''
{
  "manual": [
    {"name": "String Command", "command": "flatpak run com.example.Quake"},
    {"name": "Number Command", "command": 5},
    {"name": "No Command"},
    {"command": ["/opt/run"], "cwd": 7, "icon": 8},
    {"name": "Empty Extras", "command": ["x"], "cwd": "", "icon": ""},
    {"name": 9, "command": ["x"]},
    "not an object"
  ]
}
''');

      final config = AppConfig.load(path);
      expect(config.manual, hasLength(6));
      expect(config.manual[0].command, ['flatpak run com.example.Quake']);
      expect(config.manual[0].name, 'String Command');
      expect(config.manual[1].command, isEmpty);
      expect(config.manual[2].command, isEmpty);
      expect(config.manual[3].name, 'Untitled');
      expect(config.manual[3].cwd, isNull);
      expect(config.manual[3].icon, isNull);
      expect(config.manual[4].cwd, isNull);
      expect(config.manual[4].icon, isNull);
      expect(config.manual[5].name, '9');
    });

    test('a config that is not even JSON still loads', () {
      final dir = tempDir('omni-config-junk');
      expect(AppConfig.load(writeConfig(dir, '{ nope')).hidden, isEmpty);
      expect(AppConfig.load('${dir.path}/missing.json').hidden, isEmpty);
    });

    test('a config whose root is not an object still loads', () {
      final dir = tempDir('omni-config-root');
      for (final json in ['[1, 2]', '"nope"', '5', 'true', 'null']) {
        late AppConfig config;
        expect(() => config = AppConfig.load(writeConfig(dir, json)), returnsNormally);
        expect(config.hidden, isEmpty);
        expect(config.appimageDirs, AppConfig.defaultAppimageDirs);
        expect(config.themeMode, AppThemeMode.dark);
      }
    });

    test('renames round trip, including ids that are not in the library', () {
      final dir = tempDir('omni-config-names');
      final path = writeConfig(dir, '{}');
      AppConfig(
        nameOverrides: {'steam:105600': 'Terraria (modded)', 'gone:1': 'Ghost'},
      ).save(path);

      final loaded = AppConfig.load(path);
      expect(loaded.nameOverrides, {
        'steam:105600': 'Terraria (modded)',
        'gone:1': 'Ghost',
      });
      // A second round trip keeps them.
      loaded.save(path);
      expect(AppConfig.load(path).nameOverrides, loaded.nameOverrides);
      // And copyWith carries them over.
      expect(loaded.copyWith(showHidden: true).nameOverrides, loaded.nameOverrides);
      expect(
        loaded.copyWith(nameOverrides: const {'steam:1': 'One'}).nameOverrides,
        {'steam:1': 'One'},
      );
    });

    test('corrupt rename entries are ignored', () {
      final dir = tempDir('omni-config-names-bad');
      for (final value in ['"nope"', '[1]', '5', 'true', 'null']) {
        final path = writeConfig(dir, '{"name_overrides": $value}');
        expect(AppConfig.load(path).nameOverrides, isEmpty);
      }

      final path = writeConfig(dir, '''
{
  "name_overrides": {
    "steam:1": 5,
    "steam:2": null,
    "steam:3": true,
    "steam:4": ["a"],
    "steam:5": "",
    "steam:6": "   ",
    "steam:7": "Kept",
    "steam:8": "  Padded  "
  }
}
''');
      final overrides = AppConfig.load(path).nameOverrides;
      expect(overrides.keys, ['steam:7', 'steam:8']);
      expect(overrides['steam:7'], 'Kept');
      expect(overrides['steam:8'], '  Padded  ');
    });

    test('the accent colour survives a save and load', () {
      final dir = tempDir('omni-config-accent');
      final path = writeConfig(dir, '{}');
      AppConfig(accentColor: AppAccent.teal.id).save(path);
      expect(AppConfig.load(path).accentColor, 'teal');
      expect(AppConfig.load(path).accent.id, 'teal');

      for (final value in ['7', 'true', 'null', '"nope"']) {
        final bad = writeConfig(dir, '{"accent_color": $value}');
        expect(AppConfig.load(bad).accentColor, AppAccent.brand.id);
      }
      // An unknown accent id falls back like an unknown theme mode does.
      expect(
        AppConfig.load(writeConfig(dir, '{"accent_color": "neon"}')).accent,
        AppAccent.brand,
      );
    });
  });

  group('name overrides', () {
    test('an override renames the game and leaves the rest alone', () {
      const zelda = Game(
        id: 'steam:100',
        key: '100',
        name: 'Discovered Name',
        source: SourceKind.steam,
        command: ['steam', '-applaunch', '100'],
        path: '/games/zelda',
        extra: {'appid': '100', 'size': 42},
      );
      const other = Game(
        id: 'flatpak:org.example.Other',
        key: 'org.example.Other',
        name: 'Other',
        source: SourceKind.flatpak,
        command: ['flatpak', 'run', 'org.example.Other'],
      );

      final renamed = applyNameOverrides(const [zelda, other], const {
        'steam:100': 'Zelda',
        'steam:999': 'Not in the library',
      });

      expect(renamed, hasLength(2));
      expect(renamed.first.name, 'Zelda');
      // Identity and launch data are untouched.
      expect(renamed.first.id, 'steam:100');
      expect(renamed.first.key, '100');
      expect(renamed.first.command, ['steam', '-applaunch', '100']);
      expect(renamed.first.source, SourceKind.steam);
      expect(renamed.first.path, '/games/zelda');
      expect(renamed.first.extra, {'appid': '100', 'size': 42});
      // The game without an override is passed straight through.
      expect(renamed.last, same(other));
    });

    test('a blank override name is ignored', () {
      const game = Game(
        id: 'steam:1',
        key: '1',
        name: 'Kept',
        source: SourceKind.steam,
        command: ['steam'],
      );
      for (final blank in ['', ' ', '\t', '\n']) {
        expect(
          applyNameOverrides(const [game], {'steam:1': blank}).single.name,
          'Kept',
        );
      }
      expect(applyNameOverrides(const [game], const {}).single, same(game));
    });

    test('a rename cannot merge two games', () {
      const one = Game(
        id: 'steam:1',
        key: '1',
        name: 'One',
        source: SourceKind.steam,
        command: ['steam'],
      );
      const two = Game(
        id: 'steam:2',
        key: '2',
        name: 'Two',
        source: SourceKind.steam,
        command: ['steam'],
      );

      final renamed = applyNameOverrides(const [one, two], const {
        'steam:1': 'Same Name',
        'steam:2': 'Same Name',
      });

      expect(renamed.map((game) => game.id), ['steam:1', 'steam:2']);
      expect(renamed.map((game) => game.name), ['Same Name', 'Same Name']);
    });

    test('discoverAll renames what it found', () async {
      final config = AppConfig(
        manual: [
          ManualEntry(name: 'Hand Added', command: ['/opt/run']),
        ],
        nameOverrides: {'manual:Hand Added': 'Renamed By Hand'},
      );

      final games = await discoverAll(
        config,
        only: {SourceKind.manual},
        sources: [ManualSource()],
      );

      expect(games, hasLength(1));
      expect(games.single.name, 'Renamed By Hand');
      expect(games.single.id, 'manual:Hand Added');
      expect(games.single.key, 'Hand Added');
      expect(games.single.command, ['/opt/run']);

      // Without an override the discovered name stays.
      final plain = await discoverAll(
        AppConfig(manual: config.manual),
        only: {SourceKind.manual},
        sources: [ManualSource()],
      );
      expect(plain.single.name, 'Hand Added');
    });

    test('renamed games still de-duplicate by identity', () async {
      const fromSteam = Game(
        id: 'steam:427410',
        key: '427410',
        name: 'Abiotic Factor',
        source: SourceKind.steam,
        command: ['steam', '-applaunch', '427410'],
      );
      const fromDesktop = Game(
        id: 'desktop:Abiotic Factor.desktop',
        key: 'Abiotic Factor.desktop',
        name: 'Abiotic Factor',
        source: SourceKind.desktop,
        command: ['gtk-launch', 'Abiotic Factor.desktop'],
        extra: {'dedupe': 'steam:427410'},
      );
      final config = AppConfig(
        nameOverrides: {
          'steam:427410': 'Renamed Steam',
          'desktop:Abiotic Factor.desktop': 'Renamed Desktop',
        },
      );

      final games = await discoverAll(
        config,
        sources: [
          _FixedSource(SourceKind.steam, const [fromSteam]),
          _FixedSource(SourceKind.desktop, const [fromDesktop]),
        ],
      );

      // The shortcut still loses to the Steam entry, and both are renamed.
      expect(games, hasLength(1));
      expect(games.single.id, 'steam:427410');
      expect(games.single.name, 'Renamed Steam');
      expect(dedupeKey(games.single), 'steam:427410');
    });
  });

  group('epic games launcher', () {
    const namespace = 'c4763f236d08423eb47b4c3008779c84';
    const itemId = '93f2a8c3547846eda966cb3c152a026e';
    const appName = 'Ginger';

    /// Writes a fake launcher state directory and returns its path.
    String epicRoot(Directory dir, List<String> lines, {String? catalog}) {
      final root = Directory('${dir.path}/com.epicgames.eglv2')
        ..createSync(recursive: true);
      File('${root.path}/installations.jsonl').writeAsStringSync(
        '${lines.join('\n')}\n',
      );
      if (catalog != null) {
        final cache = Directory('${root.path}/cache/prod')
          ..createSync(recursive: true);
        File('${cache.path}/catalog-cache.json').writeAsStringSync(catalog);
      }
      return root.path;
    }

    /// The header line the launcher puts above the snapshots.
    const header = '{"version":1,"writtenAt":"2026-01-01T00:00:00Z","entries":1}';

    String catalogWith(String title) => jsonEncode({
      'schemaVersion': 2,
      'locale': 'en-US',
      'items': {
        itemId: {
          'cachedAt': 1,
          'item': {
            'id': itemId,
            'namespace': namespace,
            'title': title,
            'releaseInfo': [
              {'appId': appName, 'platform': ['Windows']},
            ],
          },
        },
      },
    });

    test('an installation with the full triple becomes a launchable game', () async {
      final dir = tempDir('omni-epic');
      final install = Directory('${dir.path}/games/AlanWake2')
        ..createSync(recursive: true);
      final root = epicRoot(dir, [
        header,
        jsonEncode({
          'installationId': 'INSTALL1',
          'complete': true,
          'dir': install.path,
          'platform': 'Windows',
          'namespace': namespace,
          'itemId': itemId,
          'artifactId': appName,
          'launchCommand': '',
          'launchExecutable': 'Ginger.exe',
          'writtenAt': '2026-01-02T00:00:00Z',
        }),
      ], catalog: catalogWith('Alan Wake 2'));

      final games = await EpicSource(dataRoot: root).discover(AppConfig());

      expect(games, hasLength(1));
      final game = games.single;
      expect(game.id, 'epic:$appName');
      expect(game.key, appName);
      expect(game.name, 'Alan Wake 2');
      expect(game.source, SourceKind.epic);
      expect(game.subtitle, 'Epic Games Launcher');
      expect(game.path, install.path);
      expect(game.launchable, isTrue);
      expect(game.command, [
        'xdg-open',
        'com.epicgames.launcher://apps/'
            '$namespace%3A$itemId%3A$appName?action=launch&silent=true',
      ]);
      expect(game.extra, {
        'installationId': 'INSTALL1',
        'namespace': namespace,
        'itemId': itemId,
        'appName': appName,
        'platform': 'Windows',
        'complete': true,
        'dir': install.path,
        'dedupe': 'epic:$appName',
      });
      expect(dedupeKey(game), 'epic:$appName');
    });

    test('an installation with only an app name uses the short launch form', () async {
      final dir = tempDir('omni-epic-short');
      final root = epicRoot(dir, [
        header,
        jsonEncode({
          'installationId': 'INSTALL2',
          'complete': true,
          'dir': '${dir.path}/games/Peony',
          'artifactId': 'Peony',
          'launchExecutable': 'Peony.exe',
        }),
      ]);

      final games = await EpicSource(dataRoot: root).discover(AppConfig());

      expect(games, hasLength(1));
      expect(games.single.command, [
        'xdg-open',
        'com.epicgames.launcher://apps/Peony?action=launch',
      ]);
      // No catalog, no directory on disk: the executable names it, the path is
      // simply unknown.
      expect(games.single.name, 'Peony');
      expect(games.single.path, isNull);
      expect(games.single.extra['dir'], '${dir.path}/games/Peony');
      expect(games.single.extra['namespace'], isNull);
      expect(games.single.extra['itemId'], isNull);
    });

    test('a record without an app name is skipped', () async {
      final dir = tempDir('omni-epic-noname');
      final root = epicRoot(dir, [
        header,
        jsonEncode({'installationId': 'A', 'namespace': namespace}),
        jsonEncode({'installationId': 'B', 'itemId': itemId}),
        jsonEncode({'installationId': 'C', 'artifactId': 'Kept'}),
      ]);

      final games = await EpicSource(dataRoot: root).discover(AppConfig());
      expect(games.map((game) => game.id), ['epic:Kept']);
    });

    test('the newest snapshot of an installation wins', () async {
      final dir = tempDir('omni-epic-log');
      final root = epicRoot(dir, [
        header,
        jsonEncode({
          'installationId': 'INSTALL3',
          'complete': false,
          'dir': '${dir.path}/pending',
          'namespace': namespace,
          'itemId': itemId,
          'artifactId': appName,
          'launchExecutable': 'Pending.exe',
          'writtenAt': '2026-01-01T00:00:00Z',
        }),
        jsonEncode({
          'installationId': 'INSTALL3',
          'complete': true,
          'dir': '${dir.path}/done',
          'namespace': namespace,
          'itemId': itemId,
          'artifactId': appName,
          'launchExecutable': 'Done.exe',
          'writtenAt': '2026-01-02T00:00:00Z',
        }),
      ]);

      final games = await EpicSource(dataRoot: root).discover(AppConfig());

      expect(games, hasLength(1));
      expect(games.single.extra['complete'], isTrue);
      expect(games.single.extra['dir'], '${dir.path}/done');
    });

    test('a half-written log still yields the installations it describes', () async {
      final dir = tempDir('omni-epic-corrupt');
      final root = epicRoot(dir, [
        header,
        '',
        '   ',
        '{ this line is not json',
        '[1, 2, 3]',
        '"just a string"',
        jsonEncode({'installationId': '', 'artifactId': 'NoId'}),
        jsonEncode({'artifactId': 'NoInstallationId'}),
        jsonEncode({'installationId': 'GOOD', 'artifactId': 'Good Game'}),
      ]);

      final games = await EpicSource(dataRoot: root).discover(AppConfig());
      expect(games.map((game) => game.id), ['epic:Good Game']);
    });

    test('a corrupt catalog only costs the pretty name', () async {
      final dir = tempDir('omni-epic-catalog');
      for (final catalog in [
        '{ not json at all',
        '{"items": [1, 2]}',
        '{"items": {"$itemId": {"item": {"title": 42}}}}',
        '{"items": {"$itemId": "not an object"}}',
      ]) {
        final root = epicRoot(dir, [
          header,
          jsonEncode({
            'installationId': 'INSTALL4',
            'dir': '${dir.path}/games',
            'namespace': namespace,
            'itemId': itemId,
            'artifactId': appName,
            'launchExecutable': 'Ginger.exe',
          }),
        ], catalog: catalog);

        final games = await EpicSource(dataRoot: root).discover(AppConfig());
        expect(games, hasLength(1), reason: catalog);
        expect(games.single.name, 'Ginger', reason: catalog);
        expect(games.single.command, [
          'xdg-open',
          'com.epicgames.launcher://apps/'
              '$namespace%3A$itemId%3A$appName?action=launch&silent=true',
        ], reason: catalog);
      }
    });

    test('duplicate app names collapse into one game', () async {
      final dir = tempDir('omni-epic-dupes');
      final first = Directory('${dir.path}/first')..createSync();
      final root = epicRoot(dir, [
        header,
        jsonEncode({
          'installationId': 'ONE',
          'complete': true,
          'dir': first.path,
          'namespace': namespace,
          'itemId': itemId,
          'artifactId': 'Twin',
        }),
        jsonEncode({
          'installationId': 'TWO',
          'complete': true,
          'dir': '${dir.path}/second',
          'namespace': namespace,
          'itemId': itemId,
          'artifactId': 'Twin',
        }),
      ]);

      final games = await EpicSource(dataRoot: root).discover(AppConfig());
      expect(games, hasLength(1));
      expect(games.single.id, 'epic:Twin');
      expect(games.single.path, first.path);
    });

    test('a missing or empty data root is not an error', () async {
      final dir = tempDir('omni-epic-missing');
      for (final root in ['${dir.path}/nope', dir.path, '']) {
        expect(
          await EpicSource(dataRoot: root).discover(AppConfig()),
          isEmpty,
          reason: root,
        );
      }
      expect(await EpicSource().discover(AppConfig()), isA<List<Game>>());
    });

    /// A Heroic `installed.json` in legendary's shape (app name -> record).
    String heroicInstalled(Directory dir, String store, String appName) {
      final file = File('${dir.path}/heroic-$store/installed.json')
        ..createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          appName: {'title': appName, 'install_path': dir.path},
        }),
      );
      return file.path;
    }

    /// Heroic's legendary store and the native launcher both yielding an
    /// installation for the same machine.
    Future<List<Game>> discoverBoth(
      Directory dir, {
      required String heroicApp,
      required String epicApp,
      String store = 'Epic',
      AppConfig? config,
    }) async {
      // Heroic counts as installed through its flatpak, so no CLI is needed.
      setFlatpakAppIdsForTest({heroicFlatpakId});
      addTearDown(() => setFlatpakAppIdsForTest(null));
      final heroic = HeroicSource(
        installedFiles: [
          (store, heroicInstalled(dir, store, heroicApp), 'legendary'),
        ],
      );
      final epic = EpicSource(
        dataRoot: epicRoot(dir, [
          header,
          jsonEncode({
            'installationId': 'INSTALL6',
            'complete': true,
            'dir': dir.path,
            'namespace': namespace,
            'itemId': itemId,
            'artifactId': epicApp,
            'launchExecutable': '$epicApp.exe',
          }),
        ]),
      );
      return discoverAll(config ?? AppConfig(), sources: [heroic, epic]);
    }

    test('the same Epic game from Heroic and the launcher folds to one', () async {
      final dir = tempDir('omni-epic-fold');
      final games = await discoverBoth(dir, heroicApp: 'Ginger', epicApp: 'Ginger');

      expect(games, hasLength(1));
      final game = games.single;
      expect(game.id, 'heroic:Ginger');
      expect(game.source, SourceKind.heroic);
      expect(game.command, ['xdg-open', 'heroic://launch/Ginger']);
      expect(dedupeKey(game), 'epic:Ginger');
    });

    test('different app names stay two games', () async {
      final dir = tempDir('omni-epic-nofold');
      final games = await discoverBoth(dir, heroicApp: 'Ginger', epicApp: 'Peony');

      expect(games.map((game) => game.id), ['heroic:Ginger', 'epic:Peony']);
      expect(games.map((game) => game.name), ['Ginger', 'Peony']);
      expect(games.map(dedupeKey), ['epic:Ginger', 'epic:Peony']);
    });

    test('only Epic-store Heroic entries share the identity', () async {
      final dir = tempDir('omni-epic-gog');
      final games = await discoverBoth(
        dir,
        heroicApp: 'Ginger',
        epicApp: 'Ginger',
        store: 'GOG',
      );

      expect(games.map((game) => game.id), ['heroic:Ginger', 'epic:Ginger']);
      final heroicGame = games.firstWhere(
        (game) => game.source == SourceKind.heroic,
      );
      expect(heroicGame.extra['store'], 'GOG');
      expect(heroicGame.extra.containsKey('dedupe'), isFalse);
    });

    test('a rename leaves the identity alone and the fold intact', () async {
      final dir = tempDir('omni-epic-rename');
      final original = (await discoverBoth(
        dir,
        heroicApp: 'Ginger',
        epicApp: 'Ginger',
      )).single;

      final renamed = applyNameOverrides([original], const {
        'heroic:Ginger': 'Renamed',
      }).single;
      expect(renamed.name, 'Renamed');
      expect(renamed.extra['dedupe'], 'epic:Ginger');
      expect(dedupeKey(renamed), dedupeKey(original));

      // And a config rename still leaves a single entry behind.
      final renamedGames = await discoverBoth(
        dir,
        heroicApp: 'Ginger',
        epicApp: 'Ginger',
        config: AppConfig(nameOverrides: const {'heroic:Ginger': 'Renamed'}),
      );
      expect(renamedGames, hasLength(1));
      expect(renamedGames.single.id, 'heroic:Ginger');
      expect(renamedGames.single.name, 'Renamed');
    });

    test('the registry finds it and the cache round trips', () async {
      expect(SourceKind.epic.id, 'epic');
      expect(SourceKind.epic.label, 'Epic Games Launcher');
      expect(
        buildSources().where((source) => source.kind == SourceKind.epic),
        hasLength(1),
      );

      final dir = tempDir('omni-epic-registry');
      final root = epicRoot(dir, [
        header,
        jsonEncode({
          'installationId': 'INSTALL5',
          'namespace': namespace,
          'itemId': itemId,
          'artifactId': appName,
        }),
      ], catalog: catalogWith('Alan Wake 2'));

      final games = await discoverAll(
        AppConfig(),
        only: {SourceKind.epic},
        sources: [EpicSource(dataRoot: root)],
      );
      expect(games, hasLength(1));
      expect(games.single.name, 'Alan Wake 2');

      final restored = Game.fromJson(games.single.toJson());
      expect(restored, isNotNull);
      expect(restored!.source, SourceKind.epic);
      expect(restored.id, 'epic:$appName');
      expect(restored.command, games.single.command);
      expect(restored.extra['itemId'], itemId);
    });
  });

  group('cached game records', () {
    test('a record with the wrong value types is repaired, not thrown on', () {
      late Game? game;
      expect(
        () => game = Game.fromJson({
          'id': 'steam:105600',
          'name': 'Terraria',
          'source': 'steam',
          'command': 'steam -applaunch 105600',
          'cwd': 5,
          'icon': 6,
          'cover': 7,
          'path': 8,
          'subtitle': 9,
          'extra': 'nope',
        }),
        returnsNormally,
      );
      expect(game, isNotNull);
      expect(game!.command, ['steam -applaunch 105600']);
      expect(game!.key, '105600');
      expect(game!.cwd, isNull);
      expect(game!.icon, isNull);
      expect(game!.cover, isNull);
      expect(game!.path, isNull);
      expect(game!.subtitle, isNull);
      expect(game!.displaySubtitle, 'Steam');
      expect(game!.extra, isEmpty);
    });

    test('a record without an id, name or known source is still rejected', () {
      expect(Game.fromJson({'id': 1, 'name': 'x', 'source': 'steam'}), isNull);
      expect(Game.fromJson({'id': 'a:1', 'name': 2, 'source': 'steam'}), isNull);
      expect(Game.fromJson({'id': 'a:1', 'name': 'x', 'source': 'nope'}), isNull);
    });
  });

  group('appimage discovery', () {
    test('finds the game, its display name and its sibling icon', () async {
      final dir = tempDir('omni-appimages');
      // A stem that cannot collide with anything in the real icon theme.
      const stem = 'omni-bugs-a-icon-check';
      final appImage = File('${dir.path}/$stem.AppImage')
        ..writeAsStringSync('not a real appimage');
      final icon = File('${dir.path}/$stem.png')..writeAsStringSync('png');
      File('${dir.path}/plain.txt').writeAsStringSync('not an appimage');

      final games = await AppImageSource().discover(
        AppConfig(appimageDirs: [dir.path]),
      );
      expect(games, hasLength(1));
      final game = games.single;
      expect(game.id, 'appimage:${appImage.path}');
      expect(game.name, 'omni bugs a icon check');
      expect(game.command, [appImage.path]);
      expect(game.cwd, dir.path);
      expect(game.icon, icon.path);
      expect(game.iconIsName, isFalse);
      expect(game.launchable, isTrue);
    });

    test('a symlink to an AppImage does not duplicate it', () async {
      final dir = tempDir('omni-appimages-link');
      final target = File('${dir.path}/real.AppImage')..writeAsStringSync('x');
      Link('${dir.path}/link.AppImage').createSync(target.path);

      final games = await AppImageSource().discover(
        AppConfig(appimageDirs: [dir.path]),
      );
      expect(games.map((game) => game.id), ['appimage:${target.path}']);
    });
  });

  group('which', () {
    test('skips files that are not executable', () {
      final dir = tempDir('omni-which');
      final shadow = Directory('${dir.path}/shadow')..createSync();
      final real = Directory('${dir.path}/real')..createSync();
      final shadowSteam = File('${shadow.path}/steam')..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['644', shadowSteam.path]);
      final realSteam = File('${real.path}/steam')..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['755', realSteam.path]);

      expect(
        which('steam', searchPath: '${shadow.path}:${real.path}'),
        realSteam.path,
      );
      expect(which('steam', searchPath: shadow.path), isNull);
      expect(which('steam', searchPath: '${real.path}:${shadow.path}'), realSteam.path);
    });

    test('ignores directories, broken symlinks and missing names', () {
      final dir = tempDir('omni-which2');
      Directory('${dir.path}/lutris').createSync();
      Link('${dir.path}/heroic').createSync('${dir.path}/gone');
      final exe = File('${dir.path}/lutris-bin')..writeAsStringSync('x');
      Process.runSync('chmod', ['700', exe.path]);

      expect(which('lutris', searchPath: dir.path), isNull);
      expect(which('heroic', searchPath: dir.path), isNull);
      expect(which('nope', searchPath: dir.path), isNull);
      expect(which('lutris-bin', searchPath: ':${dir.path}:'), exe.path);
      expect(which('lutris-bin', searchPath: ''), isNull);
    });
  });

  group('path expansion', () {
    test('leaves undefined variables alone', () {
      expect(
        AppPaths.expand(r'$OMNILAUNCHER_UNSET_VAR_XYZ/AppImages'),
        r'$OMNILAUNCHER_UNSET_VAR_XYZ/AppImages',
      );
      expect(
        AppPaths.expand(r'~/${OMNILAUNCHER_UNSET_VAR_XYZ}/AppImages'),
        '${AppPaths.home}/\${OMNILAUNCHER_UNSET_VAR_XYZ}/AppImages',
      );
    });

    test('expands ~ and defined variables', () {
      final home = Platform.environment['HOME'];
      expect(AppPaths.expand('~'), AppPaths.home);
      expect(AppPaths.expand('~/AppImages'), '${AppPaths.home}/AppImages');
      expect(AppPaths.expand(r'$HOME/AppImages'), '${AppPaths.home}/AppImages');
      if (home != null && home.isNotEmpty) {
        expect(AppPaths.expand(r'${HOME}/x'), '$home/x');
      }
    });
  });
}

/// A source that yields a fixed list, so discovery can be tested without
/// touching this machine's Steam library or application directories.
class _FixedSource extends GameSource {
  _FixedSource(this.kind, this.games);

  @override
  final SourceKind kind;

  final List<Game> games;

  @override
  Future<List<Game>> discover(AppConfig cfg) async => games;
}
