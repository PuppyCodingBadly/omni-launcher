import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/art/steamgriddb.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/covers.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/state/library_controller.dart';
import 'package:omni_launcher/src/state/playtime_store.dart';
import 'package:omni_launcher/src/ui/art_picker.dart';
import 'package:omni_launcher/src/ui/accent_colors.dart';
import 'package:omni_launcher/src/ui/detail_panel.dart';
import 'package:omni_launcher/src/ui/game_tile.dart';
import 'package:omni_launcher/src/ui/library_page.dart';
import 'package:omni_launcher/src/ui/settings_view.dart';
import 'package:omni_launcher/src/ui/theme.dart';

/// Contrast ratio between two opaque colours (WCAG 2.1).
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The GNOME basic accent palette the appearance setting will offer.
const Map<String, Color> adwaitaAccents = {
  'Default': Color(0xFF8A6BFF),
  'Blue': Color(0xFF3584E4),
  'Teal': Color(0xFF2190A4),
  'Green': Color(0xFF3A944A),
  'Yellow': Color(0xFFE5A50A),
  'Orange': Color(0xFFED5B00),
  'Red': Color(0xFFE01B24),
  'Pink': Color(0xFFD56199),
  'Purple': Color(0xFF9141AC),
  'Slate': Color(0xFF6F8396),
};

