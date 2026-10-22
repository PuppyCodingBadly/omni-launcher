import 'dart:async';

import 'package:flutter/material.dart';

import 'src/config.dart';
import 'src/paths.dart';
import 'src/state/library_controller.dart';
import 'src/ui/accent_colors.dart';
import 'src/ui/library_page.dart';
import 'src/ui/theme.dart';
import 'src/ui/window_size.dart';
import 'src/ui/window_theme.dart';

void main() {
  // A sandboxed launcher used to keep its files inside the sandbox: take over
  // what is there before anything reads the host's own folders.
  AppPaths.adoptSandboxFiles();
  runApp(const OmniLauncherApp());
}

/// One window for every game on this machine, whatever packaging it came in.
class OmniLauncherApp extends StatefulWidget {
  const OmniLauncherApp({super.key});

  @override
  State<OmniLauncherApp> createState() => _OmniLauncherAppState();
}

class _OmniLauncherAppState extends State<OmniLauncherApp>
    with WidgetsBindingObserver {
  late final LibraryController _controller = LibraryController();

  /// The appearance [MaterialApp] was last built with. The controller
  /// notifies on every library change, and the app only needs a rebuild when
  /// one of these two moved — anything else is the page's business.
  late AppThemeMode _themeMode = _controller.config.themeMode;
  late AppAccent _accent = _controller.config.accent;

  /// Debounce for window-size writes: a drag-resize reports a size per frame,
  /// and each of them must not become a config write.
  Timer? _sizeSaveTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);
    _controller.load();
    // The shipped plugins are installed (or refreshed) before the folder is
    // read, so a new build's plugin arrives without anyone copying files.
    _controller.reloadPlugins();
    _syncWindowTheme();
    // The remembered window size goes back once the first frame is up: the
    // window has to exist before GTK can be asked to resize it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restoreWindowSize();
    });
  }

  @override
  void didChangePlatformBrightness() => _syncWindowTheme();

  /// A resize is the moment to remember the window size. `detached` is not
  /// delivered reliably for a plain Linux window close, so the debounced
  /// metrics path is the one that actually persists.
  @override
  void didChangeMetrics() {
    _sizeSaveTimer?.cancel();
    _sizeSaveTimer = Timer(const Duration(milliseconds: 500), _saveWindowSize);
  }

  @override
  void dispose() {
    _sizeSaveTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    _syncWindowTheme();
    final mode = _controller.config.themeMode;
    final accent = _controller.config.accent;
    if (mode == _themeMode && accent == _accent) return;
    setState(() {
      _themeMode = mode;
      _accent = accent;
    });
  }

  /// Keep GTK's header bar and the window background in step with the palette.
  void _syncWindowTheme() {
    final mode = materialThemeMode(_controller.config.themeMode);
    final platformDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    final dark = switch (mode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformDark,
    };
    WindowTheme.apply(dark ? Brightness.dark : Brightness.light);
  }

  void _restoreWindowSize() {
    final width = _controller.config.windowWidth;
    final height = _controller.config.windowHeight;
    if (width == null || height == null) return;
    unawaited(WindowSize.apply(width, height));
  }

  /// Persist the view's logical size, unless nothing moved since the last
  /// write.
  void _saveWindowSize() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    final size = view.physicalSize / view.devicePixelRatio;
    // A minimized or closing window can report nothing; keep the last real
    // size instead of remembering zero.
    if (size.width <= 0 || size.height <= 0) return;
    if (size.width == _controller.config.windowWidth &&
        size.height == _controller.config.windowHeight) {
      return;
    }
    unawaited(_controller.saveWindowSize(size.width, size.height));
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent.color;
    return MaterialApp(
      title: 'Omni Launcher',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.light, accent),
      darkTheme: AppTheme.themeFor(Brightness.dark, accent),
      themeMode: materialThemeMode(_themeMode),
      // The page, not the app, follows the controller: the library changes
      // far more often than the appearance, and the page subscribes itself
      // around the body that reads it.
      home: LibraryPage(controller: _controller),
    );
  }
}
