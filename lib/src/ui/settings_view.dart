import 'package:flutter/material.dart';

import '../config.dart';
import '../paths.dart';
import '../state/library_controller.dart';
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
                command: commandController.text.trim().split(RegExp(r'\s+')),
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

  Widget _pathTile(String label, String path) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: SelectableText(path, style: const TextStyle(fontSize: 12)),
  );
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
