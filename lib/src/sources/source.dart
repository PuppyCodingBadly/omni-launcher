import '../config.dart';
import '../model/game.dart';

/// Contract for every source module.
///
/// * `discover` must never throw for missing files or apps - return nothing.
/// * It must not launch anything or write files.
/// * `Game.id` must be `"<kind>:<key>"` and unique inside the source.
abstract class GameSource {
  SourceKind get kind;

  Future<List<Game>> discover(AppConfig cfg);
}
