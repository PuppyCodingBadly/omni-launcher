import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/host.dart';
import 'package:omni_launcher/src/paths.dart';
import 'package:omni_launcher/src/plugins/catalog.dart';

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
      expect(
        AppPaths.stateDir,
        '${Host.home}/.local/state/omnilauncher-flutter',
      );
      expect(
        AppPaths.pluginDir,
        '${Host.home}/.local/share/omnilauncher-flutter/plugins',
      );
      // Downloaded artwork is user data, not cache: an update or a cache
      // cleanup must not take the grid the user picked.
      expect(
        AppPaths.coverDir,
        '${Host.home}/.local/share/omnilauncher-flutter/covers',
      );
      expect(
        AppPaths.legacyCoverDir,
        '${Host.home}/.cache/omnilauncher-flutter/covers',
      );
    });
  });

  group('the version in three places', () {
    test('AppPaths.version matches pubspec.yaml and the metainfo release', () {
      // flutter test runs with the package root as the working directory.
      final pubspec = File('pubspec.yaml');
      final metainfo = File(
        'flatpak/io.github.PuppyCodingBadly.OmniLauncher.metainfo.xml',
      );
      expect(
        pubspec.existsSync(),
        isTrue,
        reason:
            'pubspec.yaml not found from ${Directory.current.path}: '
            'this test must run from the package root',
      );
      expect(
        metainfo.existsSync(),
        isTrue,
        reason:
            'metainfo.xml not found from ${Directory.current.path}: '
            'this test must run from the package root',
      );

      final match = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec.readAsStringSync());
      expect(match, isNotNull, reason: 'no version: line in pubspec.yaml');
      final pubspecVersion = match!.group(1)!.split('+').first;
      expect(
        AppPaths.version,
        pubspecVersion,
        reason: 'AppPaths.version drifted from pubspec.yaml',
      );

      final releases = RegExp(r'<release\s+version="([^"]+)"')
          .allMatches(metainfo.readAsStringSync())
          .map((m) => m.group(1))
          .toSet();
      expect(
        releases,
        contains(AppPaths.version),
        reason: 'no <release version="${AppPaths.version}"> in metainfo.xml',
      );
    });
  });

  group('the plugin catalogue', () {
    test('is served from this repository, and the README says so', () {
      expect(
        pluginIndexUrl,
        'https://raw.githubusercontent.com/PuppyCodingBadly/omni-launcher/'
        'main/plugins/index.json',
      );
      // flutter test runs with the package root as the working directory.
      expect(
        File('README.md').readAsStringSync(),
        contains(pluginIndexUrl),
        reason: 'README.md and pluginIndexUrl drifted apart',
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
      expect(
        File('${to.path}/config.json').readAsStringSync(),
        'the host\'s own',
      );
      expect(File('${to.path}/playtime.json').readAsStringSync(), '{ }');
      expect(Directory('${to.path}/covers').existsSync(), isFalse);
    });

    test('a folder that is not there is nothing to take over', () {
      expect(
        AppPaths.adoptFiles('${dir.path}/gone', '${dir.path}/to'),
        isEmpty,
      );
    });

    test('artwork cached by an earlier build moves to the data folder', () {
      final from = Directory('${dir.path}/cache/covers')
        ..createSync(recursive: true);
      final cached = File('${from.path}/sgdb_steam_1_42.png')
        ..writeAsBytesSync([1, 2, 3]);
      final to = '${dir.path}/data/covers';

      final rehomed = AppPaths.rehomeCover(
        cached.path,
        from: from.path,
        to: to,
      );

      expect(rehomed, '$to/sgdb_steam_1_42.png');
      expect(File(rehomed).readAsBytesSync(), [1, 2, 3]);
      // A path outside the old folders belongs to somebody else.
      expect(
        AppPaths.rehomeCover('${dir.path}/elsewhere/a.png', from: from.path),
        '${dir.path}/elsewhere/a.png',
      );
    });

    test('there is nothing to take over outside a sandbox', () {
      expect(AppPaths.adoptSandboxFiles(), isEmpty);
    });
  });
}
