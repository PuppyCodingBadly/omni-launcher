import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
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

  test('a renamed manual entry keeps its key, so the game id is stable', () async {
    final loaded = loadJson({
      'manual': [
        {'name': 'Alpha', 'key': 'alpha-1a2b3c', 'command': ['/opt/run']},
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
  });

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
        {'name': 'Alpha', 'command': ['/opt/a']},
        {'name': 'Alpha', 'command': ['/opt/b']},
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
      manual: [ManualEntry(name: 'Alpha', key: 'alpha-1a2b3c', command: ['/opt/run'])],
    ).save(path);

    final saved = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    expect(saved['version'], 1);
    expect(File('$path.tmp').existsSync(), isFalse);
    // The key survives the round trip.
    expect(AppConfig.load(path).manual.single.key, 'alpha-1a2b3c');
  });

  test('the saved config is readable by the owner alone', () {
    AppConfig().save(path);
    if (Platform.isLinux || Platform.isMacOS) {
      expect(File(path).statSync().mode & 0x3F, 0);
    }
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
    final saved = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    expect(saved.containsKey('window'), isFalse);
  });
}
