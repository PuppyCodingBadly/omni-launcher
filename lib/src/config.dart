import 'dart:convert';
import 'dart:io';

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
    Map<String, Map<String, String>>? autoArt,
    Map<String, String>? nameOverrides,
    this.steamgriddbKey = '',
    this.steamgriddbAuto = false,
    this.themeMode = AppThemeMode.dark,
    this.accentColor = 'default',
    Set<String>? closeWithGame,
    this.coverFetch = true,
    this.showHidden = false,
  }) : hidden = hidden ?? <String>{},
       appimageDirs = appimageDirs ?? List<String>.from(defaultAppimageDirs),
       manual = manual ?? <ManualEntry>[],
       artOverrides = artOverrides ?? <String, String>{},
       autoArt = autoArt ?? <String, Map<String, String>>{},
       nameOverrides = nameOverrides ?? <String, String>{},
       closeWithGame = closeWithGame ?? <String>{};

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

  /// Artwork the launcher fetched per game and poster shape
  /// (game id -> shape name -> cached file path).
  final Map<String, Map<String, String>> autoArt;

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

  /// Game ids whose launcher should be closed once the game exits.
  final Set<String> closeWithGame;
  final bool coverFetch;
  final bool showHidden;

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
    }
    return AppConfig(
      hidden: _stringList(data['hidden'])?.toSet() ?? <String>{},
      appimageDirs:
          _stringList(data['appimage_dirs']) ?? List<String>.from(defaultAppimageDirs),
      manual: _manualList(data['manual']),
      artOverrides: _stringMap(data['art_overrides']),
      autoArt: _autoArt(data['auto_art']),
      nameOverrides: _nameOverrides(data['name_overrides']),
      steamgriddbKey: '${data['steamgriddb_key'] ?? ''}',
      steamgriddbAuto: data['steamgriddb_auto'] == true,
      themeMode: _themeMode(data['theme_mode']),
      accentColor: _accent(data['accent_color']),
      closeWithGame: _closeWithGame(data['close_with_game']),
      coverFetch: data['cover_fetch'] != false,
      showHidden: data['show_hidden'] == true,
    );
  }

  /// `[str(item) for item in value]`, or `null` when [value] is not a list.
  ///
  /// A config file is hand editable, so a key with the wrong type must not
  /// take the whole load (and with it the app) down.
  static List<String>? _stringList(Object? value) =>
      value is List ? value.map((item) => '$item').toList() : null;

  /// `{game: {shape: path}}`, ignoring anything that is not shaped like it.
  static Map<String, Map<String, String>> _autoArt(Object? value) {
    if (value is! Map) return <String, Map<String, String>>{};
    final result = <String, Map<String, String>>{};
    for (final entry in value.entries) {
      final inner = entry.value;
      if (inner is! Map) continue;
      final paths = <String, String>{
        for (final shape in inner.entries)
          if (shape.value is String && (shape.value as String).isNotEmpty)
            '${shape.key}': shape.value as String,
      };
      if (paths.isNotEmpty) result['${entry.key}'] = paths;
    }
    return result;
  }

  static Map<String, String> _stringMap(Object? value) => value is Map
      ? value.map((key, item) => MapEntry('$key', '$item'))
      : <String, String>{};

  static List<ManualEntry> _manualList(Object? value) {
    if (value is! List) return <ManualEntry>[];
    return value
        .whereType<Map>()
        .map((entry) => ManualEntry.fromJson(entry.cast<String, Object?>()))
        .toList();
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
    final payload = {
      'hidden': hidden.toList()..sort(),
      'appimage_dirs': appimageDirs,
      'manual': manual.map((m) => m.toJson()).toList(),
      'art_overrides': artOverrides,
      'auto_art': autoArt,
      'name_overrides': nameOverrides,
      'steamgriddb_key': steamgriddbKey,
      'steamgriddb_auto': steamgriddbAuto,
      'theme_mode': themeMode.id,
      'accent_color': accentColor,
      'close_with_game': closeWithGame.toList()..sort(),
      'cover_fetch': coverFetch,
      'show_hidden': showHidden,
    };
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(payload)}\n');
  }

  /// Configured AppImage directories, with `~` and env vars expanded.
  List<String> appimagePaths(String Function(String) expand) =>
      appimageDirs.map(expand).toList();

  bool isHidden(String gameId) => hidden.contains(gameId);

  /// The accent choice as its enum value.
  AppAccent get accent => AppAccent.byId(accentColor);

  /// Game ids whose launcher should be closed with the game.
  bool closesWithGame(String gameId) => closeWithGame.contains(gameId);

  static Set<String> _closeWithGame(Object? value) {
    if (value is! List) return <String>{};
    return {
      for (final entry in value)
        if (entry is String && entry.trim().isNotEmpty) entry.trim(),
    };
  }

  AppConfig copyWith({
    Set<String>? hidden,
    List<String>? appimageDirs,
    List<ManualEntry>? manual,
    Map<String, String>? artOverrides,
    Map<String, Map<String, String>>? autoArt,
    Map<String, String>? nameOverrides,
    String? steamgriddbKey,
    bool? steamgriddbAuto,
    AppThemeMode? themeMode,
    String? accentColor,
    Set<String>? closeWithGame,
    bool? coverFetch,
    bool? showHidden,
  }) => AppConfig(
    hidden: hidden ?? this.hidden,
    appimageDirs: appimageDirs ?? this.appimageDirs,
    manual: manual ?? this.manual,
    artOverrides: artOverrides ?? this.artOverrides,
    autoArt: autoArt ?? this.autoArt,
    nameOverrides: nameOverrides ?? this.nameOverrides,
    steamgriddbKey: steamgriddbKey ?? this.steamgriddbKey,
    steamgriddbAuto: steamgriddbAuto ?? this.steamgriddbAuto,
    themeMode: themeMode ?? this.themeMode,
    accentColor: accentColor ?? this.accentColor,
    closeWithGame: closeWithGame ?? this.closeWithGame,
    coverFetch: coverFetch ?? this.coverFetch,
    showHidden: showHidden ?? this.showHidden,
  );
}

class ManualEntry {
  ManualEntry({required this.name, required this.command, this.cwd, this.icon});

  final String name;
  final List<String> command;
  final String? cwd;
  final String? icon;

  Map<String, Object?> toJson() => {
    'name': name,
    'command': command,
    'cwd': cwd,
    'icon': icon,
  };

  static ManualEntry fromJson(Map<String, Object?> data) {
    final rawCommand = data['command'];
    final List<String> command;
    if (rawCommand is String) {
      command = [rawCommand];
    } else if (rawCommand is List) {
      command = rawCommand.map((item) => '$item').toList();
    } else {
      command = <String>[];
    }
    final rawName = data['name'] == null ? '' : '${data['name']}';
    final cwd = data['cwd'];
    final icon = data['icon'];
    return ManualEntry(
      name: rawName.isEmpty ? 'Untitled' : rawName,
      command: command,
      cwd: cwd is String && cwd.isNotEmpty ? cwd : null,
      icon: icon is String && icon.isNotEmpty ? icon : null,
    );
  }
}
