import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/sources/bottles.dart';
import 'package:omni_launcher/src/sources/prism.dart';

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

/// An `instances/<id>/instance.cfg` fixture carrying [name].
String prismInstance(Directory root, String id, String name) {
  final file = File('${root.path}/instances/$id/instance.cfg')
    ..createSync(recursive: true);
  file.writeAsStringSync('[General]\nConfigVersion=1.2\nname=$name\n');
  return '${root.path}/instances';
}

/// A `<root>/<bottle>/library.yml` fixture with [contents].
String bottle(Directory root, String bottle, String contents) {
  final file = File('${root.path}/bottles/$bottle/library.yml')
    ..createSync(recursive: true);
  file.writeAsStringSync(contents);
  return '${root.path}/bottles';
}

void main() {
  group('SourceKind', () {
    test('prism and bottles carry their labels and ids', () {
      expect(SourceKind.prism.id, 'prism');
      expect(SourceKind.prism.label, 'Prism Launcher');
      expect(SourceKind.bottles.id, 'bottles');
      expect(SourceKind.bottles.label, 'Bottles');
      expect(SourceKind.byId('prism'), SourceKind.prism);
      expect(SourceKind.byId('bottles'), SourceKind.bottles);
    });
  });

  group('instanceName', () {
    test('reads name at the top level or under a section', () {
      expect(instanceName('name=1.20.1\nInstanceType=OneSix\n'), '1.20.1');
      expect(instanceName('[General]\nname=Modded\n'), 'Modded');
    });

    test('missing or blank names count as absent', () {
      expect(instanceName(''), isNull);
      expect(instanceName('name=\n'), isNull);
      expect(instanceName('InstanceType=OneSix\n'), isNull);
    });
  });

  group('PrismSource', () {
    test('discovers a native instance, launched with -l', () async {
      final dir = tempDir('omni-prism-native');
      final root = prismInstance(dir, '1.20.1', 'Vanilla Plus');

      final games = await PrismSource(
        roots: [root],
        command: ['prismlauncher'],
      ).discover(AppConfig());

      expect(games, hasLength(1));
      final game = games.single;
      expect(game.id, 'prism:1.20.1');
      expect(game.key, '1.20.1');
      expect(game.name, 'Vanilla Plus');
      expect(game.source, SourceKind.prism);
      expect(game.command, ['prismlauncher', '-l', '1.20.1']);
      expect(game.extra, {'instance': '1.20.1'});
    });

    test('discovers a flatpak instance, launched through flatpak run', () async {
      final dir = tempDir('omni-prism-flatpak');
      final flatpak =
          '${dir.path}/.var/app/$prismFlatpakId/data/PrismLauncher';
      final file = File('$flatpak/instances/Fabric/instance.cfg')
        ..createSync(recursive: true);
      file.writeAsStringSync('name=Fabric 1.21\n');

      final games = await PrismSource(
        roots: ['$flatpak/instances'],
        command: ['flatpak', 'run', prismFlatpakId],
      ).discover(AppConfig());

      expect(games, hasLength(1));
      expect(games.single.command, [
        'flatpak',
        'run',
        'org.prismlauncher.PrismLauncher',
        '-l',
        'Fabric',
      ]);
    });

    test('missing and unnamed instances are skipped, not fatal', () async {
      final dir = tempDir('omni-prism-missing');
      final root = prismInstance(dir, 'named', 'Named');
      // An instance dir without instance.cfg.
      Directory('$root/unnamed').createSync();
      // An instance.cfg without a usable name.
      final blank = File('$root/blank/instance.cfg')
        ..createSync(recursive: true);
      blank.writeAsStringSync('InstanceType=OneSix\nname=\n');

      final games = await PrismSource(
        roots: [root, '${dir.path}/no-such-root'],
        command: ['prismlauncher'],
      ).discover(AppConfig());

      expect(games.map((game) => game.id), ['prism:named']);
    });
  });

  group('parseLibraryYaml', () {
    test('reads the list shape', () {
      final entries = parseLibraryYaml('''
- bottle: gaming
  name: Cool Game
  id: abc-123
- bottle: gaming
  name: "Quoted: Game"
  id: def-456
''');
      expect(entries, hasLength(2));
      expect(entries.first['name'], 'Cool Game');
      expect(entries.first['id'], 'abc-123');
      expect(entries.last['name'], 'Quoted: Game');
    });

    test('reads the map shape Bottles also writes', () {
      final entries = parseLibraryYaml('''
abc-123:
  bottle: gaming
  name: Cool Game
  id: abc-123
''');
      expect(entries, hasLength(1));
      expect(entries.single['name'], 'Cool Game');
      expect(entries.single['bottle'], 'gaming');
    });

    test('junk yields no entries', () {
      expect(parseLibraryYaml('not yaml at all {]{'), isEmpty);
      expect(parseLibraryYaml(''), isEmpty);
    });
  });

  group('BottlesSource', () {
    test('discovers native library entries, launched via bottles-cli', () async {
      final dir = tempDir('omni-bottles-native');
      final root = bottle(dir, 'gaming', '''
- bottle: gaming
  name: Cool Game
  id: abc-123
''');

      final games = await BottlesSource(
        roots: [root],
        command: ['bottles-cli'],
      ).discover(AppConfig());

      expect(games, hasLength(1));
      final game = games.single;
      expect(game.id, 'bottles:gaming/abc-123');
      expect(game.name, 'Cool Game');
      expect(game.source, SourceKind.bottles);
      expect(game.command, [
        'bottles-cli',
        'run',
        '-b',
        'gaming',
        '-p',
        'Cool Game',
      ]);
      expect(game.extra, {'bottle': 'gaming', 'program': 'Cool Game'});
    });

    test('discovers flatpak entries, launched through flatpak run', () async {
      final dir = tempDir('omni-bottles-flatpak');
      final flatpak = '${dir.path}/.var/app/$bottlesFlatpakId/data/bottles';
      final file = File('$flatpak/bottles/work/library.yml')
        ..createSync(recursive: true);
      file.writeAsStringSync('''
entry-1:
  bottle: work
  name: Spreadsheet Quest
  id: entry-1
''');

      final games = await BottlesSource(
        roots: ['$flatpak/bottles'],
        command: [
          'flatpak',
          'run',
          '--command=bottles-cli',
          bottlesFlatpakId,
        ],
      ).discover(AppConfig());

      expect(games, hasLength(1));
      expect(games.single.command, [
        'flatpak',
        'run',
        '--command=bottles-cli',
        'com.usebottles.bottles',
        'run',
        '-b',
        'work',
        '-p',
        'Spreadsheet Quest',
      ]);
    });

    test('malformed entries are skipped per-entry, not fatal', () async {
      final dir = tempDir('omni-bottles-malformed');
      final root = bottle(dir, 'gaming', '''
- id: no-name-here
- name: Good Game
  id: good-1
''');
      // A bottle whose library is junk, and one with no library at all.
      bottle(dir, 'broken', '{][ not yaml');
      Directory('$root/empty').createSync();

      final games = await BottlesSource(
        roots: [root, '${dir.path}/no-such-root'],
        command: ['bottles-cli'],
      ).discover(AppConfig());

      expect(games.map((game) => game.id), ['bottles:gaming/good-1']);
    });
  });
}
