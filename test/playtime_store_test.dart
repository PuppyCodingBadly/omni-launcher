import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';

void main() {
  late Directory dir;
  late String path;
  late PlaytimeStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-playtime');
    path = '${dir.path}/playtime.json';
    store = PlaytimeStore(path: path);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  final start = DateTime(2026, 10, 14, 18, 0);

  test('a finished session is added to the total', () {
    store.begin('steam:1', start);
    store.end('steam:1', start.add(const Duration(minutes: 42, seconds: 30)));
    expect(store.totalFor('steam:1'), const Duration(minutes: 42, seconds: 30));
    expect(store.isOpen('steam:1'), isFalse);
    expect(store.lastPlayedFor('steam:1'), start.add(const Duration(minutes: 42, seconds: 30)));
  });

  test('sessions accumulate', () {
    store.begin('steam:1', start);
    store.end('steam:1', start.add(const Duration(hours: 1)));
    store.begin('steam:1', start.add(const Duration(hours: 5)));
    store.end('steam:1', start.add(const Duration(hours: 5, minutes: 30)));
    expect(store.totalFor('steam:1'), const Duration(hours: 1, minutes: 30));
  });

  test('an open session counts only what was observed', () {
    store.begin('steam:1', start);
    store.touch('steam:1', start.add(const Duration(minutes: 10)));
    // Ten minutes observed so far, even though "now" is much later.
    expect(store.totalFor('steam:1'), const Duration(minutes: 10));
    expect(store.isOpen('steam:1'), isTrue);
  });

  test('touch never moves time backwards and skips the write', () {
    store.begin('steam:1', start);
    store.touch('steam:1', start.add(const Duration(minutes: 20)));
    final before = File(path).readAsBytesSync();
    store.touch('steam:1', start.add(const Duration(minutes: 5)));
    store.touch('steam:1', start.add(const Duration(minutes: 20)));
    expect(store.totalFor('steam:1'), const Duration(minutes: 20));
    // No rewrite happened: the file still holds exactly the earlier bytes.
    expect(File(path).readAsBytesSync(), before);
    final reopened = PlaytimeStore(path: path);
    expect(reopened.isOpen('steam:1'), isTrue);
    expect(reopened.totalFor('steam:1'), const Duration(minutes: 20));
  });

  test('a session left open by a crash closes at the last tick', () {
    store.begin('steam:1', start);
    store.touch('steam:1', start.add(const Duration(minutes: 30)));
    // The launcher died; a new one starts an hour later.
    final reopened = PlaytimeStore(path: path);
    expect(reopened.isOpen('steam:1'), isTrue);
    reopened.closeOpenSessions(start.add(const Duration(hours: 1)));
    expect(reopened.totalFor('steam:1'), const Duration(minutes: 30));
    expect(reopened.isOpen('steam:1'), isFalse);
  });

  test('a session with no ticks closes at its start', () {
    store.begin('steam:1', start);
    store.closeOpenSessions(start.add(const Duration(days: 2)));
    expect(store.totalFor('steam:1'), Duration.zero);
    expect(store.isOpen('steam:1'), isFalse);
  });

  test('begin closes a session that was already open', () {
    store.begin('steam:1', start);
    store.begin('steam:1', start.add(const Duration(minutes: 15)));
    store.end('steam:1', start.add(const Duration(minutes: 20)));
    expect(store.totalFor('steam:1'), const Duration(minutes: 20));
    expect(store.entries['steam:1']!.isOpen, isFalse);
  });

  test('end without a session is a no-op', () {
    store.end('steam:1', start);
    expect(store.totalFor('steam:1'), Duration.zero);
    expect(store.entries, isEmpty);
  });

  test('history survives a reload', () {
    store.begin('steam:1', start);
    store.end('steam:1', start.add(const Duration(hours: 3)));
    final reloaded = PlaytimeStore(path: path);
    expect(reloaded.totalFor('steam:1'), const Duration(hours: 3));
    expect(reloaded.lastPlayedFor('steam:1'), start.add(const Duration(hours: 3)));
  });

  test('a corrupt or foreign file is ignored', () {
    File(path).writeAsStringSync('{ not json');
    expect(PlaytimeStore(path: path).entries, isEmpty);

    File(path).writeAsStringSync(
      jsonEncode({
        'steam:1': {'total': 90, 'played': start.millisecondsSinceEpoch},
        'steam:2': 'nonsense',
        'steam:3': {'total': '120'},
        'steam:4': {'total': -5, 'played': 'garbage'},
      }),
    );
    final loaded = PlaytimeStore(path: path);
    expect(loaded.totalFor('steam:1'), const Duration(seconds: 90));
    expect(loaded.lastPlayedFor('steam:1'), start);
    expect(loaded.entries.containsKey('steam:2'), isFalse);
    expect(loaded.totalFor('steam:3'), const Duration(seconds: 120));
    expect(loaded.totalFor('steam:4'), Duration.zero);
    expect(loaded.lastPlayedFor('steam:4'), isNull);
  });

  test('a pre-version file without a version field still loads', () {
    File(path).writeAsStringSync(
      jsonEncode({
        'steam:1': {'total': 60, 'played': start.millisecondsSinceEpoch},
      }),
    );
    final loaded = PlaytimeStore(path: path);
    expect(loaded.totalFor('steam:1'), const Duration(minutes: 1));
    expect(loaded.lastPlayedFor('steam:1'), start);
  });

  test('saving writes a schema version and leaves no temporary file', () {
    store.begin('steam:1', start);
    final saved = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    expect(saved['version'], 1);
    expect(saved['steam:1'], isA<Map>());
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('a missing file starts empty and the first session creates it', () {
    expect(store.entries, isEmpty);
    expect(File(path).existsSync(), isFalse);
    store.begin('steam:1', start);
    expect(File(path).existsSync(), isTrue);
  });
}
