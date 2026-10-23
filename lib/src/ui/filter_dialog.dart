import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import 'theme.dart';

/// Tags and smart filters, with one live checkbox each.
///
/// The wall updates behind the dialog: the checkboxes call the controller and
/// rebuild from its notifications, the same way the settings switches do.
Future<void> showFilterDialog(
  BuildContext context, {
  required LibraryController controller,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final palette = context.palette;
      return AlertDialog(
        backgroundColor: palette.surface,
        title: const Text('Filters'),
        content: SizedBox(
          width: 440,
          height: 460,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final tags = controller.allTags;
              return ListView(
                children: [
                  _header(context, 'Status'),
                  for (final filter in SmartFilter.values)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: controller.smartFilters.contains(filter),
                      onChanged: (_) => controller.toggleSmartFilter(filter),
                      title: Text(filter.label),
                    ),
                  const SizedBox(height: 12),
                  _header(context, 'Tags'),
                  if (tags.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No tags yet. Add them from a game’s cog.',
                        style: TextStyle(color: palette.textDim),
                      ),
                    ),
                  for (final tag in tags)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      // The filter keeps the casing it was added with, and
                      // that can go stale when a source or the config renames
                      // a tag: compare folded so the box never reads unchecked
                      // while the filter is actually on.
                      value: _isFiltered(controller, tag),
                      onChanged: (_) => controller.toggleTag(
                        _activeTag(controller, tag) ?? tag,
                      ),
                      title: Text(tag),
                    ),
                  if (controller.tagFilter.isNotEmpty ||
                      controller.smartFilters.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () {
                          controller.clearTags();
                          controller.clearSmartFilters();
                        },
                        child: const Text('Clear all'),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );
}

/// The filter's own spelling of [tag], when it is on under any casing.
String? _activeTag(LibraryController controller, String tag) {
  final folded = tag.toLowerCase();
  for (final active in controller.tagFilter) {
    if (active.toLowerCase() == folded) return active;
  }
  return null;
}

bool _isFiltered(LibraryController controller, String tag) =>
    _activeTag(controller, tag) != null;

Widget _header(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 4, top: 4),
  child: Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 10,
      letterSpacing: 1.2,
      color: context.palette.textDim,
      fontWeight: FontWeight.w700,
    ),
  ),
);
