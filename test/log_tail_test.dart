import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/util/log_tail.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('omni-log-tail'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String writeLog(String contents) {
    final file = File('${dir.path}/launch.log')..writeAsStringSync(contents);
    return file.path;
  }

  test('a missing log reads as null', () {
    expect(readLogTail('${dir.path}/absent.log'), isNull);
  });

  test('an empty log reads as an empty string', () {
    expect(readLogTail(writeLog('')), '');
  });

  test('only the last lines asked for are kept', () {
    final path = writeLog('a\nb\nc\nd\ne\n');
    expect(readLogTail(path, maxLines: 2), 'd\ne');
    expect(readLogTail(path, maxLines: 10), 'a\nb\nc\nd\ne');
  });

  test('a game id starts the tail at its launch line', () {
    final path = writeLog(
      '2026-10-22T10:00:00 launched steam:440 pid=1 :: /bin/other\n'
      'other output\n'
      '2026-10-22T10:00:01 launched gog:7 pid=2 :: /bin/gog\n'
      'gog output\n'
      '2026-10-22T10:00:02 launched steam:440 pid=3 :: /bin/game\n'
      'game output one\n'
      'game output two\n',
    );

    expect(
      readLogTail(path, gameId: 'steam:440'),
      '2026-10-22T10:00:02 launched steam:440 pid=3 :: /bin/game\n'
      'game output one\n'
      'game output two',
    );
  });

  test('a game id with no launch line falls back to the plain tail', () {
    final path = writeLog(
      '2026-10-22T10:00:00 launched steam:440 pid=1 :: /bin/game\n'
      'game output\n',
    );

    expect(
      readLogTail(path, gameId: 'steam:999'),
      '2026-10-22T10:00:00 launched steam:440 pid=1 :: /bin/game\n'
      'game output',
    );
  });

  test('a byte window that starts mid-line drops the partial line', () {
    final lines = List.generate(5, (i) => 'L$i${'x' * 18}');
    final path = writeLog('${lines.join('\n')}\n');
    final length = File(path).lengthSync();
    expect(length, 105);

    // 50 bytes from the end start partway through the third line.
    final tail = readLogTail(path, maxBytes: 50);
    expect(tail, '${lines[3]}\n${lines[4]}');
  });

  test('a byte window that starts on a line boundary keeps that line', () {
    final path = writeLog('abc\ndef\nghi\n');
    expect(readLogTail(path, maxBytes: 8), 'def\nghi');
  });
}
