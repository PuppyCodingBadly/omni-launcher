import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/window_size.dart';

void main() {
  // The channel tests below are plain tests, not testWidgets: awaiting
  // platform-channel futures inside testWidgets' FakeAsync zone stalls
  // (microtasks do not progress there), which hangs the test.
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omni-window-size');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('a saved window size survives a reload', () async {
    final first = LibraryController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      config: AppConfig(appimageDirs: const []),
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );
    // No window size is remembered by default.
    expect(first.config.windowWidth, isNull);
    expect(first.config.windowHeight, isNull);

    await first.saveWindowSize(1440, 900);
    expect(first.config.windowWidth, 1440);
    expect(first.config.windowHeight, 900);

    // On disk right away...
    final saved = AppConfig.load('${dir.path}/config.json');
    expect(saved.windowWidth, 1440);
    expect(saved.windowHeight, 900);
    first.dispose();

    // ...and in the controller the next run builds from that file.
    final second = LibraryController(
      configPath: '${dir.path}/config.json',
      cachePath: '${dir.path}/games.json',
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );
    expect(second.config.windowWidth, 1440);
    expect(second.config.windowHeight, 900);

    // A resize overwrites the remembered size.
    await second.saveWindowSize(1280, 720);
    expect(AppConfig.load('${dir.path}/config.json').windowWidth, 1280);
    expect(AppConfig.load('${dir.path}/config.json').windowHeight, 720);
    second.dispose();
  });

  test('the window calls reach the runner over its channel', () async {
    const channel = MethodChannel('omni_launcher/window');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await WindowSize.apply(1280, 720);
    await WindowSize.minimize();
    await WindowSize.show();
    await WindowSize.setTrayIcon(true);

    expect(calls.map((call) => call.method), [
      'setSize',
      'minimize',
      'show',
      'setTrayIcon',
    ]);
    expect(calls.first.arguments, {'width': 1280.0, 'height': 720.0});
    expect(calls.last.arguments, isTrue);
  });

  test('without a runner the window calls quietly do nothing', () async {
    // No handler behind the channel: like a platform without the GTK runner,
    // every call must complete instead of throwing.
    await expectLater(WindowSize.apply(1024, 768), completes);
    await expectLater(WindowSize.minimize(), completes);
    await expectLater(WindowSize.show(), completes);
    await expectLater(WindowSize.setTrayIcon(false), completes);
  });

  test('a focus event from the runner fires the listener', () async {
    var focusCount = 0;
    WindowSize.listenForFocus(() => focusCount++);
    // listenForFocus registers a real (not mock) handler on the channel;
    // drop it again so it cannot leak into other tests in this process.
    addTearDown(
      () => const MethodChannel(
        'omni_launcher/window_events',
      ).setMethodCallHandler(null),
    );

    await messenger.handlePlatformMessage(
      'omni_launcher/window_events',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('focus')),
      (_) {},
    );
    expect(focusCount, 1);

    // An unrelated call on the channel is not a focus.
    await messenger.handlePlatformMessage(
      'omni_launcher/window_events',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('blur')),
      (_) {},
    );
    expect(focusCount, 1);
  });
}