/// Mirrors the wiring in `lib/main.dart`.
class _Harness extends StatelessWidget {
  const _Harness({required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => MaterialApp(
      theme: AppTheme.themeFor(
        Brightness.light,
        controller.config.accent.color,
      ),
      darkTheme: AppTheme.themeFor(
        Brightness.dark,
        controller.config.accent.color,
      ),
      themeMode: materialThemeMode(controller.config.themeMode),
      home: Builder(
        builder: (context) => ColoredBox(
          key: const ValueKey('probe'),
          color: context.palette.background,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

/// The same wiring, with the real library page as the home route.
class _AppHarness extends StatelessWidget {
  const _AppHarness({required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: materialThemeMode(controller.config.themeMode),
      home: LibraryPage(controller: controller),
    ),
  );
}

/// A controller that records what the UI asked the artwork layer for.
class _RecordingController extends LibraryController {
  _RecordingController({super.configPath, super.cachePath, super.config});

  /// Game ids the tiles asked for a cover.
  final List<String> fetched = <String>[];

  /// Game ids the art picker asked SteamGridDB for.
  final List<String> searched = <String>[];

  @override
  Future<Artwork?> requestCoverArt(Game game) async {
    fetched.add(game.id);
    return null;
  }

  @override
  Future<List<SgdbGrid>> searchArt(Game game) async {
    searched.add(game.id);
    return const [];
  }
}

/// Rendered height of the cover box inside the first tile.
double coverHeight(WidgetTester tester) => tester
    .getSize(
      find
          .descendant(
            of: find.byType(GameTile),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    )
    .height;

/// A controller whose picks always fail, for the picker's error path.
class _FailingArtController extends LibraryController {
  _FailingArtController({
    super.configPath,
    super.cachePath,
    super.config,
    super.playtime,
  });

  int attempts = 0;

  @override
  Future<List<SgdbGrid>> searchArt(Game game) async => const [
    SgdbGrid(
      id: 7,
      url: 'https://cdn.example/grid/7.png',
      thumb: 'https://cdn.example/thumb/7.png',
    ),
  ];

  @override
  Future<bool> applyArt(Game game, SgdbGrid grid) async {
    attempts++;
    throw const SteamGridDbException('SteamGridDB could not be reached.');
  }
}

/// A one pixel PNG, so `Image.file` decodes instead of falling back.
const String onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

const Game alphaGame = Game(
  id: 'flatpak:alpha',
  key: 'alpha',
  name: 'Alpha',
  source: SourceKind.flatpak,
  command: ['true'],
);

/// The artwork image inside the first tile, when it has one.
Finder tileArtwork() =>
    find.descendant(of: find.byType(GameTile), matching: find.byType(Image));

Game game(String id, String name, SourceKind source) => Game(
  id: id,
  key: id.split(':').last,
  name: name,
  source: source,
  command: const ['true'],
);

Color probedBackground(WidgetTester tester) =>
    tester.widget<ColoredBox>(find.byKey(const ValueKey('probe'))).color;

void main() {
  group('palette', () {
    test('the dark palette is byte for byte the old hardcoded one', () {
      expect(AppPalette.dark.background, const Color(0xFF0E0E13));
      expect(AppPalette.dark.sidebar, const Color(0xFF14141B));
      expect(AppPalette.dark.surface, const Color(0xFF1A1A23));
      expect(AppPalette.dark.surfaceHigh, const Color(0xFF23232E));
      expect(AppPalette.dark.accent, const Color(0xFF8A6BFF));
      expect(AppPalette.dark.accentSoft, const Color(0xFFB9A5FF));
      expect(AppPalette.dark.text, const Color(0xFFEDEDF2));
      expect(AppPalette.dark.textDim, const Color(0xFF9A9AAB));
      expect(AppPalette.dark.warning, Colors.orangeAccent);
      expect(AppPalette.dark.tileLetter, const Color(0x66FFFFFF));
      expect(AppPalette.dark.previewLetter, const Color(0x55FFFFFF));
      expect(AppPalette.dark.scrim, const [
        Color(0xCC000000),
        Color(0x22000000),
        Color(0xE6000000),
      ]);
      expect(AppPalette.dark.shadow, Colors.black);
      expect(AppPalette.dark.shadowAlpha, 0.25);
      expect(AppPalette.dark.shadowHoverAlpha, 0.45);
    });

    test('the dark theme data keeps the old colours', () {
      final theme = AppTheme.dark;
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0E0E13));
      expect(theme.colorScheme.primary, const Color(0xFF8A6BFF));
      expect(theme.colorScheme.secondary, const Color(0xFFB9A5FF));
      expect(theme.colorScheme.surface, const Color(0xFF0E0E13));
      expect(theme.colorScheme.onSurface, const Color(0xFFEDEDF2));
      expect(theme.inputDecorationTheme.fillColor, const Color(0xFF1A1A23));
      expect(theme.popupMenuTheme.color, const Color(0xFF23232E));
      expect(theme.extension<AppPalette>(), AppPalette.dark);
    });

    test('the light theme carries the light palette', () {
      final theme = AppTheme.light;
      expect(theme.brightness, Brightness.light);
      expect(theme.extension<AppPalette>(), AppPalette.light);
      expect(theme.scaffoldBackgroundColor, AppPalette.light.background);
      expect(theme.colorScheme.onSurface, AppPalette.light.text);
    });

    test('text keeps a readable contrast in both modes', () {
      for (final palette in [AppPalette.dark, AppPalette.light]) {
        expect(
          contrast(palette.text, palette.background),
          greaterThan(4.5),
          reason: 'body text',
        );
        expect(
          contrast(palette.textDim, palette.background),
          greaterThan(4.5),
          reason: 'dim text',
        );
        expect(
          contrast(palette.textDim, palette.sidebar),
          greaterThan(4.5),
          reason: 'dim text on the sidebar',
        );
        expect(
          contrast(palette.warning, palette.background),
          greaterThan(4.5),
          reason: 'warning text',
        );
        expect(
          contrast(palette.accentSoft, palette.background),
          greaterThan(4.5),
          reason: 'text button label',
        );
        // 15px semibold on the accent: the dark look ships at 3.7, so only the
        // large-text floor is a hard requirement.
        expect(
          contrast(Colors.white, palette.accent),
          greaterThan(3),
          reason: 'filled button label',
        );
      }
      // Light mode has no such excuse.
      expect(contrast(Colors.white, AppPalette.light.accent), greaterThan(4.5));
    });

    test('lerp moves between the two palettes', () {
      final half = AppPalette.dark.lerp(AppPalette.light, 0.5);
      expect(
        half.background,
        Color.lerp(
          AppPalette.dark.background,
          AppPalette.light.background,
          0.5,
        ),
      );
      expect(half.scrim.length, 3);
      expect(half.shadowHoverAlpha, closeTo(0.325, 1e-9));
      expect(AppPalette.dark.lerp(null, 0.5), AppPalette.dark);
    });

    test('materialThemeMode covers every choice', () {
      expect(materialThemeMode(AppThemeMode.system), ThemeMode.system);
      expect(materialThemeMode(AppThemeMode.dark), ThemeMode.dark);
      expect(materialThemeMode(AppThemeMode.light), ThemeMode.light);
    });

    test('the default accent returns the shipped palettes untouched', () {
      expect(
        AppPalette.forMode(Brightness.dark, AppPalette.dark.accent),
        same(AppPalette.dark),
      );
      expect(
        AppPalette.forMode(Brightness.light, AppPalette.light.accent),
        same(AppPalette.light),
      );
      expect(
        AppTheme.themeFor(Brightness.dark, AppPalette.dark.accent),
        same(AppTheme.dark),
      );
      expect(
        AppTheme.themeFor(Brightness.light, AppPalette.light.accent),
        same(AppTheme.light),
      );
    });

    test('every Adwaita accent stays readable in both modes', () {
      for (final entry in adwaitaAccents.entries) {
        for (final brightness in Brightness.values) {
          final reason = '${entry.key} in $brightness';
          final palette = AppPalette.forMode(brightness, entry.value);
          expect(palette.accent, entry.value, reason: reason);
          expect(
            contrast(palette.accentSoft, palette.background),
            greaterThanOrEqualTo(4.5),
            reason: '$reason: muted accent on the page',
          );
          expect(
            contrast(palette.accentSoft, palette.sidebar),
            greaterThanOrEqualTo(4.5),
            reason: '$reason: muted accent on the sidebar',
          );
          expect(
            contrast(palette.onAccent, palette.accent),
            greaterThanOrEqualTo(3),
            reason: '$reason: button label on the accent',
          );
          final theme = AppTheme.themeFor(brightness, entry.value);
          expect(theme.colorScheme.primary, entry.value, reason: reason);
          expect(
            theme.scaffoldBackgroundColor,
            palette.background,
            reason: reason,
          );
          expect(
            theme.filledButtonTheme.style?.foregroundColor?.resolve(
              <WidgetState>{},
            ),
            palette.onAccent,
            reason: reason,
          );
        }
      }
    });

    test('a pale accent gets dark button labels', () {
      const yellow = Color(0xFFE5A50A);
      expect(
        AppPalette.forMode(Brightness.dark, yellow).onAccent,
        Colors.black,
      );
      expect(
        AppPalette.forMode(Brightness.light, yellow).onAccent,
        Colors.black,
      );
      expect(
        AppPalette.forMode(Brightness.dark, AppPalette.dark.accent).onAccent,
        Colors.white,
      );
    });

    test('themeFor memoizes per mode and accent', () {
      const blue = Color(0xFF3584E4);
      expect(
        AppTheme.themeFor(Brightness.dark, blue),
        same(AppTheme.themeFor(Brightness.dark, blue)),
      );
      expect(
        AppTheme.themeFor(Brightness.light, blue),
        isNot(same(AppTheme.themeFor(Brightness.dark, blue))),
      );
    });

    testWidgets('context.palette follows the ambient theme', (tester) async {
      late AppPalette seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) {
              seen = context.palette;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen, AppPalette.light);
    });
  });

  group('poster geometry', () {
    late Directory dir;
    late String configPath;
    late String cachePath;
    late _RecordingController controller;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omni-shape');
      configPath = '${dir.path}/config.json';
      cachePath = '${dir.path}/games.json';
      controller = _RecordingController(
        configPath: configPath,
        cachePath: cachePath,
        config: AppConfig(
          appimageDirs: const [],
          coverFetch: false,
          steamgriddbKey: 'key',
          steamgriddbAuto: true,
        ),
      )..games = [game('flatpak:alpha', 'Alpha', SourceKind.flatpak)];
      controller.status = LibraryStatus.ready;
    });

    tearDown(() {
      controller.dispose();
      dir.deleteSync(recursive: true);
    });

    testWidgets('the wall stays portrait, whatever the window shape', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_AppHarness(controller: controller));
      await tester.pumpAndSettle();

      expect(controller.fetched, ['flatpak:alpha']);
      expect(coverHeight(tester), 252);
      final cell = tester.getSize(find.byType(GameTile));
      expect(
        cell.height / cell.width,
        closeTo((GameTile.coverHeight + 68) / GameTile.width, 0.001),
      );

      // A square window used to switch the wall to square posters and square
      // tiles; both are gone, so a resize must not change the geometry.
      tester.view.physicalSize = const Size(900, 900);
      await tester.pumpAndSettle();

      expect(coverHeight(tester), 252);
      final square = tester.getSize(find.byType(GameTile));
      expect(
        square.height / square.width,
        closeTo((GameTile.coverHeight + 68) / GameTile.width, 0.001),
      );
      expect(controller.fetched, ['flatpak:alpha']);

      // The detail panel draws the poster's own 2:3 too: a wide or square box
      // there crops the art the tile shows.
      controller.select(controller.games.first);
      await tester.pumpAndSettle();
      final preview = tester.getSize(
        find.descendant(
          of: find.byType(DetailPanel),
          matching: find.byType(AspectRatio),
        ),
      );
      expect(preview.width / preview.height, closeTo(2 / 3, 0.01));
    });
  });

