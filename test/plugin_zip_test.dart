import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/plugins/zip.dart';

import 'zip_fixture.dart';

void main() {
  late Directory dir;
  late String target;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-zip');
    target = '${dir.path}/out';
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a deflated archive unpacks, folders and all', () {
    unpackZip(
      archive(const [
        Entry('plugin.json', '{"id":"test"}'),
        Entry('lib/run.py', 'print("hi")\n'),
      ]),
      target,
    );

    expect(File('$target/plugin.json').readAsStringSync(), '{"id":"test"}');
    expect(File('$target/lib/run.py').readAsStringSync(), 'print("hi")\n');
  });

  test('a stored archive unpacks too', () {
    unpackZip(
      archive(const [Entry('plugin.json', '{}', method: 0)]),
      target,
    );

    expect(File('$target/plugin.json').readAsStringSync(), '{}');
  });

  test('an archive made elsewhere unpacks', () async {
    // The reader is shown a real archive, not one this file wrote: python3's
    // zipfile decides the layout, so a misunderstanding of the format cannot
    // cancel itself out.
    final script = '''
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('plugin.json', '{"id":"outside"}')
    archive.writestr('nested/dir/run.py', 'print("outside")\\n')
''';
    final built = '${dir.path}/outside.zip';
    final ProcessResult result;
    try {
      result = await Process.run('python3', ['-c', script, built]);
    } on ProcessException {
      return; // no python3 here: the fixtures above still cover the reader
    }
    expect(result.exitCode, 0, reason: '${result.stderr}');

    unpackZip(File(built).readAsBytesSync(), target);

    expect(File('$target/plugin.json').readAsStringSync(), '{"id":"outside"}');
    expect(
      File('$target/nested/dir/run.py').readAsStringSync(),
      'print("outside")\n',
    );
  });

  test('a file that climbs out of the folder is refused', () {
    expect(
      () => unpackZip(
        archive(const [Entry('../escaped.txt', 'nope')]),
        target,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(File('${dir.path}/escaped.txt').existsSync(), isFalse);
  });

  test('an absolute path is refused', () {
    expect(
      () => unpackZip(archive(const [Entry('/etc/omni', 'nope')]), target),
      throwsA(isA<FormatException>()),
    );
  });

  test('a symlink is refused', () {
    expect(
      () => unpackZip(
        archive(const [Entry('link', '/etc/passwd', mode: 0xa1ff)]),
        target,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('an encrypted archive is refused', () {
    // The flag lives in the central directory, which is what decides.
    expect(
      () => unpackZip(
        archive(const [Entry('plugin.json', '{}')], centralFlags: 0x1),
        target,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('an archive that unpacks to too much is refused', () {
    final big = 'x' * (maxPluginBytes + 1);
    expect(
      () => unpackZip(archive([Entry('plugin.json', big)]), target),
      throwsA(isA<FormatException>()),
    );
  });

  test('an archive with too many files is refused', () {
    expect(
      () => unpackZip(
        archive([
          for (var index = 0; index <= maxPluginEntries; index++)
            Entry('file$index', 'x'),
        ]),
        target,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('something that is not an archive is refused', () {
    expect(
      () => unpackZip(utf8.encode('not a zip at all'), target),
      throwsA(isA<FormatException>()),
    );
  });

  test('a truncated archive is refused', () {
    final whole = archive(const [Entry('plugin.json', '{}')]);
    expect(
      () => unpackZip(whole.sublist(0, whole.length - 30), target),
      throwsA(isA<FormatException>()),
    );
  });

  test('a file whose deflated data is damaged is refused', () {
    final whole = archive([Entry('plugin.json', 'x' * 500)]);
    // Corrupt a byte of the deflated data: 30 bytes of local header, then the
    // name, then the data itself.
    final nameLength = whole[26] | whole[27] << 8;
    final data = 30 + nameLength;
    whole[data + 2] = whole[data + 2] ^ 0xff;
    whole[data + 3] = whole[data + 3] ^ 0x55;
    expect(
      () => unpackZip(whole, target),
      throwsA(isA<FormatException>()),
    );
  });
}
