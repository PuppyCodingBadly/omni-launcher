/// Per-game launch options: what the launcher adds to a game's own argv.
///
/// Kept out of [Game] because a rescan rebuilds games from their source: these
/// are the user's choices, stored in the config by game id, and they survive a
/// game being rediscovered under the same id.
class LaunchOptions {
  const LaunchOptions({
    this.wrapper = const [],
    this.args = const [],
    this.env = const {},
    this.cwd,
  });

  /// argv words put before the game's own command, e.g. `gamemoderun` or
  /// `mangohud`.
  final List<String> wrapper;

  /// argv words appended after the game's own command.
  final List<String> args;

  /// Extra environment variables for the game's process.
  final Map<String, String> env;

  /// A working folder that replaces the one the source reports.
  final String? cwd;

  bool get isEmpty =>
      wrapper.isEmpty && args.isEmpty && env.isEmpty && (cwd ?? '').isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// One line for the detail panel: what is added, in command order.
  String get summary => [
    if (wrapper.isNotEmpty) wrapper.join(' '),
    if (args.isNotEmpty) '… ${args.join(' ')}',
    if (env.isNotEmpty) '${env.length} env',
    if ((cwd ?? '').isNotEmpty) 'in $cwd',
  ].join(' · ');

  Map<String, Object?> toJson() => {
    if (wrapper.isNotEmpty) 'wrapper': wrapper,
    if (args.isNotEmpty) 'args': args,
    if (env.isNotEmpty) 'env': env,
    if ((cwd ?? '').isNotEmpty) 'cwd': cwd,
  };

  /// The options [json] describes; a broken entry becomes defaults rather than
  /// failing the whole config load.
  static LaunchOptions fromJson(Object? json) {
    if (json is! Map) return const LaunchOptions();
    return LaunchOptions(
      wrapper: _stringList(json['wrapper']),
      args: _stringList(json['args']),
      env: _stringMap(json['env']),
      cwd: _text(json['cwd']),
    );
  }

  LaunchOptions copyWith({
    List<String>? wrapper,
    List<String>? args,
    Map<String, String>? env,
    String? cwd,
    bool clearCwd = false,
  }) => LaunchOptions(
    wrapper: wrapper ?? this.wrapper,
    args: args ?? this.args,
    env: env ?? this.env,
    cwd: clearCwd ? null : (cwd ?? this.cwd),
  );

  /// [value]'s strings, in order and exactly as written.
  ///
  /// These become argv words, so trimming or dropping an empty word would
  /// change the command the user configured.
  static List<String> _stringList(Object? value) =>
      value is List ? value.whereType<String>().toList() : const [];

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    final result = <String, String>{};
    for (final entry in value.entries) {
      final rawKey = entry.key;
      final rawValue = entry.value;
      // Only a string is an environment value; a null or number would reach
      // Process.start as `null`/`42` text the user never wrote.
      if (rawKey is! String || rawValue is! String) continue;
      final key = rawKey.trim();
      if (key.isEmpty) continue;
      result[key] = rawValue;
    }
    return result;
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
