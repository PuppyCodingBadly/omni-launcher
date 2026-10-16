import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/host.dart';
import 'package:omni_launcher/src/paths.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('omni-paths'));
  tearDown(() {
    Host.setInFlatpakForTest(null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('the folders the launcher keeps its own files in', () {
    test('are the host\'s, even from inside a sandbox', () {
      // Flatpak points the XDG variables at the sandbox's own folders; the
      // launcher ignores them so that a native build and the flatpak share one
      // set of hidden games, renames and playtime.
      Host.setInFlatpakForTest(true);

      expect(AppPaths.configDir, '${Host.home}/.config/omnilauncher-flutter');
      expect(AppPaths.cacheDir, '${Host.home}/.cache/omnilauncher-flutter');
      expect(AppPaths.stateDir, '${Host.home}/.local/state/omnilauncher-flutter');
      expect(
        AppPaths.pluginDir,
        '${Host.home}/.local/share/omnilauncher-flutter/plugins',
      );
    });
  });

  group('taking over what a sandbox kept', () {
    test('copies what the host does not have, and leaves what it has', () {
      final from = Directory('${dir.path}/from')..createSync();
      final to = Directory('${dir.path}/to')..createSync();
      File('${from.path}/config.json').writeAsStringSync('from the sandbox');
      File('${from.path}/playtime.json').writeAsStringSync('{ }');
      File('${to.path}/config.json').writeAsStringSync('the host\'s own');
      // The cover cache is a folder: it comes back on its own.
      Directory('${from.path}/covers').createSync();

      final written = AppPaths.adoptFiles(from.path, to.path);

      expect(written, ['${to.path}/playtime.json']);
      expect(File('${to.path}/config.json').readAsStringSync(), 'the host\'s own');
      expect(File('${to.path}/playtime.json').readAsStringSync(), '{ }');
      expect(Directory('${to.path}/covers').existsSync(), isFalse);
    });

    test('a folder that is not there is nothing to take over', () {
      expect(AppPaths.adoptFiles('${dir.path}/gone', '${dir.path}/to'), isEmpty);
    });

    test('there is nothing to take over outside a sandbox', () {
      expect(AppPaths.adoptSandboxFiles(), isEmpty);
    });
  });
}
