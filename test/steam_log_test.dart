import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/util/steam_log.dart';

void main() {
  late Directory dir;
  late File log;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-steam-log');
    log = File('${dir.path}/gameprocess_log.txt')..writeAsStringSync('');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  void write(String text) =>
      log.writeAsStringSync(text, mode: FileMode.append, flush: true);

  String line(String stamp, String text) => '[$stamp] $text\n';

  group('SteamHandoff.find', () {
    test('names the app and the client log of a native Steam install', () {
      final handoff = SteamHandoff.find([
        '/usr/bin/steam',
        '-applaunch',
        '1962700',
      ], home: '/home/jade');

      expect(handoff?.appId, '1962700');
      expect(handoff?.path, '/home/jade/.steam/steam/logs/gameprocess_log.txt');
    });

    test('follows the flatpak client to its own home', () {
      final handoff = SteamHandoff.find([
        'flatpak',
        'run',
        'com.valvesoftware.Steam',
        '-applaunch',
        '42',
      ], home: '/home/jade');

      expect(
        handoff?.path,
        '/home/jade/.var/app/com.valvesoftware.Steam/.local/share/Steam/logs/'
        'gameprocess_log.txt',
      );
    });

    test('a command that does not hand off has no log', () {
      expect(SteamHandoff.find(['/usr/bin/game', '--play']), isNull);
      expect(SteamHandoff.find(['/usr/bin/steam', '-applaunch']), isNull);
      expect(SteamHandoff.find(const []), isNull);
    });
  });

  group('SteamGameLog', () {
    test('waits, runs while Steam tracks a process, and ends on remove', () {
      final follow = SteamGameLog(appId: '42', path: log.path);
      follow.start();
      // The launcher asked for the game; Steam has not reported it yet.
      expect(follow.state, SteamGameState.starting);

      write(
        line(
          '2026-10-24 19:00:00',
          'AppID 42 adding PID 123 as a tracked process',
        ),
      );
      follow.poll();
      expect(follow.state, SteamGameState.running);
      expect(follow.pids, {123});

      write(
        line(
          '2026-10-24 19:05:00',
          'AppID 42 no longer tracking PID 123, exit code 0',
        ),
      );
      write(line('2026-10-24 19:05:00', 'Remove 42 from running list'));
      follow.poll();
      expect(follow.state, SteamGameState.ended);
      expect(follow.pids, isEmpty);
      expect(follow.endedAt, DateTime(2026, 10, 24, 19, 5));
    });

    test('a game already running when Steam was asked is adopted', () {
      // The game was started earlier; the launch only focuses it.
      write(
        line(
          '2026-10-24 18:00:00',
          'AppID 42 adding PID 7 as a tracked process',
        ),
      );
      final follow = SteamGameLog(appId: '42', path: log.path);

      follow.start();

      expect(follow.state, SteamGameState.running);
      expect(follow.pids, {7});
    });

    test('an earlier game end is not this launch\'s end', () {
      write(line('2026-10-24 18:00:00', 'Remove 42 from running list'));
      write(
        line(
          '2026-10-24 18:01:00',
          'AppID 7 adding PID 1 as a tracked process',
        ),
      );
      final follow = SteamGameLog(appId: '42', path: log.path);

      follow.start();

      // Steam is starting our game; the last thing it said about this app
      // was a different session ending.
      expect(follow.state, SteamGameState.starting);
    });

    test('another app\'s lines are not ours', () {
      final follow = SteamGameLog(appId: '42', path: log.path);
      follow.start();

      write(
        line(
          '2026-10-24 19:00:00',
          'AppID 420 adding PID 9 as a tracked process',
        ),
      );
      write(line('2026-10-24 19:00:01', 'Remove 420 from running list'));
      follow.poll();

      expect(follow.state, SteamGameState.starting);
      expect(follow.pids, isEmpty);
    });

    test('a line Steam is still writing waits for its end', () {
      final follow = SteamGameLog(appId: '42', path: log.path);
      follow.start();

      write('[2026-10-24 19:00:00] AppID 42 adding PID 12');
      follow.poll();
      expect(follow.state, SteamGameState.starting);

      write('3 as a tracked process\n');
      follow.poll();
      expect(follow.state, SteamGameState.running);
      expect(follow.pids, {123});
    });

    test('a rotated log says the game Steam was running is gone', () {
      write(
        line(
          '2026-10-24 18:00:00',
          'AppID 42 adding PID 7 as a tracked process',
        ),
      );
      final follow = SteamGameLog(appId: '42', path: log.path);
      follow.start();
      expect(follow.state, SteamGameState.running);

      // Steam restarted: the log is rewritten, and the game it was running
      // went with it.
      log.writeAsStringSync(line('2026-10-24 20:00:00', 'Client version: 1'));
      follow.poll();

      expect(follow.state, SteamGameState.ended);
      expect(follow.endedAt, isNotNull);
    });

    test('a removed game forgets the pids a stop would have signalled', () {
      write(
        line(
          '2026-10-24 18:00:00',
          'AppID 42 adding PID 7 as a tracked process',
        ),
      );
      write(line('2026-10-24 18:30:00', 'Remove 42 from running list'));
      write(
        line(
          '2026-10-24 18:40:00',
          'AppID 42 adding PID 8 as a tracked process',
        ),
      );
      final follow = SteamGameLog(appId: '42', path: log.path);

      follow.start();

      expect(follow.state, SteamGameState.running);
      expect(follow.pids, {8});
    });

    test('a log that is not there yet starts when it appears', () {
      log.deleteSync();
      final follow = SteamGameLog(appId: '42', path: log.path);
      follow.start();
      expect(follow.state, SteamGameState.starting);

      log.writeAsStringSync(
        line(
          '2026-10-24 19:00:00',
          'AppID 42 adding PID 5 as a tracked process',
        ),
      );
      follow.poll();

      expect(follow.state, SteamGameState.running);
      expect(follow.pids, {5});
    });
  });
}
