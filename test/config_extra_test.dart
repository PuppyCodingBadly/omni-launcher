import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-config-extra');
    path = '${dir.path}/config.json';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  AppConfig loadJson(Map<String, Object?> json) {
    File(path).writeAsStringSync(jsonEncode(json));
    return AppConfig.load(path);
  }

  group('atomic save', () {
    test('saving replaces the file wholesale, leaving no partial file', () {
      // A config with plenty of keys first.
      AppConfig(
        hidden: {'steam:1'},
        favorites: ['steam:1'],
        steamgriddbKey: 'secret',
      ).save(path);
      // A smaller config over it: nothing of the old file may survive.
      AppConfig().save(path);

      final raw = File(path).readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      expect(decoded['hidden'], isEmpty);
      expect(decoded['favorites'], isEmpty);
      expect(decoded['steamgriddb_key'], '');
      // The file is one complete JSON document...
      expect(raw.endsWith('}\n'), isTrue);
      // ...written through a sibling that is gone once the rename landed.
      expect(File('$path.tmp').existsSync(), isFalse);
    });

    test('saving creates the config folder when it does not exist', () {
      final nested = '${dir.path}/deeply/nested/config.json';
      AppConfig(favorites: ['steam:1']).save(nested);

      expect(File(nested).existsSync(), isTrue);
      expect(AppConfig.load(nested).favorites, ['steam:1']);
    });
  });

  group('schema versions', () {
    test('an unknown future version keeps the current semantics', () {
      final loaded = loadJson({
        'version': 99,
        'close_with_game': ['steam', 'steam:440'],
      });
      // At version 2 and beyond the entries are launcher ids; the game id
      // form is dead weight and dropped.
      expect(loaded.closeWithGame, {'steam'});
    });

    test('a version that is not a number at all reads as version 1', () {
      final loaded = loadJson({
        'version': 'abc',
        'close_with_game': ['steam:440'],
      });
      // Treated as a pre-versioning file: the game id migrates to the
      // launcher every Steam game shares.
      expect(loaded.closeWithGame, {'steam'});
    });

    test('version zero is the old per-game form', () {
      final loaded = loadJson({
        'version': 0,
        'close_with_game': ['lutris:foo'],
      });
      expect(loaded.closeWithGame, {'lutris'});
    });
  });

  group('malformed files', () {
    test('a file that is not JSON loads as defaults, without throwing', () {
      File(path).writeAsStringSync('{ this is not json');

      final loaded = AppConfig.load(path);
      expect(loaded.hidden, isEmpty);
      expect(loaded.favorites, isEmpty);
      expect(loaded.closeWithGame, isEmpty);
      expect(loaded.sortMode, 'name');
      expect(loaded.appimageDirs, AppConfig.defaultAppimageDirs);
    });

    test('a JSON document that is not an object loads as defaults', () {
      File(path).writeAsStringSync('["steam:1"]');

      final loaded = AppConfig.load(path);
      expect(loaded.hidden, isEmpty);
      expect(loaded.favorites, isEmpty);
    });

    test('a missing file loads as defaults', () {
      final loaded = AppConfig.load('${dir.path}/nope/config.json');
      expect(loaded.hidden, isEmpty);
      expect(loaded.themeMode, AppThemeMode.dark);
      expect(loaded.sortMode, 'name');
    });
  });

  test('loading a permissive config tightens its permissions', () {
    File(path).writeAsStringSync('{}');
    if (Platform.isLinux || Platform.isMacOS) {
      Process.runSync('chmod', ['644', path]);
      expect(File(path).statSync().mode & 0x3F, isNot(0));

      AppConfig.load(path);

      // The config holds the SteamGridDB key, so a load brings it back to
      // owner-only.
      expect(File(path).statSync().mode & 0x3F, 0);
    }
  });

  group('edge values', () {
    test('hidden, favorites, renames and tags round trip with unicode', () {
      AppConfig(
        hidden: {'steam:空', ''},
        favorites: ['steam:空', 'manual:café-1a2b3c'],
        nameOverrides: {'steam:空': '空のゲーム ✨'},
        tags: {
          'steam:空': ['日本語', 'Co-op'],
        },
      ).save(path);

      final loaded = AppConfig.load(path);
      expect(loaded.hidden, {'steam:空', ''});
      expect(loaded.isHidden('steam:空'), isTrue);
      expect(loaded.favorites, ['steam:空', 'manual:café-1a2b3c']);
      expect(loaded.nameOverrides, {'steam:空': '空のゲーム ✨'});
      expect(loaded.tagsFor('steam:空'), ['日本語', 'Co-op']);
    });

    test('a rename to nothing is dropped, a unicode rename is kept', () {
      final loaded = loadJson({
        'name_overrides': {
          'steam:1': '',
          'steam:2': '   ',
          'steam:3': 'Ünïcode ✨',
        },
      });

      expect(loaded.nameOverrides, {'steam:3': 'Ünïcode ✨'});
    });

    test(
      'tags are trimmed, de-duplicated and dropped when unusable',
      () {
        final loaded = loadJson({
          'tags': {
            'steam:1': ['  Co-op  ', 'co-OP', '', '日本語'],
            '': ['orphan'],
            'steam:2': 'not a list',
          },
        });

        expect(loaded.tagsFor('steam:1'), ['Co-op', '日本語']);
        // An empty id cannot name a game, so its tags are dropped.
        expect(loaded.tags.containsKey(''), isFalse);
        expect(loaded.tagsFor('steam:2'), isEmpty);
      },
    );
  });
}
