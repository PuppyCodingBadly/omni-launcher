import 'package:flutter/material.dart';

import '../config.dart';
import '../paths.dart';
import '../plugins/bundled.dart';
import '../plugins/catalog.dart' as catalogue;
import '../plugins/plugin.dart';
import '../state/library_controller.dart';
import '../util/shell.dart';
import 'accent_colors.dart';
import 'theme.dart';

/// Add a game by hand (name + command + optional folder).
Future<ManualEntry?> showAddGameDialog(BuildContext context) {
  final nameController = TextEditingController();
  final commandController = TextEditingController();
  final cwdController = TextEditingController();
  final formKey = GlobalKey<FormState>();

  return showDialog<ManualEntry>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: context.palette.surface,
      title: const Text('Add a game by hand'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (value) =>
                    (value == null || value.trim().isEmpty) ? 'A name is required' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: commandController,
                decoration: const InputDecoration(
                  labelText: 'Launch command',
                  hintText: 'flatpak run com.example.Game',
                ),
                validator: (value) =>
                    (value == null || value.trim().isEmpty) ? 'A command is required' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: cwdController,
                decoration: const InputDecoration(
                  labelText: 'Working folder (optional)',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!(formKey.currentState?.validate() ?? false)) return;
            final cwd = cwdController.text.trim();
            Navigator.of(context).pop(
              ManualEntry(
                name: nameController.text.trim(),
                command: splitShellWords(commandController.text.trim()),
                cwd: cwd.isEmpty ? null : cwd,
              ),
            );
          },
          child: const Text('Add'),
        ),
      ],
    ),
  );
}

/// Settings: appearance, AppImage folders, cover fetching, hidden games, paths.
class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        backgroundColor: palette.background,
        title: const Text('Settings'),
      ),
      // The switches and lists below read the config, so they have to follow it.
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final config = controller.config;
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
            children: [
              _section(context, 'Appearance'),
              SegmentedButton<AppThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: AppThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto_outlined),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                ],
                selected: {config.themeMode},
                onSelectionChanged: (selection) =>
                    controller.setThemeMode(selection.first),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Appearance: ${config.themeMode.label}',
                  style: TextStyle(fontSize: 12, color: palette.textDim),
                ),
              ),
              const SizedBox(height: 18),
              _AccentRow(selected: config.accent, onChanged: controller.setAccentColor),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Accent: ${config.accent.label}',
                  style: TextStyle(fontSize: 12, color: palette.textDim),
                ),
              ),
              const SizedBox(height: 24),
              _section(context, 'Library'),
              SwitchListTile(
                value: config.showHidden,
                onChanged: (_) => controller.toggleShowHidden(),
                title: const Text('Show hidden games'),
                subtitle: Text('${controller.hiddenCount} hidden'),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                value: config.coverFetch,
                onChanged: controller.setCoverFetch,
                title: const Text('Download Steam cover art'),
                subtitle: const Text(
                  'Portrait capsules are fetched once into the cache folder',
                ),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: controller.rescan,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Rescan library'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final entry = await showAddGameDialog(context);
                      if (entry != null) {
                        await controller.addManual(entry.name, entry.command, cwd: entry.cwd);
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add game by hand'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _section(context, 'Artwork'),
              _SteamGridDbSection(controller: controller),
              const SizedBox(height: 24),
              _section(context, 'AppImage folders'),
              for (final dir in config.appimageDirs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.folder, color: palette.textDim),
                  title: Text(dir),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => controller.setAppimageDirs(
                      [...config.appimageDirs.where((entry) => entry != dir)],
                    ),
                  ),
                ),
              _AddFolderField(
                onAdd: (value) =>
                    controller.setAppimageDirs([...config.appimageDirs, value]),
              ),
              const SizedBox(height: 24),
              _section(context, 'Hand added games'),
              if (config.manual.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Nothing added by hand yet.',
                    style: TextStyle(color: palette.textDim),
                  ),
                ),
              for (final entry in config.manual)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.sports_esports, color: palette.textDim),
                  title: Text(entry.name),
                  subtitle: Text(entry.command.join(' ')),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => controller.removeManual(entry.name),
                  ),
                ),
              const SizedBox(height: 24),
              _section(context, 'Plugins'),
              _PluginStore(controller: controller),
              const SizedBox(height: 24),
              _section(context, 'Files'),
              _pathTile('Config', AppPaths.configFile),
              _pathTile('Cache', AppPaths.cacheFile),
              _pathTile('Launch log', AppPaths.launchLog),
            ],
          );
        },
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 1.2,
        color: context.palette.textDim,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// A read-only path with its label.
Widget _pathTile(String label, String path) => ListTile(
  contentPadding: EdgeInsets.zero,
  title: Text(label),
  subtitle: SelectableText(path, style: const TextStyle(fontSize: 12)),
);

