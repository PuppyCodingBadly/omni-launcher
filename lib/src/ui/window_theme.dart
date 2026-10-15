import 'package:flutter/services.dart';

/// The window's title bar and the colour behind the very first frame are drawn
/// by GTK, not by Flutter, so the chosen palette has to be pushed to the runner.
class WindowTheme {
  static const MethodChannel _channel = MethodChannel('omni_launcher/theme');

  /// Last value sent, so rebuilds do not spam the platform channel.
  static bool? _lastDark;

  /// Ask the runner to paint the header bar and window background for
  /// [brightness].
  static Future<void> apply(Brightness brightness) async {
    final dark = brightness == Brightness.dark;
    if (_lastDark == dark) return;
    _lastDark = dark;
    try {
      await _channel.invokeMethod<void>('setDark', dark);
    } on MissingPluginException {
      // No runner behind us (widget tests, other platforms).
    } on PlatformException {
      // The bar keeps whatever the runner defaulted to; never fatal.
    }
  }

  /// Forget the cached value (used by tests).
  static void resetForTest() => _lastDark = null;
}
