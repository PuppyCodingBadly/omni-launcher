/// Desktop entry helpers shared by the flatpak and desktop sources.
library;

import 'dart:io';

import 'proc.dart';
import 'shell.dart';

/// Field codes that must be dropped from an `Exec=` line.
final RegExp _execFieldCode = RegExp(r'^%[fFuUdDnNickvm]$');

/// Turn an `Exec=` line into argv, dropping field codes.
List<String> desktopExecArgv(String execLine) =>
    splitShellWords(execLine).where((part) => !_execFieldCode.hasMatch(part)).toList();

List<String> desktopCategories(Map<String, String> entry) => (entry['Categories'] ?? '')
    .split(';')
    .where((category) => category.isNotEmpty)
    .toList();

/// `net.retrodeck.retrodeck.Configurator.desktop` -> `net.retrodeck.retrodeck`.
String? flatpakAppForDesktop(String desktopName, Set<String> appIds) {
  final base = desktopName.endsWith('.desktop')
      ? desktopName.substring(0, desktopName.length - '.desktop'.length)
      : desktopName;
  if (appIds.contains(base)) return base;
  final matches = appIds.where((app) => base.startsWith('$app.')).toList();
  if (matches.isEmpty) return null;
  matches.sort((a, b) => b.length.compareTo(a.length));
  return matches.first;
}

bool isFlatpakExport(String path) =>
    path.contains('flatpak/exports/share/applications');

/// argv that starts whatever this desktop entry describes.
Future<List<String>> desktopLaunchCommand(String path, Map<String, String> entry) async {
  final appId = flatpakAppForDesktop(File(path).uri.pathSegments.last, await flatpakAppIds());
  if (appId != null && (isFlatpakExport(path) || which('flatpak') != null)) {
    return ['flatpak', 'run', appId];
  }
  if (which('gtk-launch') != null) {
    return ['gtk-launch', File(path).uri.pathSegments.last];
  }
  return desktopExecArgv(entry['Exec'] ?? '');
}