  group('artwork', () {
    late Directory dir;
    late String configPath;
    late String cachePath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omni-art');
      configPath = '${dir.path}/config.json';
      cachePath = '${dir.path}/games.json';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    LibraryController controllerWith(AppConfig config) => LibraryController(
      configPath: configPath,
      cachePath: cachePath,
      config: config,
      playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
    );

    testWidgets('a tile follows artwork pinned for the same game', (
      tester,
    ) async {
      final art = File('${dir.path}/picked.png')
        ..writeAsBytesSync(base64Decode(onePixelPng));
      final controller =
          controllerWith(
              AppConfig(
                appimageDirs: const [],
                artOverrides: {alphaGame.id: art.path},
              ),
            )
            ..games = [alphaGame]
            ..status = LibraryStatus.ready;
      addTearDown(controller.dispose);

      await tester.pumpWidget(_AppHarness(controller: controller));
      await tester.pumpAndSettle();
      expect(tileArtwork(), findsOneWidget);
      expect(find.text('A'), findsNothing);

      // Dropping the pinned art has to reach the tile even though the game id
      // did not change: that staleness is what made a pick look like a no-op.
      controller.clearArt(alphaGame);
      await tester.pumpAndSettle();

      expect(tileArtwork(), findsNothing);
      expect(find.text('A'), findsOneWidget);

      // addTearDown runs after the pending-timer check, so the notice's
      // auto-expire timer is put out here instead.
      controller.notice = null;
    });

    testWidgets('the picker reports a failed pick and stays usable', (
      tester,
    ) async {
      final controller = _FailingArtController(
        configPath: configPath,
        cachePath: cachePath,
        config: AppConfig(appimageDirs: const [], steamgriddbKey: 'key'),
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showArtPicker(context, controller, alphaGame),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final candidate = find
          .descendant(of: find.byType(GridView), matching: find.byType(InkWell))
          .first;
      await tester.tap(candidate);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('SteamGridDB could not be reached.'), findsOneWidget);

      // The dialog is still live: a second pick is attempted instead of the
      // candidates going dead behind a stuck "applying" spinner.
      await tester.tap(candidate);
      await tester.pumpAndSettle();
      expect(controller.attempts, 2);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('the picker shows candidates in the portrait cells it pins', (
      tester,
    ) async {
      final controller = _FailingArtController(
        configPath: configPath,
        cachePath: cachePath,
        config: AppConfig(appimageDirs: const [], steamgriddbKey: 'key'),
        playtime: PlaytimeStore(path: '${dir.path}/playtime.json'),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showArtPicker(context, controller, alphaGame),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The cell has the shape the wall draws, so a pick looks like the tile
      // it lands on.
      final cell = tester.getSize(
        find
            .descendant(
              of: find.byType(GridView),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(cell.width / cell.height, closeTo(2 / 3, 0.01));
    });

    test('a download that blows up is reported instead of thrown', () async {
      final controller = controllerWith(
        AppConfig(appimageDirs: const [], steamgriddbKey: 'key'),
      );
      addTearDown(controller.dispose);

      // This url cannot even be parsed, so the download throws before it
      // reaches the network. It used to escape `applyArt` and wedge the picker.
      final ok = await controller.applyArt(
        alphaGame,
        const SgdbGrid(id: 1, url: 'http://[::1', thumb: ''),
      );

      expect(ok, isFalse);
      expect(controller.failure, contains('Alpha'));
      expect(controller.failure, contains('Missing end'));
    });
  });

  group('appearance', () {
    late Directory dir;
    late String configPath;
    late LibraryController controller;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omni-theme');
      configPath = '${dir.path}/config.json';
      controller = LibraryController(
        configPath: configPath,
        config: AppConfig(),
      );
      // Notices expire on a timer; a live controller must not outlive the test.
      addTearDown(controller.dispose);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('the window repaints when the mode changes', (tester) async {
      await tester.pumpWidget(_Harness(controller: controller));
      expect(probedBackground(tester), AppPalette.dark.background);

      controller.setThemeMode(AppThemeMode.light);
      await tester.pumpAndSettle();
      expect(probedBackground(tester), AppPalette.light.background);

      controller.setThemeMode(AppThemeMode.dark);
      await tester.pumpAndSettle();
      expect(probedBackground(tester), AppPalette.dark.background);
    });

    testWidgets('System follows the platform brightness', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      controller.setThemeMode(AppThemeMode.system);
      await tester.pumpWidget(_Harness(controller: controller));
      expect(probedBackground(tester), AppPalette.light.background);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(probedBackground(tester), AppPalette.dark.background);
    });

    testWidgets('the library follows the controller through the shell', (
      tester,
    ) async {
      controller.games = [game('flatpak:alpha', 'Alpha', SourceKind.flatpak)];
      controller.status = LibraryStatus.ready;
      await tester.pumpWidget(_AppHarness(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);

      controller.setQuery('zzz');
      await tester.pumpAndSettle();
      expect(find.textContaining('No game matches'), findsOneWidget);

      controller.setQuery('');
      controller.setThemeMode(AppThemeMode.light);
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      final theme = Theme.of(tester.element(find.byType(LibraryPage)));
      expect(theme.brightness, Brightness.light);
      expect(theme.extension<AppPalette>(), AppPalette.light);
      // The sidebar paints its own colour: no hidden ink, no overflowed Row.
      expect(tester.takeException(), isNull);
    });

    testWidgets('the accent choice reaches the theme through the shell', (
      tester,
    ) async {
      await tester.pumpWidget(_Harness(controller: controller));
      await tester.pumpAndSettle();

      ThemeData shown() =>
          Theme.of(tester.element(find.byKey(const ValueKey('probe'))));
      expect(shown().colorScheme.primary, AppAccent.brand.color);

      controller.setAccentColor(AppAccent.teal);
      await tester.pumpAndSettle();

      expect(shown().colorScheme.primary, AppAccent.teal.color);
      final palette = shown().extension<AppPalette>()!;
      expect(palette.accent, AppAccent.teal.color);
      expect(
        palette.accentSoft,
        AppPalette.forMode(Brightness.dark, AppAccent.teal.color).accentSoft,
      );
    });

    testWidgets('the status bar survives a long notice in a narrow window', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller.games = [game('flatpak:alpha', 'Alpha', SourceKind.flatpak)];
      controller.status = LibraryStatus.ready;
      controller.failure = 'Alpha: SteamGridDB returned HTTP 400.';

      await tester.pumpWidget(_AppHarness(controller: controller));
      await tester.pumpAndSettle();

      // The detail panel takes another 360px off the column.
      await tester.tap(find.byType(GameTile));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byType(DetailPanel), findsOneWidget);
      expect(find.textContaining('HTTP 400'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the status bar keeps the notice on the right', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller.games = [game('flatpak:alpha', 'Alpha', SourceKind.flatpak)];
      controller.status = LibraryStatus.ready;
      controller.notice = 'Launched Alpha';

      await tester.pumpWidget(_AppHarness(controller: controller));
      await tester.pumpAndSettle();

      final counts = tester.getRect(find.textContaining('shown ·'));
      final notice = tester.getRect(find.textContaining('Launched Alpha'));

      expect(notice.left, greaterThan(counts.right));
      expect(notice.right, greaterThan(1500));
      expect(tester.takeException(), isNull);

      // addTearDown runs after the pending-timer check, so the notice's
      // auto-expire timer is put out here instead.
      controller.notice = null;
    });

    testWidgets(
      'the accent swatches switch the accent and mark the active one',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: SettingsView(controller: controller),
          ),
        );

        BoxDecoration swatch(String label) =>
            tester
                    .widget<Container>(
                      find.descendant(
                        of: find.byTooltip(label),
                        matching: find.byType(Container),
                      ),
                    )
                    .decoration!
                as BoxDecoration;

        Finder tick(String label) => find.descendant(
          of: find.byTooltip(label),
          matching: find.byIcon(Icons.check),
        );

        // One circle per choice, in the accent's own colour.
        for (final accent in AppAccent.values) {
          expect(
            swatch(accent.label).color,
            accent.color,
            reason: accent.label,
          );
        }
        expect(find.text('Accent: Default'), findsOneWidget);
        expect(tick('Default'), findsOneWidget);
        expect(tick('Blue'), findsNothing);
        // The active one is ringed, the others keep a hairline outline.
        expect((swatch('Default').border! as Border).top.width, 3);
        expect((swatch('Blue').border! as Border).top.width, 1);

        await tester.tap(find.byTooltip('Blue'));
        await tester.pumpAndSettle();

        expect(controller.config.accent, AppAccent.blue);
        expect(find.text('Accent: Blue'), findsOneWidget);
        expect(tick('Blue'), findsOneWidget);
        expect(tick('Default'), findsNothing);
        expect((swatch('Blue').border! as Border).top.width, 3);
        expect(AppConfig.load(configPath).accentColor, 'blue');
      },
    );

    testWidgets('the swatch ring and tick read in both themes', (tester) async {
      for (final theme in [AppTheme.dark, AppTheme.light]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: SettingsView(controller: controller),
          ),
        );
        // `AnimatedTheme` lerps between the two palettes; wait for it to land.
        await tester.pumpAndSettle();
        final palette = theme.extension<AppPalette>()!;
        final box =
            tester
                    .widget<Container>(
                      find.descendant(
                        of: find.byTooltip('Default'),
                        matching: find.byType(Container),
                      ),
                    )
                    .decoration!
                as BoxDecoration;
        expect((box.border! as Border).top.color, palette.text);
        final check = tester.widget<Icon>(
          find.descendant(
            of: find.byTooltip('Default'),
            matching: find.byIcon(Icons.check),
          ),
        );
        expect(check.color, palette.onAccent);
      }
    });

    testWidgets('settings shows the mode and switches it', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: materialThemeMode(controller.config.themeMode),
          home: SettingsView(controller: controller),
        ),
      );

      final segmented = find.byType(SegmentedButton<AppThemeMode>);
      expect(tester.widget<SegmentedButton<AppThemeMode>>(segmented).selected, {
        AppThemeMode.dark,
      });
      expect(find.text('Appearance: Dark'), findsOneWidget);

      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();

      expect(controller.config.themeMode, AppThemeMode.light);
      expect(tester.widget<SegmentedButton<AppThemeMode>>(segmented).selected, {
        AppThemeMode.light,
      });
      expect(find.text('Appearance: Light'), findsOneWidget);
      expect(AppConfig.load(configPath).themeMode, AppThemeMode.light);
    });

    testWidgets('the settings switches follow the controller', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: SettingsView(controller: controller),
        ),
      );

      final tile = find.widgetWithText(SwitchListTile, 'Show hidden games');
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);

      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      expect(controller.config.showHidden, isTrue);
      expect(AppConfig.load(configPath).showHidden, isTrue);
    });

    testWidgets('removing an AppImage folder drops the row', (tester) async {
      controller.setAppimageDirs(['~/Games', '/opt']);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: SettingsView(controller: controller),
        ),
      );

      await tester.scrollUntilVisible(
        find.text('/opt'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.widgetWithText(ListTile, '/opt'));
      await tester.pumpAndSettle();
      expect(find.text('/opt'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, '/opt'),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('/opt'), findsNothing);
      expect(controller.config.appimageDirs, ['~/Games']);
    });
  });
}
