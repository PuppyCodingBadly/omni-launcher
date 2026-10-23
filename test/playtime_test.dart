import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/launcher.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/util/proc.dart';
import 'package:omni_launcher/src/ui/detail_panel.dart';
import 'package:omni_launcher/src/ui/playtime.dart';
import 'package:omni_launcher/src/ui/settings_view.dart';
import 'package:omni_launcher/src/ui/theme.dart';

/// A game that cannot be launched, for the "bookkeeping must not fail" case.
Game missingGame() => Game(
  id: 'manual:gone',
  key: 'gone',
  name: 'Gone',
  source: SourceKind.manual,
  command: const ['definitely-not-a-program-xyz'],
);

void main() {
  group('formatPlaytime', () {
    test('rounds down to the minute', () {
      expect(formatPlaytime(Duration.zero), '0m');
      expect(formatPlaytime(const Duration(seconds: 59)), '0m');
      expect(formatPlaytime(const Duration(minutes: 1)), '1m');
      expect(formatPlaytime(const Duration(minutes: 59, seconds: 59)), '59m');
    });

    test('drops the minutes when they are zero', () {
      expect(formatPlaytime(const Duration(hours: 1)), '1h');
      expect(formatPlaytime(const Duration(hours: 3)), '3h');
      expect(formatPlaytime(const Duration(hours: 100)), '100h');
    });

    test('mixes hours and minutes', () {
      expect(formatPlaytime(const Duration(hours: 12, minutes: 40)), '12h 40m');
      expect(formatPlaytime(const Duration(minutes: 61)), '1h 1m');
    });

    test('never reports a negative total', () {
      expect(formatPlaytime(const Duration(minutes: -5)), '0m');
    });
  });

  group('formatLastPlayed', () {
    final now = DateTime(2026, 10, 14, 21, 30);

    test('today and yesterday', () {
      expect(formatLastPlayed(now, now), 'today');
      expect(
        formatLastPlayed(now.subtract(const Duration(minutes: 5)), now),
        'today',
      );
      expect(formatLastPlayed(DateTime(2026, 10, 14, 0, 5), now), 'today');
      expect(
        formatLastPlayed(DateTime(2026, 10, 13, 23, 55), now),
        'yesterday',
      );
      expect(formatLastPlayed(DateTime(2026, 10, 13), now), 'yesterday');
    });

    test('counts calendar days, not 24 hour blocks', () {
      expect(
        formatLastPlayed(DateTime(2026, 10, 11, 23, 59), now),
        '3 days ago',
      );
      expect(formatLastPlayed(DateTime(2026, 10, 8), now), '6 days ago');
    });

    test('weeks, then an absolute date', () {
      expect(formatLastPlayed(DateTime(2026, 10, 7), now), 'a week ago');
      expect(formatLastPlayed(DateTime(2026, 9, 24), now), '2 weeks ago');
      expect(formatLastPlayed(DateTime(2026, 9, 16), now), '4 weeks ago');
      expect(formatLastPlayed(DateTime(2026, 9, 14), now), 'on 14 Sep 2026');
      expect(formatLastPlayed(DateTime(2025, 3, 2), now), 'on 2 Mar 2025');
    });

    test('a clock that moved backwards still reads as today', () {
      expect(formatLastPlayed(now.add(const Duration(hours: 3)), now), 'today');
    });

    test('a stored UTC instant lands on the local day', () {
      final utc = DateTime.utc(2026, 10, 12, 6);
      expect(formatLastPlayed(utc, now), formatLastPlayed(utc.toLocal(), now));
    });
  });

  group('controller', () {
    late Directory dir;
    late String configPath;
    late String cachePath;
    late String playtimePath;

    LibraryController build() => LibraryController(
      configPath: configPath,
      cachePath: cachePath,
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: playtimePath),
    );

    void seed(Map<String, Object?> entries) =>
        File(playtimePath).writeAsStringSync(jsonEncode(entries));

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omni-playtime-ui');
      configPath = '${dir.path}/config.json';
      cachePath = '${dir.path}/games.json';
      playtimePath = '${dir.path}/playtime.json';
      // Launching must never append to the real launch log.
      Launcher.logPathOverrideForTest = '${dir.path}/launch.log';
    });

    tearDown(() {
      Launcher.logPathOverrideForTest = null;
      dir.deleteSync(recursive: true);
    });

    test('played time and last played come from the store', () {
      final played = DateTime(2026, 10, 11, 18, 30);
      seed({
        'steam:1': {'total': 45600, 'played': played.millisecondsSinceEpoch},
      });
      final controller = build();
      addTearDown(controller.dispose);

      expect(
        controller.playtimeOf('steam:1'),
        const Duration(hours: 12, minutes: 40),
      );
      expect(controller.lastPlayedFor('steam:1'), played);
      expect(controller.playtimeOf('steam:2'), Duration.zero);
      expect(controller.lastPlayedFor('steam:2'), isNull);
    });

    test('start up closes a session the launcher never finished', () async {
      // The store keeps milliseconds, so the seed has to as well.
      final started = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now()
            .subtract(const Duration(hours: 2))
            .millisecondsSinceEpoch,
      );
      final seen = started.add(const Duration(minutes: 30));
      seed({
        'steam:1': {
          'total': 600,
          'started': started.millisecondsSinceEpoch,
          'seen': seen.millisecondsSinceEpoch,
        },
      });
      final controller = build();
      addTearDown(controller.dispose);
      await controller.load(refresh: false);

      // Ten minutes from before plus the half hour that was observed, and the
      // game is not credited with the time the launcher was not there for.
      expect(controller.playtimeOf('steam:1'), const Duration(minutes: 40));
      expect(controller.lastPlayedFor('steam:1'), seen);

      // The next start finds nothing open, so nothing is counted twice.
      final again = build();
      addTearDown(again.dispose);
      await again.load(refresh: false);
      expect(again.playtimeOf('steam:1'), const Duration(minutes: 40));
    });

    test('a failed launch records nothing at all', () async {
      final controller = build();
      addTearDown(controller.dispose);
      final game = missingGame();

      await controller.launch(game);

      expect(controller.failure, contains('Could not launch'));
      expect(controller.playtimeOf(game.id), Duration.zero);
      expect(controller.lastPlayedFor(game.id), isNull);
      expect(File(playtimePath).existsSync(), isFalse);
    });

    test('the heartbeat is written at most every 30 seconds', () {
      final start = DateTime(2026, 10, 14, 20);
      expect(LibraryController.shouldTouch(start, start), isFalse);
      expect(
        LibraryController.shouldTouch(
          start,
          start.add(const Duration(seconds: 29)),
        ),
        isFalse,
      );
      expect(
        LibraryController.shouldTouch(
          start,
          start.add(const Duration(seconds: 30)),
        ),
        isTrue,
      );
    });

    testWidgets('the detail panel shows played time and last played', (
      tester,
    ) async {
      // The panel scrolls; give it room so the metadata fields are laid out.
      tester.view.physicalSize = const Size(420, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final played = DateTime.now().subtract(const Duration(days: 3, hours: 2));
      seed({
        'flatpak:alpha': {
          'total': 45600,
          'played': played.millisecondsSinceEpoch,
        },
      });
      final controller = build();
      addTearDown(controller.dispose);
      const game = Game(
        id: 'flatpak:alpha',
        key: 'alpha',
        name: 'Alpha',
        source: SourceKind.flatpak,
        command: ['true'],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: DetailPanel(controller: controller, game: game),
          ),
        ),
      );

      expect(find.text('PLAYED'), findsOneWidget);
      expect(find.text('12h 40m'), findsOneWidget);
      expect(find.text('LAST PLAYED'), findsOneWidget);
      expect(
        find.text(formatLastPlayed(played, DateTime.now())),
        findsOneWidget,
      );
    });

    testWidgets('a game that was never played shows no last played', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = build();
      addTearDown(controller.dispose);
      const game = Game(
        id: 'flatpak:alpha',
        key: 'alpha',
        name: 'Alpha',
        source: SourceKind.flatpak,
        command: ['true'],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: DetailPanel(controller: controller, game: game),
          ),
        ),
      );

      expect(find.text('PLAYED'), findsOneWidget);
      expect(find.text('0m'), findsOneWidget);
      expect(find.text('LAST PLAYED'), findsNothing);
    });
    testWidgets('settings closes a launcher with its games', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = LibraryController(
        configPath: configPath,
        cachePath: cachePath,
        config: AppConfig(appimageDirs: const []),
        playtime: PlaytimeStore(path: playtimePath),
        pluginDir: '${dir.path}/plugins',
      );
      addTearDown(controller.dispose);
      controller.games = [
        const Game(
          id: 'steam:alpha',
          key: 'alpha',
          name: 'Alpha',
          source: SourceKind.steam,
          command: ['true'],
        ),
        const Game(
          id: 'flatpak:beta',
          key: 'beta',
          name: 'Beta',
          source: SourceKind.flatpak,
          command: ['true'],
        ),
      ];
      // The store reads its catalogue when it is first shown; this test has no
      // network, and a failure keeps it from asking.
      controller.catalogFailure = 'offline';

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => SettingsView(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The launcher client gets a row; the flatpak game, run directly, does
      // not.
      final row = find.widgetWithText(SwitchListTile, 'Steam');
      expect(find.widgetWithText(SwitchListTile, 'Flatpak'), findsNothing);
      expect(tester.widget<SwitchListTile>(row).value, isFalse);

      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(row).value, isTrue);
      expect(controller.config.closesWithGame(SourceKind.steam), isTrue);
      expect(
        AppConfig.load(configPath).closesWithGame(SourceKind.steam),
        isTrue,
      );

      // addTearDown runs after the pending-timer check, so the notice's
      // auto-expire timer is put out here instead.
      controller.notice = null;
    });
  });

  group('closing with the game', () {
    late Directory dir;
    late String configPath;
    late String playtimePath;

    LibraryController build({Duration? pollInterval}) => LibraryController(
      configPath: configPath,
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: playtimePath),
      pollInterval: pollInterval,
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omni-close');
      configPath = '${dir.path}/config.json';
      playtimePath = '${dir.path}/playtime.json';
      // These tests launch real processes: keep their log out of the real one.
      Launcher.logPathOverrideForTest = '${dir.path}/launch.log';
    });

    tearDown(() {
      Launcher.logPathOverrideForTest = null;
      dir.deleteSync(recursive: true);
    });

    test('descendants walks deeper than the direct children', () async {
      // sh -> sh -> sleep: the sleep is a grandchild, so a one level walk
      // would not find it.
      final process = await Process.start('sh', [
        '-c',
        "sh -c 'sleep 30 & wait' & wait",
      ]);
      addTearDown(() => process.kill(ProcessSignal.sigkill));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final tree = descendants(process.pid);
      final direct = tree.where((pid) => parentPid(pid) == process.pid).toSet();

      expect(direct, isNotEmpty);
      expect(tree.length, greaterThan(direct.length));
      expect(tree, isNot(contains(process.pid)));
    });

    test('a process is described while it lives and gone afterwards', () async {
      // `sleep` itself, not through a shell: some shells keep the command as
      // a child and some exec it, and this test is about a process without
      // children.
      final process = await Process.start('sleep', ['30']);
      addTearDown(() => process.kill(ProcessSignal.sigkill));

      expect(processRunning(process.pid), isTrue);
      expect(processStartTime(process.pid), isNotNull);
      expect(descendants(process.pid), isEmpty);
      // A pid that cannot exist.
      expect(processRunning(1 << 30), isFalse);
      expect(processStartTime(1 << 30), isNull);

      process.kill(ProcessSignal.sigterm);
      await process.exitCode;

      expect(processRunning(process.pid), isFalse);
    });

    test('the launcher is only closed when it should be', () {
      bool close({
        bool closeWithGame = true,
        bool alive = true,
        bool sawDescendants = true,
        int quietTicks = 2,
      }) => LibraryController.shouldCloseLauncher(
        closeWithGame: closeWithGame,
        alive: alive,
        sawDescendants: sawDescendants,
        quietTicks: quietTicks,
      );

      expect(LibraryController.closeAfterQuietTicks, 2);
      expect(close(), isTrue);
      // Off by default: nothing is ever signalled for a game that did not ask.
      expect(close(closeWithGame: false), isFalse);
      expect(close(alive: false), isFalse);
      // A process that never started a game is the game itself.
      expect(close(sawDescendants: false), isFalse);
      expect(close(quietTicks: 0), isFalse);
      expect(close(quietTicks: 1), isFalse);
    });

    test('closing with the game is chosen once per launcher', () {
      final controller = build();
      addTearDown(controller.dispose);

      controller.setCloseWithGame(SourceKind.steam, true);

      // Every game the launcher starts shares the choice; another launcher
      // is not affected.
      expect(controller.config.closesWithGame(SourceKind.steam), isTrue);
      expect(controller.config.closesWithGame(SourceKind.lutris), isFalse);
      expect(AppConfig.load(configPath).closeWithGame, {'steam'});

      controller.setCloseWithGame(SourceKind.steam, false);

      expect(controller.config.closesWithGame(SourceKind.steam), isFalse);
      expect(AppConfig.load(configPath).closeWithGame, isEmpty);
    });

    /// Waits for [condition] to hold, or gives up after [timeout].
    Future<bool> waitFor(bool Function() condition, {Duration? timeout}) async {
      final limit = timeout ?? const Duration(seconds: 8);
      final deadline = DateTime.now().add(limit);
      while (DateTime.now().isBefore(deadline)) {
        if (condition()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      return condition();
    }

    /// A launcher window that starts a game, then outlives it.
    ///
    /// It writes its own pid and records the TERM it is asked for, so a test
    /// can tell "asked to close" from "happened to exit". After the game (the
    /// `sleep 1` child) exits it blocks on a fifo, which — unlike another
    /// `sleep` — is not a child, exactly like a launcher window waiting for a
    /// click.
    Game wrapperGame(File pidFile, File termFile) {
      final script = File('${dir.path}/wrapper.sh')
        ..writeAsStringSync(
          'echo \$\$ > ${pidFile.path}\n'
          "trap 'echo term > ${termFile.path}; exit 0' TERM\n"
          'mkfifo ${dir.path}/fifo\n'
          'sleep 1\n'
          'read line < ${dir.path}/fifo\n',
        );
      return Game(
        id: 'steam:wrapper',
        key: 'wrapper',
        name: 'Wrapper',
        source: SourceKind.steam,
        command: ['sh', script.path],
      );
    }

    test('a launcher is asked to close once its game is gone', () async {
      final controller = build(pollInterval: const Duration(milliseconds: 40));
      addTearDown(controller.dispose);
      final pidFile = File('${dir.path}/pid');
      final termFile = File('${dir.path}/term');
      final game = wrapperGame(pidFile, termFile);
      controller.setCloseWithGame(game.source, true);

      await controller.launch(game);
      expect(await waitFor(() => pidFile.existsSync()), isTrue);
      final pid = int.parse(pidFile.readAsStringSync().trim());
      addTearDown(() => Process.killPid(pid, ProcessSignal.sigkill));

      expect(await waitFor(() => termFile.existsSync()), isTrue);
      expect(termFile.readAsStringSync().trim(), 'term');
    });

    test('stop asks the game to exit and is not a quick exit', () async {
      final controller = build(pollInterval: const Duration(milliseconds: 40));
      addTearDown(controller.dispose);
      final pidFile = File('${dir.path}/pid');
      final termFile = File('${dir.path}/term');
      final game = wrapperGame(pidFile, termFile);

      await controller.launch(game);
      expect(await waitFor(() => pidFile.existsSync()), isTrue);
      expect(controller.isRunning(game.id), isTrue);

      controller.stop(game);
      expect(controller.isStopping(game.id), isTrue);
      expect(await waitFor(() => termFile.existsSync()), isTrue);
      expect(await waitFor(() => !controller.isRunning(game.id)), isTrue);
      expect(controller.isStopping(game.id), isFalse);
      expect(controller.quickExitFor(game.id), isNull);
    });

    test('a second launch while running does nothing', () async {
      final controller = build(pollInterval: const Duration(milliseconds: 40));
      addTearDown(controller.dispose);
      const game = Game(
        id: 'steam:dup',
        key: 'dup',
        name: 'Dup',
        source: SourceKind.steam,
        command: ['sleep', '30'],
      );

      await controller.launch(game);
      expect(await waitFor(() => controller.isRunning(game.id)), isTrue);
      await controller.launch(game);
      final log = File('${dir.path}/launch.log').readAsStringSync();
      expect('launched ${game.id}'.allMatches(log).length, 1);
      expect(controller.notice, contains('already running'));

      controller.stop(game);
      expect(await waitFor(() => !controller.isRunning(game.id)), isTrue);
    });

    test('a game that exits at once keeps its exit and its log', () async {
      final controller = build(pollInterval: const Duration(milliseconds: 40));
      addTearDown(controller.dispose);
      const game = Game(
        id: 'steam:quick',
        key: 'quick',
        name: 'Quick',
        source: SourceKind.steam,
        command: ['false'],
      );

      await controller.launch(game);
      expect(
        await waitFor(() => controller.quickExitFor(game.id) != null),
        isTrue,
      );
      expect(controller.latestQuickExit?.gameId, game.id);
      expect(controller.launchLogFor(game), contains('launched ${game.id}'));
    });

    test('a game that did not ask is left alone', () async {
      final controller = build(pollInterval: const Duration(milliseconds: 40));
      addTearDown(controller.dispose);
      final pidFile = File('${dir.path}/pid');
      final termFile = File('${dir.path}/term');
      final game = wrapperGame(pidFile, termFile);

      await controller.launch(game);
      expect(await waitFor(() => pidFile.existsSync()), isTrue);
      final pid = int.parse(pidFile.readAsStringSync().trim());
      addTearDown(() => Process.killPid(pid, ProcessSignal.sigkill));

      // Its game is long gone, but the option is off: nothing is signalled.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(termFile.existsSync(), isFalse);
      expect(processRunning(pid), isTrue);
    });
  });
}
