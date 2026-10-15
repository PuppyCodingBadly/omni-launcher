import '../config.dart';
import '../model/game.dart';
import 'appimage.dart';
import 'desktop.dart';
import 'epic.dart';
import 'faugus.dart';
import 'flatpak.dart';
import 'heroic.dart';
import 'lutris.dart';
import 'manual.dart';
import 'source.dart';
import 'steam.dart';
import 'steam_shortcuts.dart';

/// Every source, in UI order.
List<GameSource> buildSources() => [
  ManualSource(),
  SteamSource(),
  FlatpakSource(),
  AppImageSource(),
  HeroicSource(),
  EpicSource(),
  LutrisSource(),
  FaugusSource(),
  DesktopSource(),
];

/// Identity of the underlying game, when a source can name it.
///
/// A `.desktop` shortcut for a Steam game and the Steam manifest describe the
/// same game; the same goes for a desktop entry that wraps an AppImage.
String? dedupeKey(Game game) {
  final explicit = game.extra['dedupe'];
  if (explicit is String && explicit.isNotEmpty) return explicit;
  if (game.source == SourceKind.steam) return 'steam:${game.key}';
  if (game.source == SourceKind.appimage) return 'path:${game.key}';
  return null;
}

List<Game> sortGames(Iterable<Game> games) {
  final sorted = games.toList();
  sorted.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    return a.source.index.compareTo(b.source.index);
  });
  return sorted;
}

/// Give every game the name the user picked for it, when there is one.
///
/// [games] must already be de-duplicated and sorted: renaming afterwards means
/// an override can neither merge two games nor decide which of them wins, and
/// the library keeps the order it had before the rename. The game keeps its
/// `id`, `key`, `command` and `extra`, so everything keyed by identity - hidden
/// games, pinned artwork, the playtime log - follows the game across a rename.
List<Game> applyNameOverrides(List<Game> games, Map<String, String> overrides) {
  if (overrides.isEmpty) return games;
  final renamed = <Game>[];
  for (final game in games) {
    final name = overrides[game.id];
    renamed.add(
      name == null || name.trim().isEmpty ? game : game.copyWith(name: name),
    );
  }
  return renamed;
}

/// Prefer Steam for games that are also a Steam non-Steam shortcut.
///
/// A shortcut gives the game Steam Input, the overlay and the play-time
/// tracking, which is why RetroDECK is added to Steam in the first place. The
/// flatpak key is the strongest match (`FlatpakAppID` in the shortcut); a name
/// match covers everything else. A visible shortcut always beats a hidden one.
Future<List<Game>> preferSteamShortcuts(
  List<Game> games,
  List<SteamShortcut> shortcuts,
) async {
  if (shortcuts.isEmpty) return games;
  final byFlatpak = <String, SteamShortcut>{};
  final byName = <String, SteamShortcut>{};
  for (final shortcut in shortcuts) {
    final flatpakId = shortcut.flatpakAppId;
    if (flatpakId != null && flatpakId.isNotEmpty) {
      final current = byFlatpak[flatpakId];
      if (current == null || (current.hidden && !shortcut.hidden)) {
        byFlatpak[flatpakId] = shortcut;
      }
    }
    final key = shortcut.name.trim().toLowerCase();
    if (key.isEmpty) continue;
    final current = byName[key];
    if (current == null || (current.hidden && !shortcut.hidden)) {
      byName[key] = shortcut;
    }
  }

  final result = <Game>[];
  for (final game in games) {
    final shortcut = game.source == SourceKind.flatpak
        ? byFlatpak[game.key] ?? byName[game.name.trim().toLowerCase()]
        : byName[game.name.trim().toLowerCase()];
    if (shortcut == null) {
      result.add(game);
      continue;
    }
    result.add(
      Game(
        id: game.id,
        key: game.key,
        name: game.name,
        source: game.source,
        command: await steamLaunchCommand('${shortcut.appId}'),
        cwd: game.cwd,
        icon: game.icon,
        iconIsName: game.iconIsName,
        cover: game.cover,
        path: game.path,
        subtitle: game.subtitle,
        extra: {
          ...game.extra,
          'steamShortcut': shortcut.appId,
          'launchedViaSteam': true,
        },
      ),
    );
  }
  return result;
}

/// Scan every (or the given) source; de-duplicate by game id and identity.
///
/// [sources] replaces [buildSources], which lets a caller scan a fixed set of
/// sources instead of the ones installed on this machine. [shortcuts] replaces
/// the Steam shortcuts read from disk.
Future<List<Game>> discoverAll(
  AppConfig cfg, {
  Set<SourceKind>? only,
  List<GameSource>? sources,
  List<SteamShortcut>? shortcuts,
  void Function(SourceKind kind, Object error)? onError,
}) async {
  final found = <String, Game>{};
  final identities = <String, String>{};
  for (final source in sources ?? buildSources()) {
    if (only != null && !only.contains(source.kind)) continue;
    List<Game> games;
    try {
      games = await source.discover(cfg);
    } catch (error) {
      onError?.call(source.kind, error);
      continue;
    }
    for (final game in games) {
      if (found.containsKey(game.id)) continue;
      final identity = dedupeKey(game);
      if (identity != null && identities.containsKey(identity)) continue;
      if (identity != null) identities[identity] = game.id;
      found[game.id] = game;
    }
  }
  final sorted = applyNameOverrides(sortGames(found.values), cfg.nameOverrides);
  return preferSteamShortcuts(sorted, shortcuts ?? readSteamShortcuts());
}
