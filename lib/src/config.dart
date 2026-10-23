import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'model/game.dart';
import 'model/launch_options.dart';
import 'util/shell.dart';

/// Which palette the window uses.
enum AppThemeMode {
  system('system', 'Follow the system'),
  dark('dark', 'Dark'),
  light('light', 'Light');

  const AppThemeMode(this.id, this.label);

  final String id;
  final String label;

  static AppThemeMode byId(String? id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return AppThemeMode.dark;
  }
}

/// Accent choices: the GNOME/Adwaita basic colours, plus the launcher's own.
///
/// Kept as an ARGB int so this file stays free of Flutter imports; the UI turns
/// it into a `Color` (see `ui/accent_colors.dart`).
enum AppAccent {
  brand('default', 'Default', 0xFF8A6BFF),
  blue('blue', 'Blue', 0xFF3584E4),
  teal('teal', 'Teal', 0xFF2190A4),
  green('green', 'Green', 0xFF3A944A),
  yellow('yellow', 'Yellow', 0xFFE5A50A),
  orange('orange', 'Orange', 0xFFED5B00),
  red('red', 'Red', 0xFFE01B24),
  pink('pink', 'Pink', 0xFFD56199),
  purple('purple', 'Purple', 0xFF9141AC),
  slate('slate', 'Slate', 0xFF6F8396);

  const AppAccent(this.id, this.label, this.argb);

  final String id;
  final String label;
  final int argb;

  static AppAccent byId(String? id) {
    for (final accent in values) {
      if (accent.id == id) return accent;
    }
    return brand;
  }
}

/// User configuration (`~/.config/omnilauncher-flutter/config.json`).
class AppConfig {
  AppConfig({
    Set<String>? hidden,
    List<String>? appimageDirs,
    List<ManualEntry>? manual,
    Map<String, String>? artOverrides,
    Map<String, String>? autoArt,
    Map<String, int>? sgdbMisses,
    Map<String, String>? nameOverrides,
    this.steamgriddbKey = '',
    this.steamgriddbAuto = false,
    this.themeMode = AppThemeMode.dark,
    this.accentColor = 'default',
    Set<String>? closeWithGame,
    Map<String, List<String>>? tags,
    Map<String, LaunchOptions>? launchOptions,
    Set<String>? forgotten,
    Map<String, Set<String>>? pluginGrants,
    this.minimizeOnLaunch = false,
    this.trayIcon = false,
    this.coverFetch = true,
    this.showHidden = false,
    this.sidebarCollapsed = false,
    List<String>? favorites,
    this.sortMode = 'name',
    this.windowWidth,
    this.windowHeight,
  }) : hidden = hidden ?? <String>{},
       appimageDirs = appimageDirs ?? List<String>.from(defaultAppimageDirs),
       manual = manual ?? <ManualEntry>[],
       artOverrides = artOverrides ?? <String, String>{},
       autoArt = autoArt ?? <String, String>{},
       sgdbMisses = sgdbMisses ?? <String, int>{},
       nameOverrides = nameOverrides ?? <String, String>{},
       closeWithGame = closeWithGame ?? <String>{},
       tags = tags ?? <String, List<String>>{},
       launchOptions = launchOptions ?? <String, LaunchOptions>{},
       forgotten = forgotten ?? <String>{},
       pluginGrants = pluginGrants ?? <String, Set<String>>{},
       favorites = favorites ?? <String>[];

  static const List<String> defaultAppimageDirs = [
    '~/AppImages',
    '~/Applications',
    '~/AppImage',
    '~/Games',
    '~/Downloads',
    '~/.local/bin',
    '/opt',
  ];

  final Set<String> hidden;
  final List<String> appimageDirs;
  final List<ManualEntry> manual;

  /// Chosen artwork per game id (game id -> cached file path).
  final Map<String, String> artOverrides;

  /// Artwork the launcher fetched per game (game id -> cached file path).
  final Map<String, String> autoArt;

  /// Automatic SteamGridDB lookups that found nothing (game id -> when the
  /// lookup ran, in milliseconds since the epoch), so an artless game is not
  /// re-queried on every run. Entries older than the controller's TTL count
  /// as absent.
  final Map<String, int> sgdbMisses;

