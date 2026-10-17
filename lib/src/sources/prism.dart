import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../model/game.dart';
import '../paths.dart';
import '../util/proc.dart';
import 'source.dart';

// Minecraft instances managed by Prism Launcher, one per `instances/*/`.

/// Flatpak ref of Prism Launcher.
const String prismFlatpakId = 'org.prismlauncher.PrismLauncher';

String _home() => AppPaths.home;

/// The `instances` directories of a native and a flatpak install.
List<String> _defaultRoots() => [
  '${_home()}/.local/share/PrismLauncher/instances',
  '${_home()}/.var/app/$prismFlatpakId/data/PrismLauncher/instances',
];

/// The `name=` out of an `instance.cfg`, or null when there is none.
///
/// The file is INI-ish: MultiMC wrote `name` at the top level, Prism puts it
/// under `[General]`. Either answers, so the section is ignored and the first
/// `name=` line wins; a blank name counts as absent.
String? instanceName(String text) {
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
    if (line.startsWith('[')) continue;
    final index = line.indexOf('=');
    if (index < 0) continue;
    if (line.substring(0, index).trim() != 'name') continue;
    final value = line.substring(index + 1).trim();
    return value.isEmpty ? null : value;
  }
  return null;
}

/// One game per Prism Launcher instance, launched with `-l <instance>`.
class PrismSource extends GameSource {
  PrismSource({List<String>? roots, this.command})
    : roots = roots ?? _defaultRoots();

  /// The `instances` directories to scan; the real ones unless a caller (a
  /// test, or an unusual install) points somewhere else.
  final List<String> roots;

  /// The argv prefix to launch with; detected from the install when null.
  final List<String>? command;

  @override
  SourceKind get kind => SourceKind.prism;

  @override
  Future<List<Game>> discover(AppConfig cfg) async {
    final argv =
        command ??
        (which('prismlauncher') != null
            ? <String>['prismlauncher']
            : <String>['flatpak', 'run', prismFlatpakId]);
    final seen = <String>{};
    final games = <Game>[];
    for (final root in roots) {
      final List<FileSystemEntity> entries;
      try {
        entries = await Directory(root).list().toList();
      } on FileSystemException {
        continue;
      }
      final dirs = entries.whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final dir in dirs) {
        // The instance id is the directory name; that is what `-l` takes.
        final instance = dir.path.substring(dir.path.lastIndexOf('/') + 1);
        final String text;
        try {
          text = utf8.decode(
            await File('${dir.path}/instance.cfg').readAsBytes(),
            allowMalformed: true,
          );
        } on FileSystemException {
          continue;
        }
        final name = instanceName(text);
        if (name == null || !seen.add(instance)) continue;
        games.add(
          Game(
            id: '${SourceKind.prism.id}:$instance',
            key: instance,
            name: name,
            source: SourceKind.prism,
            command: [...argv, '-l', instance],
            subtitle: 'Prism Launcher',
            extra: {'instance': instance},
          ),
        );
      }
    }
    return games;
  }
}