/// The plugin store: what the catalogue offers, what is installed, and the
/// buttons for both.
class _PluginStore extends StatefulWidget {
  const _PluginStore({required this.controller});

  final LibraryController controller;

  @override
  State<_PluginStore> createState() => _PluginStoreState();
}

class _PluginStoreState extends State<_PluginStore> {
  @override
  void initState() {
    super.initState();
    // The store is the point of the section, so the list is read the first time
    // it is shown rather than waiting to be asked. The folder is also read
    // again here, since a plugin may have been dropped in from outside.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = widget.controller;
      if (controller.catalog.isEmpty &&
          !controller.catalogLoading &&
          controller.catalogFailure == null) {
        controller.refreshCatalog();
      }
      controller.reloadPlugins();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final palette = context.palette;
    final installed = {
      for (final plugin in controller.plugins) plugin.id: plugin,
    };
    final listed = {for (final entry in controller.catalog) entry.id};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: controller.catalogLoading
                ? null
                : () => controller.refreshCatalog(),
            icon: controller.catalogLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_outlined, size: 18),
            label: const Text('Refresh the list'),
          ),
        ),
        if (controller.catalogFailure case final failure?)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 16, color: palette.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    failure,
                    style: TextStyle(fontSize: 12.5, color: palette.warning),
                  ),
                ),
              ],
            ),
          ),
        if (controller.catalog.isEmpty && !controller.catalogLoading)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              'Nothing listed yet. Plugins are read from the launcher\'s own '
              'repository; you can also drop a folder with a plugin.json in it '
              'into the folder below.',
              style: TextStyle(fontSize: 12.5, color: palette.textDim),
            ),
          ),
        for (final entry in controller.catalog)
          _CatalogRow(
            controller: controller,
            entry: entry,
            installed: installed[entry.id],
          ),
        for (final plugin in controller.plugins)
          if (!listed.contains(plugin.id))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.extension_outlined, color: palette.textDim),
              title: Text(plugin.name),
              subtitle: Text(
                isBundledPlugin(plugin.id)
                    ? 'Ships with the launcher'
                    : 'Installed here, and not in the list',
                style: TextStyle(fontSize: 12.5, color: palette.textDim),
              ),
              trailing: isBundledPlugin(plugin.id)
                  ? null
                  : _RemoveButton(controller: controller, plugin: plugin),
            ),
        _pathTile('Plugins folder', controller.pluginDir),
      ],
    );
  }
}

/// One plugin the catalogue offers, with the one button it needs.
class _CatalogRow extends StatelessWidget {
  const _CatalogRow({
    required this.controller,
    required this.entry,
    this.installed,
  });

  final LibraryController controller;
  final catalogue.PluginEntry entry;

  /// The same plugin in the plugin folder, when it is there.
  final Plugin? installed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final busy = controller.isPluginBusy(entry.id);
    final current = installed;
    final newer = current != null && entry.version > current.version;
    final subtitle = [
      if (entry.description.isNotEmpty) entry.description,
      [
        if (entry.author.isNotEmpty) 'by ${entry.author}',
        if (entry.version > 0) 'version ${entry.version}',
      ].join(' · '),
      if (isBundledPlugin(entry.id)) 'Ships with the launcher',
    ].where((line) => line.isNotEmpty).join('\n');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.extension, color: palette.textDim),
      title: Text(entry.name),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12.5, color: palette.textDim),
      ),
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (current == null)
                  FilledButton(
                    onPressed: () => _confirmInstall(context),
                    child: const Text('Install'),
                  )
                else ...[
                  if (newer)
                    FilledButton(
                      onPressed: () => controller.installPlugin(entry),
                      child: const Text('Update'),
                    ),
                  // A plugin that ships with the launcher would only come back,
                  // so there is nothing to remove.
                  if (!isBundledPlugin(entry.id))
                    _RemoveButton(controller: controller, plugin: current),
                ],
              ],
            ),
    );
  }

  /// Ask before installing.
  ///
  /// A store plugin is code that runs unsandboxed on the host, so the first
  /// install is never one-click. Updates keep [controller.installPlugin]
  /// directly: the trust decision was made when the plugin was installed.
  Future<void> _confirmInstall(BuildContext context) async {
    final details = [
      if (entry.description.isNotEmpty) entry.description,
      [
        if (entry.author.isNotEmpty) 'by ${entry.author}',
        if (entry.version > 0) 'version ${entry.version}',
      ].join(' · '),
    ].where((line) => line.isNotEmpty).join('\n');
    final install = await showDialog<bool>(
      context: context,
      builder: (context) {
        final palette = context.palette;
        return AlertDialog(
          backgroundColor: palette.surface,
          title: Text('Install ${entry.name}?'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (details.isNotEmpty) ...[
                  Text(
                    details,
                    style: TextStyle(fontSize: 12.5, color: palette.textDim),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  'Plugins run as programs on this computer, outside the '
                  'flatpak sandbox, with the same access to your files as '
                  'you. Install only plugins you trust.',
                  style: TextStyle(fontSize: 12.5, color: palette.warning),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Install'),
            ),
          ],
        );
      },
    );
    if (install ?? false) {
      await controller.installPlugin(entry);
    }
  }
}

