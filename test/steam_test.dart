import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/sources/steam.dart';

/// A directory that is removed again when the test ends.
Directory tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Nothing useful to do about a failing cleanup.
    }
  });
  return dir;
}

/// An `appmanifest_<appid>.acf` fixture in `<library>/steamapps`.
void appManifest(
  String library,
  int appid, {
  required String name,
  required String stateFlags,
  String installdir = 'GameFolder',
  String? sizeOnDisk = '2048',
  bool includeAppId = true,
  String extra = '',
}) {
  File('$library/steamapps/appmanifest_$appid.acf')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
"AppState"
{
${includeAppId ? '\t"appid"\t\t"$appid"\n' : ''}	"name"		"$name"
	"StateFlags"		"$stateFlags"
${sizeOnDisk == null ? '' : '\t"SizeOnDisk"		"$sizeOnDisk"\n'}	"installdir"		"$installdir"
$extra}
''');
}

/// A `steamapps/libraryfolders.vdf` fixture at [root] listing [libraries].
void libraryFolders(String root, List<String> libraries) {
  final buffer = StringBuffer('"libraryfolders"\n{\n');
  for (var i = 0; i < libraries.length; i++) {
    buffer.writeln('	"$i"');
    buffer.writeln('	{');
    buffer.writeln('		"path"		"${libraries[i]}"');
    buffer.writeln('	}');
  }
  buffer.writeln('}');
  File('$root/steamapps/libraryfolders.vdf')
    ..createSync(recursive: true)
    ..writeAsStringSync(buffer.toString());
}

void main() {
  group('SteamSource state flags', () {
    test('the flags decide which installs count, and how', () async {
      final dir = tempDir('omni-steam-flags');
      final root = '${dir.path}/steam';
      // Fully installed, nothing else going on.
      appManifest(root, 10, name: 'Installed Game', stateFlags: '4');
      // Installed, but Steam says an update is required.
      appManifest(root, 20, name: 'Needs Update', stateFlags: '6');
      // Installed and being downloaded right now (4 | 1048576).
      appManifest(
        root,
        30,
        name: 'Downloading Game',
        stateFlags: '1048580',
        extra:
            '\t"BytesDownloaded"\t\t"1000"\n\t"BytesToDownload"\t\t"4000"\n',
      );
      // Installed but being uninstalled (4 | 2048): on its way out.
      appManifest(root, 40, name: 'Leaving Game', stateFlags: '2052');
      // Installed with files missing (4 | 32).
      appManifest(root, 50, name: 'Broken Game', stateFlags: '36');
      // Update required but not installed: not a playable game yet.
      appManifest(root, 60, name: 'Not Installed', stateFlags: '2');
      // Flags that do not parse are no answer at all.
      appManifest(root, 70, name: 'Odd Flags', stateFlags: 'not-a-number');

      final games = await SteamSource(roots: [root]).discover(AppConfig());
      final byId = {for (final game in games) game.id: game};

      expect(byId.keys.toSet(), {
        'steam:10',
        'steam:20',
        'steam:30',
        'steam:50',
      });

      final installed = byId['steam:10']!;
      expect(installed.updating, isFalse);
      expect(installed.updateRequired, isFalse);
      expect(installed.broken, isFalse);
      expect(installed.launchable, isTrue);
      expect(installed.extra.containsKey('updating'), isFalse);

      final needsUpdate = byId['steam:20']!;
      expect(needsUpdate.updateRequired, isTrue);
      expect(needsUpdate.updating, isFalse);
      // Byte counters are meaningless when no update is live.
      expect(needsUpdate.extra.containsKey('bytes_downloaded'), isFalse);
      expect(needsUpdate.extra.containsKey('bytes_to_download'), isFalse);

      final downloading = byId['steam:30']!;
      expect(downloading.updating, isTrue);
      expect(downloading.updateRequired, isFalse);
      expect(downloading.extra['bytes_downloaded'], 1000);
      expect(downloading.extra['bytes_to_download'], 4000);

      final broken = byId['steam:50']!;
      expect(broken.broken, isTrue);
      expect(broken.launchable, isFalse);
    });
  });

  group('SteamSource libraries', () {
    test('games come from every folder libraryfolders.vdf lists', () async {
      final dir = tempDir('omni-steam-libraries');
      final root = '${dir.path}/steam';
      final libA = '${dir.path}/libA';
      final libB = '${dir.path}/libB';
      Directory(libA).createSync(recursive: true);
      Directory(libB).createSync(recursive: true);
      libraryFolders(root, [libA, libB]);
      appManifest(libA, 100, name: 'Alpha', stateFlags: '4', installdir: 'A');
      appManifest(libB, 200, name: 'Beta', stateFlags: '4', installdir: 'B');
      // The root's own steamapps is not scanned when the vdf points
      // elsewhere: the vdf is the whole list of libraries.
      appManifest(root, 300, name: 'Root Game', stateFlags: '4');

      final games = await SteamSource(roots: [root]).discover(AppConfig());

      expect(games.map((game) => game.id), ['steam:100', 'steam:200']);
      final alpha = games[0];
      expect(alpha.extra['library'], libA);
      expect(alpha.path, '$libA/steamapps/common/A');
      final beta = games[1];
      expect(beta.extra['library'], libB);
      expect(beta.path, '$libB/steamapps/common/B');
    });
  });

  group('SteamSource roots', () {
    test('the flatpak sandbox is one of the default roots', () {
      expect(
        SteamSource().roots,
        contains(
          endsWith('.var/app/com.valvesoftware.Steam/.local/share/Steam'),
        ),
      );
    });

    test('a root without libraryfolders.vdf is its own library', () async {
      final dir = tempDir('omni-steam-flatpak');
      // The flatpak sandbox layout carries no libraryfolders.vdf.
      final root =
          '${dir.path}/.var/app/com.valvesoftware.Steam/.local/share/Steam';
      appManifest(root, 555, name: 'Sandboxed Game', stateFlags: '4');
      // The sandbox keeps its own appcache, and the cover comes from the
      // manifest's owning root.
      File('$root/appcache/librarycache/555/library_600x900.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);

      final games = await SteamSource(roots: [root]).discover(AppConfig());

      expect(games, hasLength(1));
      final game = games.single;
      expect(game.id, 'steam:555');
      expect(game.extra['library'], root);
      expect(game.path, '$root/steamapps/common/GameFolder');
      expect(
        game.cover,
        '$root/appcache/librarycache/555/library_600x900.jpg',
      );
    });
  });

  group('SteamSource manifest edges', () {
    test('a manifest without a size, or a zero one, reports zero', () async {
      final dir = tempDir('omni-steam-sizes');
      final root = '${dir.path}/steam';
      appManifest(root, 400, name: 'No Size', stateFlags: '4', sizeOnDisk: null);
      appManifest(root, 401, name: 'Zero Size', stateFlags: '4', sizeOnDisk: '0');

      final games = await SteamSource(roots: [root]).discover(AppConfig());
      final byId = {for (final game in games) game.id: game};

      expect(byId['steam:400']!.extra['size'], 0);
      expect(byId['steam:401']!.extra['size'], 0);
    });

    test('a missing installdir leaves the path at the common folder', () async {
      final dir = tempDir('omni-steam-installdir');
      final root = '${dir.path}/steam';
      appManifest(root, 402, name: 'No Folder', stateFlags: '4', installdir: '');

      final games = await SteamSource(roots: [root]).discover(AppConfig());

      expect(games.single.path, '$root/steamapps/common');
    });

    test('the app id falls back to the manifest file name', () async {
      final dir = tempDir('omni-steam-appid');
      final root = '${dir.path}/steam';
      appManifest(root, 403, name: 'No Appid Key', stateFlags: '4',
          includeAppId: false);

      final games = await SteamSource(roots: [root]).discover(AppConfig());

      expect(games.single.id, 'steam:403');
      expect(games.single.key, '403');
    });
  });
}