  /// Names the user picked, per game id (game id -> the name to show).
  ///
  /// The game keeps its id, key and launch command; only the label changes.
  final Map<String, String> nameOverrides;

  /// SteamGridDB API key; empty disables the integration.
  final String steamgriddbKey;

  /// Fetch SteamGridDB art automatically for games with no local cover.
  final bool steamgriddbAuto;

  /// Palette selection: system, dark or light.
  final AppThemeMode themeMode;

  /// Accent colour id ([AppAccent.id]); `default` keeps the shipped violet.
  final String accentColor;

  /// [SourceKind.id]s of the game launcher clients (see
  /// [SourceKind.launchers]) to close once their game exits.
  ///
  /// The launcher is the client that started the game (Steam, Heroic,
  /// Lutris…), not the game, so the choice is made once per launcher rather
  /// than once per game. Config files written before schema version 2 hold
  /// game ids and are migrated on load.
  final Set<String> closeWithGame;

  /// Tags the user gave a game, per game id. Tags a source already knows
  /// (Steam collections, Lutris categories) travel with the game itself and
  /// are merged with these.
  final Map<String, List<String>> tags;

  /// What the launcher adds to a game's own argv, per game id.
  final Map<String, LaunchOptions> launchOptions;

  /// Game ids the user removed from the library after they went missing.
  ///
  /// A game that disappears from its source but has playtime is kept, so the
  /// hours are not lost; forgetting it here is how that entry is removed for
  /// good.
  final Set<String> forgotten;

  /// Capabilities the user allowed a plugin, per plugin id.
  ///
  /// A plugin that is not listed here keeps the capability it has always had:
  /// lookup. Actions and launch hooks are opt-in.
  final Map<String, Set<String>> pluginGrants;

  /// Minimize the launcher window when a game starts.
  final bool minimizeOnLaunch;

  /// Keep a tray icon that brings the window back.
  final bool trayIcon;

  final bool coverFetch;
  final bool showHidden;

  /// Whether the source sidebar is collapsed to its icon rail.
  final bool sidebarCollapsed;

  /// Game ids the user pinned as favourites.
  final List<String> favorites;

  /// Library ordering: one of [sortModes]; unknown values load as `name`.
  final String sortMode;

  /// Last window size, if the platform reported one; absent by default.
  final double? windowWidth;
  final double? windowHeight;

  /// The values [sortMode] may take.
  static const Set<String> sortModes = {'name', 'lastPlayed', 'mostPlayed'};

  /// Schema version of the written file. A missing `version` is version 1;
  /// bump only together with a migration in [load].
  static const int schemaVersion = 2;

