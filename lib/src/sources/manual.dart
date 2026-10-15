import '../config.dart';
import '../model/game.dart';
import 'source.dart';

/// Games the user added by hand (config.json `manual` list).
class ManualSource extends GameSource {
  @override
  SourceKind get kind => SourceKind.manual;

  @override
  Future<List<Game>> discover(AppConfig cfg) async => [
    for (final entry in cfg.manual)
      if (entry.command.isNotEmpty)
        Game(
          id: 'manual:${entry.name}',
          key: entry.name,
          name: entry.name,
          source: SourceKind.manual,
          command: List<String>.from(entry.command),
          cwd: entry.cwd,
          icon: entry.icon,
          path: entry.cwd,
        ),
  ];
}
