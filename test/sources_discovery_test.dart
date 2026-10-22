import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/host.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/sources/desktop.dart';
import 'package:omni_launcher/src/sources/faugus.dart';
import 'package:omni_launcher/src/sources/steam.dart';
import 'package:omni_launcher/src/util/proc.dart';

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
  String sizeOnDisk = '2048',
}) {
  File('$library/steamapps/appmanifest_$appid.acf')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
"AppState"
{
	"appid"		"$appid"
	"name"		"$name"
	"StateFlags"		"$stateFlags"
	"SizeOnDisk"		"$sizeOnDisk"
	"installdir"		"$installdir"
}
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
  group('SteamSource', () {
    test(
      'discovers installed games across two libraries, one symlinked',
      () async {
        final dir = tempDir('omni-steam');
        final root = '${dir.path}/steam';
        final libA = '${dir.path}/libA';
        final libB = '${dir.path}/libB';
        Directory(libA).createSync(recursive: true);
        Directory(libB).createSync(recursive: true);
        // The second library is listed through a symlink, the way a moved
        // library commonly is.
        Link('${dir.path}/libB-link').createSync(libB);
        libraryFolders(root, [libA, '${dir.path}/libB-link']);

        appManifest(
          libA,
          111,
          name: 'Test Game Alpha',
          stateFlags: '4',
          installdir: 'Alpha',
        );
        // StateFlags 2 lacks the fully-installed bit: not a playable game yet.
        appManifest(libA, 222, name: 'Test Game Pending', stateFlags: '2');
        // Tooling entries are not games, however installed they claim to be.
        appManifest(libA, 333, name: 'SteamVR', stateFlags: '4');
        appManifest(
          libB,
          444,
          name: 'Test Game Beta',
          stateFlags: '4',
          installdir: 'Beta',
        );

        // `~/.steam/steam` style: a second root that is just a link to the
        // first must not double the games.
        Link('${dir.path}/steam-link').createSync(root);

        final games = await SteamSource(
          roots: [root, '${dir.path}/steam-link', '${dir.path}/no-such-root'],
        ).discover(AppConfig());

        expect(games.map((game) => game.id), ['steam:111', 'steam:444']);

        final alpha = games[0];
        expect(alpha.key, '111');
        expect(alpha.name, 'Test Game Alpha');
        expect(alpha.source, SourceKind.steam);
        expect(alpha.subtitle, 'Steam');
        expect(alpha.path, '$libA/steamapps/common/Alpha');
        expect(alpha.extra, {'appid': '111', 'size': 2048, 'library': libA});
        // The argv tail asks Steam to start the appid, whichever launcher
        // prefix (native steam, flatpak) the host offers.
        expect(alpha.command.sublist(alpha.command.length - 2), [
          '-applaunch',
          '111',
        ]);

        final beta = games[1];
        expect(beta.id, 'steam:444');
        expect(beta.name, 'Test Game Beta');
        // The library is reported at the path libraryfolders.vdf gave, not the
        // resolved one.
        expect(beta.path, '${dir.path}/libB-link/steamapps/common/Beta');
        expect(beta.command.sublist(beta.command.length - 2), [
          '-applaunch',
          '444',
        ]);
      },
    );

    test(
      'a flatpak-style sandbox root scans with no libraryfolders.vdf',
      () async {
        final dir = tempDir('omni-steam-flatpak');
        final root =
            '${dir.path}/.var/app/com.valvesoftware.Steam/.local/share/Steam';
        appManifest(
          root,
          555,
          name: 'Test Game Gamma',
          stateFlags: '4',
          installdir: 'Gamma',
        );

        final games = await SteamSource(roots: [root]).discover(AppConfig());

        expect(games, hasLength(1));
        expect(games.single.id, 'steam:555');
        expect(games.single.name, 'Test Game Gamma');
        expect(games.single.path, '$root/steamapps/common/Gamma');
        expect(games.single.command.sublist(games.single.command.length - 2), [
          '-applaunch',
          '555',
        ]);
      },
    );
  });

  group('DesktopSource', () {
    // `_desktopDirs` in the source is a top-level final bound on the first
    // discover() call in this process, so every test in the group has to
    // serve its fixtures from one stable mount root — a fresh tempDir per
    // test would leave the bound dirs pointing at a deleted tree.
    final mount = '${Directory.systemTemp.path}/omni-desktop-mount';
    final applications = '$mount/usr/share/applications';

    setUp(() {
      final root = Directory(mount);
      if (root.existsSync()) root.deleteSync(recursive: true);
      // The sandbox mount seam re-roots the system applications dirs at a
      // fixture tree.
      Directory(applications).createSync(recursive: true);
      Host.setInFlatpakForTest(true);
      Host.setMountForTest(mount);
      setFlatpakAppIdsForTest(<String>{});
    });

    tearDown(() {
      Host.setInFlatpakForTest(null);
      Host.setMountForTest(null);
      setFlatpakAppIdsForTest(null);
      final root = Directory(mount);
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    void entry(String name, String exec) {
      File('$applications/$name.desktop').writeAsStringSync('''
[Desktop Entry]
Type=Application
Name=OmniTest $name
Exec=$exec
Categories=Game;
''');
    }

    /// The discovered fixture games, ignoring anything the real host's
    /// `~/.local/share/applications` (always scanned) happens to hold.
    Future<Map<String, Game>> fixtures() async {
      final games = await DesktopSource().discover(AppConfig());
      return {
        for (final game in games)
          if (game.name.startsWith('OmniTest')) game.key: game,
      };
    }

    test('a steam:// entry is owned by Steam via its dedupe key', () async {
      entry('testgame-steam', 'steam steam://rungameid/12345');
      entry('testgame-plain', '/nonexistent/omnitest-run %U');

      final games = await fixtures();
      expect(games, hasLength(2));

      final steam = games['testgame-steam.desktop']!;
      expect(steam.id, 'desktop:testgame-steam.desktop');
      expect(steam.name, 'OmniTest testgame-steam');
      expect(steam.source, SourceKind.desktop);
      expect(steam.subtitle, 'Desktop entry');
      // The steam:// entry does not get a `steam -applaunch` argv here: the
      // dedupe key hands the game to the Steam source, whose launch command
      // wins over this one.
      expect(steam.extra['dedupe'], 'steam:12345');

      final plain = games['testgame-plain.desktop']!;
      expect(plain.id, 'desktop:testgame-plain.desktop');
      // No absolute executable to own it, so no dedupe key.
      expect(plain.extra.containsKey('dedupe'), isFalse);
    });

    test(
      'an entry wrapping an AppImage shares the AppImage dedupe key',
      () async {
        // The desktop source must key the wrapped file exactly like the
        // AppImage source does: the resolved symlink when that works, the
        // absolute path as fallback, so the two never split into duplicates.
        final gamesDir = Directory('$mount/games')..createSync();
        final appimage = File('${gamesDir.path}/Wrapped.AppImage')
          ..writeAsBytesSync([0]);
        final bin = Directory('$mount/bin')..createSync();
        Link('${bin.path}/wrapped').createSync(appimage.path);
        entry('testgame-wrapped', '${bin.path}/wrapped');
        entry('testgame-direct', appimage.path);

        final games = await fixtures();
        expect(games, hasLength(2));
        // Both entries own the same file the AppImage source would report.
        for (final name in ['testgame-wrapped', 'testgame-direct']) {
          expect(
            games['$name.desktop']!.extra['dedupe'],
            'path:${appimage.absolute.path}',
          );
        }
      },
    );

    test('entries launch through gtk-launch when the host offers it', () async {
      final bin = Directory('$mount/usr/bin')..createSync();
      File('${bin.path}/gtk-launch').writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['755', '${bin.path}/gtk-launch']);
      entry('testgame-steam', 'steam steam://rungameid/12345');
      entry('testgame-plain', '/nonexistent/omnitest-run %U');

      final games = await fixtures();
      expect(games, hasLength(2));
      // gtk-launch answers from the (fixture) host mount.
      expect(games['testgame-steam.desktop']!.command, [
        'gtk-launch',
        'testgame-steam.desktop',
      ]);
      expect(games['testgame-plain.desktop']!.command, [
        'gtk-launch',
        'testgame-plain.desktop',
      ]);
      expect(games['testgame-steam.desktop']!.extra['dedupe'], 'steam:12345');
    });

    test('without gtk-launch the Exec line is the command', () async {
      entry('testgame-steam', 'steam steam://rungameid/12345');
      entry('testgame-plain', '/nonexistent/omnitest-run %U');

      final games = await fixtures();
      expect(games, hasLength(2));
      final gtkLaunch = which('gtk-launch');
      if (gtkLaunch == null) {
        expect(games['testgame-steam.desktop']!.command, [
          'steam',
          'steam://rungameid/12345',
        ]);
        // Field codes are dropped from the Exec line.
        expect(games['testgame-plain.desktop']!.command, [
          '/nonexistent/omnitest-run',
        ]);
      } else {
        // A real gtk-launch on the host wins over the fixture mount.
        expect(games['testgame-steam.desktop']!.command, [
          'gtk-launch',
          'testgame-steam.desktop',
        ]);
        expect(games['testgame-plain.desktop']!.command, [
          'gtk-launch',
          'testgame-plain.desktop',
        ]);
      }
    });
  });

  group('FaugusSource', () {
    // FaugusSource discovers from the host's real data dirs with no
    // injectable seam, so the parse layer is what a fixture can reach.
    test('readGames parses a games.json list of records', () async {
      final dir = tempDir('omni-faugus');
      final gamesJson = '${dir.path}/games.json';
      File(gamesJson).writeAsStringSync('''
[
  {
    "gameid": "abc123",
    "title": "Alpha Quest",
    "path": "/games/alpha/alpha.exe",
    "prefix": "/prefixes/alpha",
    "icon": "",
    "cover": ""
  },
  {
    "gameid": "def456",
    "title": "Beta Siege",
    "path": "/games/beta/beta.exe",
    "prefix": ""
  }
]
''');

      final entries = await readGames(gamesJson);
      expect(entries, hasLength(2));
      expect(entries[0]['title'], 'Alpha Quest');
      expect(entries[0]['prefix'], '/prefixes/alpha');
      expect(entries[1]['title'], 'Beta Siege');
      expect(entries[1]['path'], '/games/beta/beta.exe');
    });

    test('readGames yields nothing for a missing or malformed file', () async {
      final dir = tempDir('omni-faugus-bad');
      expect(await readGames('${dir.path}/gone.json'), isEmpty);
      final bad = '${dir.path}/bad.json';
      File(bad).writeAsStringSync('{"not": "a list"}');
      expect(await readGames(bad), isEmpty);
    });
  });
}
