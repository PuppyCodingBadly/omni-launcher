/// Where a game entry came from. Declaration order is the UI's source order.
enum SourceKind {
  manual('manual', 'Added by hand'),
  steam('steam', 'Steam'),
  flatpak('flatpak', 'Flatpak'),
  appimage('appimage', 'AppImage'),
  heroic('heroic', 'Heroic / Epic'),
  epic('epic', 'Epic Games Launcher'),
  lutris('lutris', 'Lutris'),
  faugus('faugus', 'Faugus'),
  prism('prism', 'Prism Launcher'),
  bottles('bottles', 'Bottles'),
  desktop('desktop', 'Other desktop apps');

  const SourceKind(this.id, this.label);

  /// Stable identifier used in game ids and in `config.json`.
  final String id;

  /// Human readable name shown in the UI.
  final String label;

  /// The sources that are game launcher clients: programs that start games
  /// and may keep a window of their own open afterwards.
  ///
  /// The others are a way of running a game directly — an AppImage, a flatpak
  /// that is the game, a desktop entry, a command written by hand — so
  /// "close the launcher with the game" has nothing to name for them.
  static const Set<SourceKind> launchers = {
    SourceKind.steam,
    SourceKind.heroic,
    SourceKind.epic,
    SourceKind.lutris,
    SourceKind.faugus,
    SourceKind.prism,
    SourceKind.bottles,
  };

  /// Whether this source is a game launcher client (see [launchers]).
  bool get isLauncher => launchers.contains(this);

  static SourceKind? byId(String id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// One launchable entry.
///
/// [command] is the full argv used to start the game; it is what the launcher
/// executes. [icon] is either an absolute path to an image file or an icon
/// theme name, disambiguated by [iconIsName].
class Game {
  const Game({
    required this.id,
    required this.name,
    required this.source,
    required this.command,
    this.key = '',
    this.cwd,
    this.icon,
    this.iconIsName = false,
    this.cover,
    this.path,
    this.subtitle,
    this.extra = const {},
  });

  /// `"<source>:<key>"`, unique across the library.
  final String id;

  /// Stable key inside the source, e.g. the Steam appid or the flatpak ref.
  final String key;

  final String name;
  final SourceKind source;
  final List<String> command;
  final String? cwd;
  final String? icon;
  final bool iconIsName;
  final String? cover;
  final String? path;
  final String? subtitle;
  final Map<String, Object?> extra;

  /// False when the source knows the entry but cannot start it.
  bool get launchable => command.isNotEmpty && !missing && !broken;

  /// The subtitle, defaulting to the source label.
  String get displaySubtitle => subtitle ?? source.label;

  /// Kept from an earlier scan after its source stopped offering it.
  bool get missing => extra['missing'] == true;

  /// Steam's own state, when the source reports it.
  bool get updating => extra['updating'] == true;
  bool get updateRequired => extra['update_required'] == true;
  bool get broken => extra['broken'] == true;

  /// Tags the source itself knows, such as Steam collections or Lutris
  /// categories. The user's own tags live in the config.
  List<String> get sourceTags {
    final raw = extra['tags'];
    if (raw is! List) return const [];
    return [
      for (final tag in raw)
        if (tag is String && tag.trim().isNotEmpty) tag.trim(),
    ];
  }

  /// [id] is unique across the library, so it is all equality needs.
  @override
  bool operator ==(Object other) => other is Game && other.id == id;

  @override
  int get hashCode => id.hashCode;

  /// A copy with the given fields replaced; `id`, `key` and `command` always
  /// carry over. [extra] is merged into the existing map, so a caller can add
  /// `missing` without dropping what the source recorded.
  Game copyWith({
    String? name,
    String? cover,
    String? subtitle,
    Map<String, Object?> extra = const {},
  }) => Game(
    id: id,
    key: key,
    name: name ?? this.name,
    source: source,
    command: command,
    cwd: cwd,
    icon: icon,
    iconIsName: iconIsName,
    cover: cover ?? this.cover,
    path: path,
    subtitle: subtitle ?? this.subtitle,
    extra: {...this.extra, ...extra},
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'key': key,
    'name': name,
    'source': source.id,
    'command': command,
    'cwd': cwd,
    'icon': icon,
    'icon_is_name': iconIsName,
    'cover': cover,
    'path': path,
    'subtitle': subtitle,
    'extra': extra,
  };

  static Game? fromJson(Map<String, Object?> data) {
    final id = data['id'];
    final name = data['name'];
    final source = SourceKind.byId('${data['source']}');
    if (id is! String || name is! String || source == null) return null;
    final rawCommand = data['command'];
    final List<String> command;
    if (rawCommand is List) {
      command = rawCommand.map((item) => '$item').toList();
    } else if (rawCommand is String) {
      command = [rawCommand];
    } else {
      command = const <String>[];
    }
    final extra = data['extra'];
    final cwd = data['cwd'];
    final icon = data['icon'];
    final cover = data['cover'];
    final path = data['path'];
    final subtitle = data['subtitle'];
    return Game(
      id: id,
      key: '${data['key'] ?? id.split(':').skip(1).join(':')}',
      name: name,
      source: source,
      command: command,
      cwd: cwd is String ? cwd : null,
      icon: icon is String ? icon : null,
      iconIsName: data['icon_is_name'] == true,
      cover: cover is String ? cover : null,
      path: path is String ? path : null,
      subtitle: subtitle is String ? subtitle : null,
      // A decoded JSON map stays mutable; hand out a copy nobody can mutate,
      // so two games decoded from the same record share nothing.
      extra: extra is Map
          ? Map.unmodifiable(extra.cast<String, Object?>())
          : const {},
    );
  }
}
