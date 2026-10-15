import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/sources/lutris.dart';
import 'package:omni_launcher/src/sources/registry.dart';
import 'package:omni_launcher/src/util/desktop.dart';
import 'package:omni_launcher/src/util/files.dart';
import 'package:omni_launcher/src/util/shell.dart';
import 'package:omni_launcher/src/sources/flatpak.dart';
import 'package:omni_launcher/src/util/vdf.dart';

void main() {
  group('Valve keyvalues', () {
    test('parses nested blocks, quoted keys and escapes', () {
      const text = '''
// a comment
"libraryfolders"
{
  "0"
  {
    "path"    "/home/u/.local/share/Steam"
    "label"   ""
  }
  "1"
  {
    "path"    "/games\\"two"
  }
}
''';
      final parsed = parseKeyValues(text);
      final folders = parsed['libraryfolders'] as Map<String, Object?>;
      final first = folders['0'] as Map<String, Object?>;
      expect(first['path'], '/home/u/.local/share/Steam');
      expect(first['label'], '');
      final second = folders['1'] as Map<String, Object?>;
      expect(second['path'], '/games"two');
    });

    test('returns an empty map for junk', () {
      expect(parseKeyValues('not a vdf file at all'), isEmpty);
    });
  });

  group('desktop entries', () {
    test('reads the Desktop Entry group only, plain keys win', () {
      final dir = Directory.systemTemp.createTempSync('omni-desktop');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/game.desktop')
        ..writeAsStringSync('''
# comment
[Desktop Entry]
Name=Plain
Name[de]=Deutsch
Categories=Game;Action;
Exec=/opt/game/run --flag %U
NoDisplay=false

[Desktop Action Play]
Name=Ignored
''');
      final entry = readDesktopFile(file.path);
      expect(entry['Name'], 'Plain');
      expect(entry.containsKey('Name[de]'), isFalse);
      expect(entry['Name'], isNot('Ignored'));
      expect(desktopCategories(entry), ['Game', 'Action']);
      expect(desktopExecArgv(entry['Exec']!), ['/opt/game/run', '--flag']);
    });

    test('maps a desktop file to its flatpak app id', () {
      final ids = {
        'net.retrodeck.retrodeck',
        'net.retrodeck.retrodeck.Configurator',
        'com.example.Other',
      };
      expect(
        flatpakAppForDesktop('net.retrodeck.retrodeck.Configurator.desktop', ids),
        'net.retrodeck.retrodeck.Configurator',
      );
      expect(
        flatpakAppForDesktop('net.retrodeck.retrodeck.desktop', ids),
        'net.retrodeck.retrodeck',
      );
      expect(flatpakAppForDesktop('org.unknown.Thing.desktop', ids), isNull);
      expect(
        isFlatpakExport('/home/x/.local/share/flatpak/exports/share/applications/a.desktop'),
        isTrue,
      );
      expect(isFlatpakExport('/usr/share/applications/a.desktop'), isFalse);
    });
  });

  group('shell quoting', () {
    test('splits quotes and escapes', () {
      expect(splitShellWords("game --name 'two words' --x"), [
        'game',
        '--name',
        'two words',
        '--x',
      ]);
      expect(splitShellWords(r'game "a \"quoted\" arg"'), ['game', 'a "quoted" arg']);
      expect(splitShellWords(''), isEmpty);
    });

    test('quoteCommand round-trips through splitShellWords', () {
      final argv = ['/opt/My Game/run', '--title', "it's here", r'back\slash', ''];
      expect(splitShellWords(quoteCommand(argv)), argv);
    });
  });

  group('lutris yaml', () {
    test('reads slugs, quoted values and the game block', () {
      final parsed = parseGameYaml('''
# a comment
game_slug: ignored-when-slug-is-set
slug: my-game
name: "Top Level"
game:
  name: Nested Name
  id: 42
  directory: /games/my-game
''');
      expect(parsed['slug'], 'my-game');
      expect(parsed['name'], 'Nested Name');
      expect(parsed['id'], '42');
      expect(parsed['directory'], '/games/my-game');
    });

    test('falls back to game_slug and tolerates empty values', () {
      final parsed = parseGameYaml('game_slug: only-slug\nname:\n');
      expect(parsed['slug'], 'only-slug');
      expect(parsed.containsKey('name'), isFalse);
    });
  });

  group('game model', () {
    test('survives a json round trip', () {
      const game = Game(
        id: 'steam:105600',
        key: '105600',
        name: 'Terraria',
        source: SourceKind.steam,
        command: ['/usr/bin/steam', '-applaunch', '105600'],
        path: '/games/Terraria',
        extra: {'appid': '105600', 'size': 42},
      );
      final restored = Game.fromJson(game.toJson());
      expect(restored, isNotNull);
      expect(restored!.id, game.id);
      expect(restored.command, game.command);
      expect(restored.source, SourceKind.steam);
      expect(restored.extra['size'], 42);
      expect(restored.displaySubtitle, 'Steam');
    });

    test('rejects records without a known source', () {
      expect(Game.fromJson({'id': 'x:1', 'name': 'x', 'source': 'nope'}), isNull);
    });
  });

  group('registry', () {
    test('dedupes a desktop shortcut that points at a Steam game', () {
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
      expect(dedupeKey(fromDesktop), 'steam:427410');
      expect(dedupeKey(fromSteam), 'steam:427410');
      expect(dedupeKey(const Game(
        id: 'flatpak:x',
        key: 'x',
        name: 'x',
        source: SourceKind.flatpak,
        command: ['flatpak', 'run', 'x'],
      )), isNull);
    });

    test('sorts by name, then by source order', () {
      final sorted = sortGames(const [
        Game(
          id: 'steam:2',
          key: '2',
          name: 'beta',
          source: SourceKind.steam,
          command: ['steam'],
        ),
        Game(
          id: 'desktop:b.desktop',
          key: 'b.desktop',
          name: 'Beta',
          source: SourceKind.desktop,
          command: ['gtk-launch'],
        ),
        Game(
          id: 'steam:1',
          key: '1',
          name: 'Alpha',
          source: SourceKind.steam,
          command: ['steam'],
        ),
      ]);
      expect(sorted.map((game) => game.id).toList(), [
        'steam:1',
        'steam:2',
        'desktop:b.desktop',
      ]);
    });
  });

  group('config', () {
    test('round trips hidden games, folders and hand added entries', () {
      final dir = Directory.systemTemp.createTempSync('omni-config');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/config.json';
      AppConfig(
        hidden: {'steam:105600'},
        appimageDirs: ['~/AppImages', '/opt'],
        manual: [
          ManualEntry(name: 'Quake', command: ['flatpak', 'run', 'com.example.Quake'], cwd: '/games/quake'),
        ],
        coverFetch: false,
        showHidden: true,
      ).save(path);

      final loaded = AppConfig.load(path);
      expect(loaded.hidden, {'steam:105600'});
      expect(loaded.isHidden('steam:105600'), isTrue);
      expect(loaded.appimageDirs, ['~/AppImages', '/opt']);
      expect(loaded.manual.single.name, 'Quake');
      expect(loaded.manual.single.command, ['flatpak', 'run', 'com.example.Quake']);
      expect(loaded.coverFetch, isFalse);
      expect(loaded.showHidden, isTrue);
    });

    test('falls back to defaults for a broken file', () {
      final dir = Directory.systemTemp.createTempSync('omni-config-bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/config.json';
      File(path).writeAsStringSync('{ not json');
      final loaded = AppConfig.load(path);
      expect(loaded.hidden, isEmpty);
      expect(loaded.appimageDirs, AppConfig.defaultAppimageDirs);
      expect(loaded.coverFetch, isTrue);
    });
  });

  group('flatpak desktop dumps', () {
    // Inside a flatpak sandbox the host's flatpak exports are masked, so the
    // entries arrive as one base64 line each.
    String line(String name, String body) =>
        '@@$name ${base64.encode(utf8.encode(body))}';

    test('reads one base64 line per entry', () {
      final dump = '${line('net.retrodeck.retrodeck.desktop', '[Desktop Entry]\nName=RetroDECK\nCategories=Game;\n')}\n'
          '${line('com.example.Other.desktop', '[Desktop Entry]\nName=Other\nCategories=Utility;\n')}\n';
      final entries = parseDesktopDump(dump);
      expect(entries.map((entry) => entry.$1).toList(), [
        'net.retrodeck.retrodeck.desktop',
        'com.example.Other.desktop',
      ]);
      expect(entries.first.$2['Name'], 'RetroDECK');
      expect(desktopCategories(entries.first.$2), ['Game']);
      expect(desktopCategories(entries.last.$2), ['Utility']);
    });

    test('a body containing the marker cannot split an entry', () {
      // The old protocol concatenated the files and split on `@@`, so a file
      // that contains the marker was cut in half and lost its Categories.
      final body = '[Desktop Entry]\nName=Tricky\nComment=@@ marker @@\n'
          'Exec=/usr/bin/tricky --flag @@\nCategories=Game;\n';
      final entries = parseDesktopDump(line('com.example.Tricky.desktop', body));
      expect(entries, hasLength(1));
      expect(desktopCategories(entries.single.$2), ['Game']);
      expect(entries.single.$2['Exec'], '/usr/bin/tricky --flag @@');
    });

    test('junk lines, empty dumps and bad payloads are ignored', () {
      expect(parseDesktopDump(''), isEmpty);
      expect(parseDesktopDump('@@not-a-desktop-file YWJj'), isEmpty);
      expect(parseDesktopDump('@@a.desktop'), isEmpty);
      expect(parseDesktopDump('@@a.desktop not*base64'), isEmpty);
      expect(parseDesktopDump('@@a.desktop ${base64.encode(utf8.encode('nonsense'))}'), isEmpty);
    });
  });
}
