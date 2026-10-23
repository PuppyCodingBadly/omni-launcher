import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/sources/steam_collections.dart';

void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('steam_collections_test');
    root = temp.path;
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Write a namespace file, creating the user's config tree.
  void writeNamespace(
    String user,
    Object contents, {
    String file = 'cloud-storage-namespace-1.json',
  }) {
    final dir = Directory('$root/userdata/$user/config/cloudstorage')
      ..createSync(recursive: true);
    File(
      '${dir.path}/$file',
    ).writeAsStringSync(contents is String ? contents : jsonEncode(contents));
  }

  /// One `[key, entry]` pair for the array-shaped namespace.
  List<Object> record(String id, Map<String, Object?> value, {bool? deleted}) {
    final entry = <String, Object?>{'value': jsonEncode(value)};
    if (deleted != null) entry['is_deleted'] = deleted;
    return ['user-collections.$id', entry];
  }

  Map<String, Object?> collection(
    String id,
    String name, {
    List<Object> added = const [],
    List<Object> removed = const [],
  }) => {'id': id, 'name': name, 'added': added, 'removed': removed};

  test('reads array namespaces and applies added minus removed', () async {
    writeNamespace('1', [
      record(
        'rpg',
        collection('rpg', 'RPG', added: [10, 20, 30], removed: [20]),
      ),
      record('coop', collection('coop', 'Coop', added: [20, 440])),
      record('multi', collection('multi', 'Multi', added: [440])),
      record('gone', collection('gone', 'Deleted', added: [99]), deleted: true),
      record('hidden', collection('hidden', 'Hidden', added: [7])),
      record('favorite', collection('favorite', 'Favorite', added: [8])),
      record('blank', collection('blank', '   ', added: [5])),
    ]);

    final tags = await steamCollectionTags([root]);

    expect(tags.keys.toSet(), {'10', '30', '20', '440'});
    expect(tags['10'], {'RPG'});
    expect(tags['30'], {'RPG'});
    expect(tags['20'], {'Coop'});
    expect(tags['440'], {'Coop', 'Multi'});
    expect(tags.containsKey('7'), isFalse);
    expect(tags.containsKey('8'), isFalse);
    expect(tags.containsKey('5'), isFalse);
    expect(tags.containsKey('99'), isFalse);
  });

  test('reads object-shaped namespaces with inline values', () async {
    writeNamespace('2', {
      'user-collections.object': {
        'value': collection('object', 'Object Shaped', added: [1, 2]),
      },
      'user-collections.string': {
        'value': jsonEncode(collection('string', 'String Shaped', added: [3])),
      },
      'other-key': {'value': 'ignored'},
    });

    final tags = await steamCollectionTags([root]);

    expect(tags, {
      '1': {'Object Shaped'},
      '2': {'Object Shaped'},
      '3': {'String Shaped'},
    });
  });

  test('accepts numeric string app ids', () async {
    writeNamespace('3', [
      record(
        'mixed',
        collection('mixed', 'Mixed', added: ['10', 20], removed: ['20']),
      ),
    ]);

    final tags = await steamCollectionTags([root]);

    expect(tags, {
      '10': {'Mixed'},
    });
  });

  test('returns an empty map for missing roots and users', () async {
    expect(await steamCollectionTags([]), isEmpty);
    expect(await steamCollectionTags(['$root/nope']), isEmpty);
    expect(await steamCollectionTags([root]), isEmpty);
  });

  test('skips malformed namespaces and modified copies', () async {
    writeNamespace('4', '{ not json', file: 'cloud-storage-namespace-1.json');
    writeNamespace('4', [
      record('live', collection('live', 'Live', added: [42])),
    ], file: 'cloud-storage-namespace-2.json');
    writeNamespace('4', [
      record('stale', collection('stale', 'Stale', added: [43])),
    ], file: 'cloud-storage-namespace-1.json.modified.json');
    writeNamespace('4', [
      ['user-collections.bad'],
      [
        42,
        {'value': 'ignored'},
      ],
      [
        'user-collections.novalue',
        {'value': 7},
      ],
    ], file: 'cloud-storage-namespace-3.json');

    final tags = await steamCollectionTags([root]);

    expect(tags, {
      '42': {'Live'},
    });
  });
}
