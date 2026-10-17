import '../config.dart';
import '../model/game.dart';
import 'source.dart';

/// Games the user added by hand (config.json `manual` list).
///
/// The game id is `manual:<key>`: the key, not the name, is the identity, so
/// renaming an entry keeps its hidden state, art and playtime.
class ManualSource extends GameSource {
  @override
  SourceKind get kind => SourceKind.manual;

  @override
  Future<List<Game>> discover(AppConfig cfg) async => [
    for (final entry in cfg.manual)
      if (entry.command.isNotEmpty)
        Game(
          id: 'manual:${entry.key}',
          key: entry.key,
          name: entry.name,
          source: SourceKind.manual,
          command: List<String>.from(entry.command),
          cwd: entry.cwd,
          icon: entry.icon,
          path: entry.cwd,
        ),
  ];
}