/// The button that takes an installed plugin away, after asking.
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.controller, required this.plugin});

  final LibraryController controller;
  final Plugin plugin;

  @override
  Widget build(BuildContext context) {
    if (controller.isPluginBusy(plugin.id)) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return IconButton(
      tooltip: 'Remove ${plugin.name}',
      icon: const Icon(Icons.delete_outline, size: 18),
      onPressed: () => _confirm(context),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.palette.surface,
        title: Text('Remove ${plugin.name}?'),
        content: Text('Its folder is deleted from ${controller.pluginDir}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove ?? false) await controller.removePlugin(plugin);
  }
}

/// The accent choices, as a row of circles; the active one is ringed and ticked.
class _AccentRow extends StatelessWidget {
  const _AccentRow({required this.selected, required this.onChanged});

  final AppAccent selected;
  final ValueChanged<AppAccent> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final brightness = Theme.of(context).brightness;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final accent in AppAccent.values)
          Tooltip(
            message: accent.label,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onChanged(accent),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accent.color,
                  shape: BoxShape.circle,
                  // The ring is the page's own text colour, so it reads in both
                  // modes; the idle outline keeps pale accents off the page.
                  border: Border.all(
                    color: accent == selected ? palette.text : palette.surfaceHigh,
                    width: accent == selected ? 3 : 1,
                  ),
                ),
                child: accent == selected
                    ? Icon(
                        Icons.check,
                        size: 16,
                        color: AppPalette.forMode(brightness, accent.color).onAccent,
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// SteamGridDB key + automatic fetching.
class _SteamGridDbSection extends StatefulWidget {
  const _SteamGridDbSection({required this.controller});

  final LibraryController controller;

  @override
  State<_SteamGridDbSection> createState() => _SteamGridDbSectionState();
}

class _SteamGridDbSectionState extends State<_SteamGridDbSection> {
  late final TextEditingController _key = TextEditingController(
    text: widget.controller.config.steamgriddbKey,
  );
  bool _checking = false;
  String? _result;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final palette = context.palette;
    final enabled = controller.covers.settings.sgdbEnabled;
    final picked = controller.config.artOverrides.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cover art for the games Steam has none for. Create a key at '
          'steamgriddb.com/profile/preferences/api.',
          style: TextStyle(color: palette.textDim, fontSize: 12.5),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _key,
                obscureText: true,
                decoration: const InputDecoration(hintText: 'SteamGridDB API key'),
                onSubmitted: _save,
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(onPressed: () => _save(_key.text), child: const Text('Save')),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _checking ? null : _test,
              child: _checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Test'),
            ),
          ],
        ),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _result!,
              style: TextStyle(
                fontSize: 12.5,
                color: _result!.startsWith('Key works') ? palette.accentSoft : palette.warning,
              ),
            ),
          ),
        SwitchListTile(
          value: controller.config.steamgriddbAuto,
          onChanged: enabled ? controller.setSteamgriddbAuto : null,
          title: const Text('Fetch SteamGridDB art automatically'),
          subtitle: const Text(
            'Games without local cover art are matched by Steam app id, then by name',
          ),
          contentPadding: EdgeInsets.zero,
        ),
        if (picked > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '$picked ${picked == 1 ? 'game uses' : 'games use'} picked artwork',
              style: TextStyle(fontSize: 12, color: palette.textDim),
            ),
          ),
      ],
    );
  }

  void _save(String value) {
    widget.controller.setSteamgriddbKey(value);
    setState(() => _result = null);
  }

  Future<void> _test() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    final result = await widget.controller.testSgdbKey(_key.text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
    });
  }
}

class _AddFolderField extends StatefulWidget {
  const _AddFolderField({required this.onAdd});

  final ValueChanged<String> onAdd;

  @override
  State<_AddFolderField> createState() => _AddFolderFieldState();
}

class _AddFolderFieldState extends State<_AddFolderField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(hintText: '~/Games or /opt'),
              onSubmitted: _submit,
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(onPressed: () => _submit(_controller.text), child: const Text('Add')),
        ],
      ),
    );
  }

  void _submit(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    widget.onAdd(trimmed);
    _controller.clear();
  }
}
