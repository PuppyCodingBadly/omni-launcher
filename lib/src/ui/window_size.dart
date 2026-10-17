import 'package:flutter/services.dart';

/// The runner owns the window's size: GTK created the window, so resizing it
/// goes through this channel, the same way the palette reaches the header bar
/// through `WindowTheme`.
class WindowSize {
  static const MethodChannel _channel = MethodChannel('omni_launcher/window');

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
}
