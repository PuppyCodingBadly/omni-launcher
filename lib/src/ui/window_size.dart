import 'package:flutter/services.dart';

/// The runner owns the window's size: GTK created the window, so resizing it
/// goes through this channel, the same way the palette reaches the header bar
/// through `WindowTheme`.
class WindowSize {
  static const MethodChannel _channel = MethodChannel('omni_launcher/window');
  static const MethodChannel _events = MethodChannel(
    'omni_launcher/window_events',
  );

  /// Ask GTK to size the window [width] × [height] logical pixels.
  static Future<void> apply(double width, double height) async {
    try {
      await _channel.invokeMethod<void>('setSize', {
        'width': width,
        'height': height,
      });
    } on MissingPluginException {
      // No runner behind us (widget tests, other platforms).
    } on PlatformException {
      // A window manager that refuses keeps its size; never fatal.
    }
  }

  /// Step out of the way while a game runs.
  static Future<void> minimize() => _call('minimize');

  /// Bring the window back, e.g. from the tray.
  static Future<void> show() => _call('show');

  /// Ask the runner for a tray icon, or take it away.
  static Future<void> setTrayIcon(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setTrayIcon', enabled);
    } on MissingPluginException {
      // The runner has no tray (widget tests, other platforms).
    } on PlatformException {
      // A desktop without a tray host simply shows nothing.
    }
  }

  static Future<void> _call(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // No runner behind us.
    } on PlatformException {
      // A window manager may refuse; never fatal.
    }
  }

  /// Call [onFocus] whenever the window comes back to the front.
  static void listenForFocus(void Function() onFocus) {
    _events.setMethodCallHandler((call) async {
      if (call.method == 'focus') onFocus();
      return null;
    });
  }
}
