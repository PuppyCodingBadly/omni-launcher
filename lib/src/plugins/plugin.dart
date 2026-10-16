/// A plugin is a process, not code loaded into the launcher: the launcher
/// writes a request as JSON on its stdin and reads the answer as JSON from its
/// stdout (see `plugin_runner.dart`). That leaves the language to whoever
/// writes the plugin, and keeps the plugin out of the launcher's own process.
library;

/// One plugin: a folder with a `plugin.json` in it and the program it names.
class Plugin {
  const Plugin({
    required this.id,
    required this.name,
    required this.description,
    required this.action,
    required this.command,
    required this.dir,
    this.version = 0,
  });

  /// The folder's name, and the plugin's identity in the answer cache.
  final String id;

  final String name;

  /// One line for the settings page; may be empty.
  final String description;

  /// What the detail panel's cog calls this plugin's lookup.
  final String action;

  /// The program to run, with its arguments. A relative path is relative to
  /// [dir], which is also the folder the program runs in.
  final List<String> command;

  /// Where the plugin lives.
  final String dir;

  /// The manifest's version, or 0 when it does not carry one. It is what the
  /// store compares against the catalogue.
  final int version;

  /// The plugin [manifest] describes, or `null` when it does not describe one:
  /// a folder whose manifest makes no sense is left alone rather than half
  /// used.
  static Plugin? fromManifest(String dir, Object? manifest) {
    if (manifest is! Map) return null;
    final json = manifest.cast<String, Object?>();
    final id = _text(json['id']);
    final name = _text(json['name']);
    if (id == null || !_idPattern.hasMatch(id)) return null;
    if (name == null) return null;
    final raw = json['command'];
    if (raw is! List || raw.isEmpty) return null;
    final command = <String>[];
    for (final part in raw) {
      final arg = _text(part);
      if (arg == null) return null;
      command.add(arg);
    }
    return Plugin(
      id: id,
      name: name,
      description: _text(json['description']) ?? '',
      action: _text(json['action']) ?? 'Look up with $name',
      command: command,
      dir: dir,
      version: versionOf(json),
    );
  }

  /// The manifest's version, which is what decides whether the copy shipped
  /// with the launcher replaces the one on disk. A manifest without one counts
  /// as 0, so any versioned plugin beats it.
  static int versionOf(Object? manifest) {
    if (manifest is! Map) return 0;
    final version = manifest['version'];
    return version is int && version > 0 ? version : 0;
  }

  static final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]*$');

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// One line of a plugin's answer.
class PluginField {
  const PluginField({required this.label, required this.value});

  final String label;
  final String value;

  static PluginField? fromJson(Object? json) {
    if (json is! Map) return null;
    final label = json['label'];
    final value = json['value'];
    if (label is! String || value is! String) return null;
    if (label.trim().isEmpty || value.trim().isEmpty) return null;
    return PluginField(label: label.trim(), value: value.trim());
  }

  Map<String, Object?> toJson() => {'label': label, 'value': value};
}

/// What a plugin said about a game.
///
/// A failure is an answer too, and is remembered like one: the panel can then
/// say what happened instead of showing nothing at all.
class PluginAnswer {
  const PluginAnswer({this.fields = const [], this.url, this.error});

  /// The label/value pairs the panel shows, in the plugin's own order.
  final List<PluginField> fields;

  /// The page the answer came from, when the plugin names one.
  final String? url;

  /// Why the lookup did not work, when it did not.
  final String? error;

  bool get ok => error == null;

  static PluginAnswer failure(String message) => PluginAnswer(error: message);

  /// The answer in [json], or `null` when the reply is not an answer at all.
  ///
  /// Strict on purpose: a plugin that half-answers has a bug, and saying the
  /// reply made no sense beats showing part of what it meant.
  static PluginAnswer? fromJson(Object? json) {
    if (json is! Map) return null;
    final error = json['error'];
    if (error is String && error.trim().isNotEmpty) {
      return PluginAnswer(error: error.trim());
    }
    final raw = json['fields'];
    if (raw != null && raw is! List) return null;
    final fields = <PluginField>[];
    for (final entry in raw as List? ?? const <Object?>[]) {
      final field = PluginField.fromJson(entry);
      if (field == null) return null;
      fields.add(field);
    }
    final url = json['url'];
    if (url != null && url is! String) return null;
    return PluginAnswer(
      fields: fields,
      url: url is String && url.trim().isNotEmpty ? url.trim() : null,
    );
  }

  Map<String, Object?> toJson() => {
    if (fields.isNotEmpty) 'fields': [for (final field in fields) field.toJson()],
    if (url != null) 'url': url,
    if (error != null) 'error': error,
  };
}
