import 'dart:ui' show Color;

import '../config.dart';

/// The `Color` view of the persisted accent choice.
///
/// The enum lives in `config.dart` (which stays free of Flutter imports so the
/// discovery sources can be exercised headlessly), so the conversion lives here.
extension AppAccentColor on AppAccent {
  Color get color => Color(argb);
}
