import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/sources/lutris_categories.dart';

/// The database checked in under `test/fixtures`, built by hand with
/// `sqlite3` so the reader can be shown the real schema Lutris writes.
String get _fixture => '${Directory.current.path}/test/fixtures/lutris_pga.db';

void main() {
  test('reads slug -> category names from a pga.db', () async {
    expect(File(_fixture).existsSync(), isTrue);
    final tags = await lutrisCategoryTags([_fixture]);
    expect(tags.keys, unorderedEquals(['alpha-game', 'beta-game']));
    expect(tags['alpha-game'], unorderedEquals(['Action', 'FPS']));
    expect(tags['beta-game'], unorderedEquals(['RPG']));
  });

  test('skips databases that are not there', () async {
    final missing = '${Directory.current.path}/test/fixtures/no-such.db';
    expect(await lutrisCategoryTags([missing]), isEmpty);
    final tags = await lutrisCategoryTags([missing, _fixture]);
    expect(tags.keys, unorderedEquals(['alpha-game', 'beta-game']));
  });
}