  static AppConfig load(String path) {
    final file = File(path);
    Map<String, Object?> data = const {};
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) data = decoded.cast<String, Object?>();
      } on FormatException {
        data = const {};
      } on FileSystemException {
        data = const {};
      }
      _restrictPermissions(path);
    }
    final window = _window(data['window']);
    // Files written before versioning count as version 1, which is also what
    // the migration from per-game to per-launcher close decisions reads.
    final rawVersion = data['version'];
    // A hand-edited file may quote the number; `2` and `"2"` mean the same.
    final version = rawVersion is num
        ? rawVersion.toInt()
        : int.tryParse('$rawVersion') ?? 1;
    return AppConfig(
      hidden: _stringList(data['hidden'])?.toSet() ?? <String>{},
      appimageDirs:
          _stringList(data['appimage_dirs']) ??
          List<String>.from(defaultAppimageDirs),
      manual: _manualList(data['manual']),
      artOverrides: _stringMap(data['art_overrides']),
      autoArt: _autoArt(data['auto_art']),
      sgdbMisses: _sgdbMisses(data['sgdb_misses']),
      nameOverrides: _nameOverrides(data['name_overrides']),
      steamgriddbKey: '${data['steamgriddb_key'] ?? ''}',
      steamgriddbAuto: data['steamgriddb_auto'] == true,
      themeMode: _themeMode(data['theme_mode']),
      accentColor: _accent(data['accent_color']),
      closeWithGame: _closeWithGame(data['close_with_game'], version),
      tags: _tags(data['tags']),
      launchOptions: _launchOptions(data['launch_options']),
      forgotten: _stringList(data['forgotten'])?.toSet() ?? <String>{},
      pluginGrants: _pluginGrants(data['plugin_grants']),
      minimizeOnLaunch: data['minimize_on_launch'] == true,
      trayIcon: data['tray_icon'] == true,
      coverFetch: data['cover_fetch'] != false,
      showHidden: data['show_hidden'] == true,
      sidebarCollapsed: data['sidebar_collapsed'] == true,
      favorites: _stringList(data['favorites']) ?? <String>[],
      sortMode: _sortMode(data['sort']),
      windowWidth: window.$1,
      windowHeight: window.$2,
    );
  }

  /// Best-effort `chmod 600`, POSIX only. The config holds the SteamGridDB
  /// key, so it should be readable by the owner alone; [always] skips the
  /// readability check (a freshly written file inherits the umask). Every
  /// error is swallowed — a filesystem without POSIX modes is not a reason
  /// to fail a load or a save.
  static void _restrictPermissions(String path, {bool always = false}) {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    try {
      if (!always && (File(path).statSync().mode & 0x3F) == 0) return;
      Process.runSync('chmod', ['600', path]);
    } on Object {
      // Best effort only.
    }
  }

  /// `(width, height)` from the `window` map, either side `null` when absent
  /// or not a number.
  static (double?, double?) _window(Object? value) {
    if (value is! Map) return (null, null);
    return (_asDouble(value['width']), _asDouble(value['height']));
  }

  static double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : null;

  /// A [sortModes] value; unknown or wrongly typed values fall back to
  /// ordering by name, the way [_themeMode] falls back to dark.
  static String _sortMode(Object? value) =>
      value is String && sortModes.contains(value) ? value : 'name';

  /// `[str(item) for item in value]`, or `null` when [value] is not a list.
  ///
  /// A config file is hand editable, so a key with the wrong type must not
  /// take the whole load (and with it the app) down.
  static List<String>? _stringList(Object? value) =>
      value is List ? value.map((item) => '$item').toList() : null;

  /// `{game: path}`, accepting the older `{game: {shape: path}}` files too: the
  /// cover wall has one shape now, so only the portrait entry is worth keeping
  /// (square grids were a square-tile experiment that is gone).
  static Map<String, String> _autoArt(Object? value) {
    if (value is! Map) return <String, String>{};
    final result = <String, String>{};
    for (final entry in value.entries) {
      final raw = entry.value;
      final path = raw is String
          ? raw
          : raw is Map
          ? raw['portrait']
          : null;
      if (path is String && path.isNotEmpty) result['${entry.key}'] = path;
    }
    return result;
  }

  static Map<String, String> _stringMap(Object? value) => value is Map
      ? value.map((key, item) => MapEntry('$key', '$item'))
      : <String, String>{};

  /// `{game id: millis}` of SteamGridDB lookups that found nothing, dropping
  /// every entry whose value is not a usable timestamp: a hand-edited file
  /// must not take the load down, and a junk entry is simply forgotten.
  static Map<String, int> _sgdbMisses(Object? value) {
    if (value is! Map) return <String, int>{};
    final result = <String, int>{};
    for (final entry in value.entries) {
      final raw = entry.value;
      final millis = raw is int
          ? raw
          : raw is num
          ? raw.toInt()
          : null;
      if (millis == null || millis < 0) continue;
      result['${entry.key}'] = millis;
    }
    return result;
  }

  /// `{game id: [tag, …]}`, trimmed and de-duplicated case-insensitively.
  static Map<String, List<String>> _tags(Object? value) {
    if (value is! Map) return <String, List<String>>{};
    final tags = <String, List<String>>{};
    for (final entry in value.entries) {
      final id = entry.key;
      if (id is! String || id.isEmpty) continue;
      final raw = entry.value;
      final list = raw is List ? raw : const <Object?>[];
      final seen = <String>{};
      final kept = <String>[];
      for (final item in list) {
        if (item is! String) continue;
        final tag = item.trim();
        if (tag.isEmpty) continue;
        if (!seen.add(tag.toLowerCase())) continue;
        kept.add(tag);
      }
      if (kept.isNotEmpty) tags[id] = kept;
    }
    return tags;
  }

  /// `{game id: LaunchOptions}`, dropping entries that add nothing.
  static Map<String, LaunchOptions> _launchOptions(Object? value) {
    if (value is! Map) return <String, LaunchOptions>{};
    final options = <String, LaunchOptions>{};
    for (final entry in value.entries) {
      final id = entry.key;
      if (id is! String || id.isEmpty) continue;
      final parsed = LaunchOptions.fromJson(entry.value);
      if (parsed.isNotEmpty) options[id] = parsed;
    }
    return options;
  }

  /// `{plugin id: [capability, …]}`, with blanks and duplicates dropped.
  static Map<String, Set<String>> _pluginGrants(Object? value) {
    if (value is! Map) return <String, Set<String>>{};
    final grants = <String, Set<String>>{};
    for (final entry in value.entries) {
      final id = entry.key;
      if (id is! String || id.isEmpty) continue;
      final raw = entry.value;
      // A grant whose value is not a list is malformed: leaving the plugin
      // out of the map keeps the default grants, whereas storing an empty set
      // would silently revoke them.
      if (raw is! List) continue;
      grants[id] = {
        for (final item in raw)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      };
    }
    return grants;
  }

  static List<ManualEntry> _manualList(Object? value) {
    if (value is! List) return <ManualEntry>[];
    final entries = value
        .whereType<Map>()
        .map((entry) => ManualEntry.fromJson(entry.cast<String, Object?>()))
        .toList();
    // The key is the game's identity; duplicates (two entries that share a
    // name, say) would alias one game's state onto the other, so later
    // duplicates get a suffix.
    final seen = <String>{};
    for (var i = 0; i < entries.length; i++) {
      var key = entries[i].key;
      var suffix = 2;
      while (!seen.add(key)) {
        key = '${entries[i].key}-${suffix++}';
      }
      if (key != entries[i].key) entries[i] = entries[i].copyWith(key: key);
    }
    return entries;
  }

  static AppThemeMode _themeMode(Object? value) =>
      value is String ? AppThemeMode.byId(value) : AppThemeMode.dark;

  /// An [AppAccent.id]; unknown or wrongly typed values fall back to the
  /// default accent, the way [_themeMode] falls back to dark.
  static String _accent(Object? value) =>
      value is String ? AppAccent.byId(value).id : AppAccent.brand.id;

  /// `{game id: name}` pairs, dropping every entry that is not a usable name.
  ///
  /// Ids the library does not know yet are kept as they are, so a rename
  /// survives a game being temporarily undiscovered.
  static Map<String, String> _nameOverrides(Object? value) {
    if (value is! Map) return <String, String>{};
    final overrides = <String, String>{};
    for (final entry in value.entries) {
      final id = entry.key;
      final name = entry.value;
      if (id is! String || name is! String || name.trim().isEmpty) continue;
      overrides[id] = name;
    }
    return overrides;
  }

  void save(String path) {
    final payload = <String, Object?>{
      'version': schemaVersion,
      'hidden': hidden.toList()..sort(),
      'appimage_dirs': appimageDirs,
      'manual': manual.map((m) => m.toJson()).toList(),
      'art_overrides': artOverrides,
      'auto_art': autoArt,
      'sgdb_misses': sgdbMisses,
      'name_overrides': nameOverrides,
      'steamgriddb_key': steamgriddbKey,
      'steamgriddb_auto': steamgriddbAuto,
      'theme_mode': themeMode.id,
      'accent_color': accentColor,
      'close_with_game': closeWithGame.toList()..sort(),
      'tags': {for (final id in tags.keys.toList()..sort()) id: tags[id]},
      'launch_options': {
        for (final id in launchOptions.keys.toList()..sort())
          id: launchOptions[id]!.toJson(),
      },
      'forgotten': forgotten.toList()..sort(),
      'plugin_grants': {
        for (final id in pluginGrants.keys.toList()..sort())
          id: pluginGrants[id]!.toList()..sort(),
      },
      'minimize_on_launch': minimizeOnLaunch,
      'tray_icon': trayIcon,
      'cover_fetch': coverFetch,
      'show_hidden': showHidden,
      'sidebar_collapsed': sidebarCollapsed,
      'favorites': favorites,
      'sort': sortMode,
      if (windowWidth != null || windowHeight != null)
        'window': {
          if (windowWidth != null) 'width': windowWidth,
          if (windowHeight != null) 'height': windowHeight,
        },
    };
    final file = File(path);
    file.parent.createSync(recursive: true);
    // Through a sibling file and a rename: a crash halfway through writing
    // must not leave a half written config behind.
    final temporary = File('$path.tmp');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
    );
    // Restrict the temp file before it becomes the config: the file holds the
    // SteamGridDB key, so it must never sit at the target path — however
    // briefly — with group or world read from the umask.
    _restrictPermissions(temporary.path, always: true);
    temporary.renameSync(path);
  }

  /// Configured AppImage directories, with `~` and env vars expanded.
  List<String> appimagePaths(String Function(String) expand) =>
      appimageDirs.map(expand).toList();

  bool isHidden(String gameId) => hidden.contains(gameId);

  /// The accent choice as its enum value.
  AppAccent get accent => AppAccent.byId(accentColor);

  /// Whether the launcher behind [source] should be closed with its game.
  bool closesWithGame(SourceKind source) =>
      source.isLauncher && closeWithGame.contains(source.id);

  /// The closure list, migrated when the file predates the per-launcher form.
  ///
  /// Version 1 held game ids (`steam:440`); the launcher those games share is
  /// the source, so each entry's prefix becomes the one launcher it enables.
  /// Unknown ids, and sources that are not game launchers, are dropped rather
  /// than kept as dead settings.
  static Set<String> _closeWithGame(Object? value, int version) {
    if (value is! List) return <String>{};
    final launchers = <String>{};
    for (final entry in value) {
      if (entry is! String) continue;
      var text = entry.trim();
      if (text.isEmpty) continue;
      if (version < 2) {
        final cut = text.indexOf(':');
        if (cut < 0) continue;
        text = text.substring(0, cut);
      }
      final source = SourceKind.byId(text);
      if (source != null && source.isLauncher) launchers.add(source.id);
    }
    return launchers;
  }

  /// Tags the user gave [gameId], or an empty list.
  List<String> tagsFor(String gameId) => tags[gameId] ?? const [];

  /// What the launcher adds to [gameId]'s argv, or defaults.
  LaunchOptions launchOptionsFor(String gameId) =>
      launchOptions[gameId] ?? const LaunchOptions();

  /// Whether [gameId] was removed after it went missing.
  bool isForgotten(String gameId) => forgotten.contains(gameId);

  /// Capabilities allowed for [pluginId]. A plugin nobody has configured keeps
  /// the lookup it always had; actions and hooks must be granted.
  Set<String> pluginGrantsFor(String pluginId) =>
      pluginGrants[pluginId] ?? const {'lookup'};

  AppConfig copyWith({
    Set<String>? hidden,
    List<String>? appimageDirs,
    List<ManualEntry>? manual,
    Map<String, String>? artOverrides,
    Map<String, String>? autoArt,
    Map<String, int>? sgdbMisses,
    Map<String, String>? nameOverrides,
    String? steamgriddbKey,
    bool? steamgriddbAuto,
    AppThemeMode? themeMode,
    String? accentColor,
    Set<String>? closeWithGame,
    Map<String, List<String>>? tags,
    Map<String, LaunchOptions>? launchOptions,
    Set<String>? forgotten,
    Map<String, Set<String>>? pluginGrants,
    bool? minimizeOnLaunch,
    bool? trayIcon,
    bool? coverFetch,
    bool? showHidden,
    bool? sidebarCollapsed,
    List<String>? favorites,
    String? sortMode,
    double? windowWidth,
    double? windowHeight,
  }) => AppConfig(
    hidden: hidden ?? this.hidden,
    appimageDirs: appimageDirs ?? this.appimageDirs,
    manual: manual ?? this.manual,
    artOverrides: artOverrides ?? this.artOverrides,
    autoArt: autoArt ?? this.autoArt,
    sgdbMisses: sgdbMisses ?? this.sgdbMisses,
    nameOverrides: nameOverrides ?? this.nameOverrides,
    steamgriddbKey: steamgriddbKey ?? this.steamgriddbKey,
    steamgriddbAuto: steamgriddbAuto ?? this.steamgriddbAuto,
    themeMode: themeMode ?? this.themeMode,
    accentColor: accentColor ?? this.accentColor,
    closeWithGame: closeWithGame ?? this.closeWithGame,
    tags: tags ?? this.tags,
    launchOptions: launchOptions ?? this.launchOptions,
    forgotten: forgotten ?? this.forgotten,
    pluginGrants: pluginGrants ?? this.pluginGrants,
    minimizeOnLaunch: minimizeOnLaunch ?? this.minimizeOnLaunch,
    trayIcon: trayIcon ?? this.trayIcon,
    coverFetch: coverFetch ?? this.coverFetch,
    showHidden: showHidden ?? this.showHidden,
    sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
    favorites: favorites ?? this.favorites,
    sortMode: sortMode ?? this.sortMode,
    windowWidth: windowWidth ?? this.windowWidth,
    windowHeight: windowHeight ?? this.windowHeight,
  );
}

