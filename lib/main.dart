import 'package:flutter/material.dart';

import 'src/paths.dart';
import 'src/state/library_controller.dart';
import 'src/ui/accent_colors.dart';
import 'src/ui/library_page.dart';
import 'src/ui/theme.dart';
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

class _OmniLauncherAppState extends State<OmniLauncherApp> with WidgetsBindingObserver {
  late final LibraryController _controller = LibraryController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_syncWindowTheme);
    _controller.load();
    // The shipped plugins are installed (or refreshed) before the folder is
    // read, so a new build's plugin arrives without anyone copying files.
    _controller.reloadPlugins();
    _syncWindowTheme();
  }

  @override
  void didChangePlatformBrightness() => _syncWindowTheme();

  @override
  void dispose() {
    _controller.removeListener(_syncWindowTheme);
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  /// Keep GTK's header bar and the window background in step with the palette.
  void _syncWindowTheme() {
    final mode = materialThemeMode(_controller.config.themeMode);
    final platformDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    final dark = switch (mode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformDark,
    };
    WindowTheme.apply(dark ? Brightness.dark : Brightness.light);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final accent = _controller.config.accent.color;
        return MaterialApp(
          title: 'Omni Launcher',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeFor(Brightness.light, accent),
          darkTheme: AppTheme.themeFor(Brightness.dark, accent),
          themeMode: materialThemeMode(_controller.config.themeMode),
          home: LibraryPage(controller: _controller),
        );
      },
    );
  }
}