class ManualEntry {
  ManualEntry({
    required this.name,
    required this.command,
    String? key,
    this.cwd,
    this.icon,
  }) : key = key ?? generateKey(name);

  final String name;
  final List<String> command;

  /// Stable identity behind the `manual:<key>` game id. The name is display
  /// and may change; the key never does, so a rename keeps hidden state, art
  /// and playtime attached to the game.
  final String key;

  final String? cwd;
  final String? icon;

  Map<String, Object?> toJson() => {
    'name': name,
    'key': key,
    'command': command,
    'cwd': cwd,
    'icon': icon,
  };

  static ManualEntry fromJson(Map<String, Object?> data) {
    final rawCommand = data['command'];
    final List<String> command;
    if (rawCommand is String) {
      // Older hand-edited files wrote the command as one string.
      command = splitShellWords(rawCommand);
    } else if (rawCommand is List) {
      command = rawCommand.map((item) => '$item').toList();
    } else {
      command = <String>[];
    }
    final rawName = data['name'] == null ? '' : '${data['name']}';
    final name = rawName.isEmpty ? 'Untitled' : rawName;
    final rawKey = data['key'];
    final cwd = data['cwd'];
    final icon = data['icon'];
    return ManualEntry(
      name: name,
      // Entries written before keys existed migrate to a key derived from the
      // name; deriving (not generating) keeps the id stable across restarts.
      key: rawKey is String && rawKey.isNotEmpty ? rawKey : deriveKey(name),
      command: command,
      cwd: cwd is String && cwd.isNotEmpty ? cwd : null,
      icon: icon is String && icon.isNotEmpty ? icon : null,
    );
  }

  ManualEntry copyWith({
    String? name,
    List<String>? command,
    String? key,
    String? cwd,
    String? icon,
  }) => ManualEntry(
    name: name ?? this.name,
    command: command ?? this.command,
    key: key ?? this.key,
    cwd: cwd ?? this.cwd,
    icon: icon ?? this.icon,
  );

  static final Random _keyRandom = Random();

  /// Lowercase slug of [name]: words of ASCII alphanumerics joined by `-`.
  static String _slug(String name) {
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    return slug.replaceAll(RegExp(r'^-+|-+$'), '');
  }

  /// A fresh key for a hand-added entry: a readable slug plus random hex, so
  /// the id stays stable across renames and two entries with the same name
  /// still get distinct keys.
  static String generateKey(String name) {
    final base = _slug(name);
    final hex = _keyRandom.nextInt(0x1000000).toRadixString(16).padLeft(6, '0');
    return '${base.isEmpty ? 'game' : base}-$hex';
  }

  /// The key an entry written before keys existed would have had.
  static String deriveKey(String name) {
    final slug = _slug(name);
    return slug.isEmpty ? 'game' : slug;
  }
}
