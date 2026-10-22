import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/config.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/sources/registry.dart';
import 'package:omni_launcher/src/sources/source.dart';
import 'package:omni_launcher/src/sources/steam_shortcuts.dart';

/// Build the binary KeyValues Steam writes for non-Steam shortcuts.
List<int> shortcutFile(List<Map<String, Object?>> shortcuts) {
  final out = <int>[];
  void writeString(String value) {
    out.addAll(utf8.encode(value));
    out.add(0);
  }

  // Binary KeyValues order is: type byte, key (NUL terminated), value.
  void writeEntry(String key, Object? value) {
    if (value is Map) {
      out.add(0x00);
      writeString(key);
      for (final entry in value.entries) {
        writeEntry('${entry.key}', entry.value);
      }
      out.add(0x08);
      return;
    }
    if (value is String) {
      out.add(0x01);
      writeString(key);
      writeString(value);
      return;
    }
    if (value is int) {
      out.add(0x02);
      writeString(key);
      out.addAll([
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ]);
    }
  }

  out.add(0x00);
  writeString('shortcuts');
  for (var i = 0; i < shortcuts.length; i++) {
    out.add(0x00);
    writeString(i.toString());
    for (final entry in shortcuts[i].entries) {
      writeEntry(entry.key, entry.value);
    }
    out.add(0x08);
  }
  out.add(0x08);
  return out;
}

const int retroDeckSignedId = -1793624754; // 0x951ee54e, as Steam stores it
const int retroDeckUnsignedId = 2501342542;

Game game({
  String id = 'flatpak:net.retrodeck.retrodeck',
  String key = 'net.retrodeck.retrodeck',
  String name = 'RetroDECK',
  SourceKind source = SourceKind.flatpak,
  List<String> command = const ['flatpak', 'run', 'net.retrodeck.retrodeck'],
  String path = '/games/retrodeck',
  Map<String, Object?> extra = const {},
}) => Game(
  id: id,
  key: key,
  name: name,
  source: source,
  command: command,
  icon: 'net.retrodeck.retrodeck',
  iconIsName: true,
  path: path,
  extra: extra,
);

void main() {
  group('binary keyvalues', () {
    test('reads the shape Steam writes', () {
      final parsed = parseBinaryVdf(
        shortcutFile([
          {
            'appid': retroDeckSignedId,
            'appname': 'RetroDECK',
            'exe': '"flatpak"',
            'StartDir': '.',
            'LaunchOptions': 'run net.retrodeck.retrodeck',
            'IsHidden': 0,
            'FlatpakAppID': 'net.retrodeck.retrodeck',
          },
        ]),
      );
      final entry = (parsed['shortcuts'] as Map)['0'] as Map;
      expect(entry['appname'], 'RetroDECK');
      expect(entry['FlatpakAppID'], 'net.retrodeck.retrodeck');
      expect(entry['IsHidden'], 0);
    });

    test(
      'a truncated or foreign file yields what was readable, never throws',
      () {
        final bytes = shortcutFile([
          {'appid': 1, 'appname': 'Kept'},
          {'appid': 2, 'appname': 'Lost'},
        ]);
        final truncated = parseBinaryVdf(bytes.sublist(0, bytes.length - 6));
        expect(truncated, isA<Map<String, Object?>>());
        expect(parseBinaryVdf(const []), isEmpty);
        expect(parseBinaryVdf(utf8.encode('not a vdf at all')), isEmpty);
      },
    );
  });

  group('shortcut files', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('omni-shortcuts'));
    tearDown(() => dir.deleteSync(recursive: true));

    void writeShortcuts(String user, List<Map<String, Object?>> shortcuts) {
      final file = File('${dir.path}/userdata/$user/config/shortcuts.vdf');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(shortcutFile(shortcuts));
    }

    test(
      'reads every userdata directory and converts the app id unsigned',
      () async {
        writeShortcuts('1', [
          {
            'appid': retroDeckSignedId,
            'appname': 'RetroDECK',
            'FlatpakAppID': 'net.retrodeck.retrodeck',
            'IsHidden': 0,
          },
        ]);
        writeShortcuts('2', [
          {'appid': 42, 'AppName': 'Older Steam', 'exe': '/usr/bin/thing'},
        ]);
        final shortcuts = await readSteamShortcuts(roots: [dir.path]);
        expect(shortcuts, hasLength(2));
        final byName = {
          for (final shortcut in shortcuts) shortcut.name: shortcut,
        };
        final retrodeck = byName['RetroDECK']!;
        expect(retrodeck.appId, retroDeckUnsignedId);
        expect(retrodeck.flatpakAppId, 'net.retrodeck.retrodeck');
        expect(retrodeck.matchesFlatpak('net.retrodeck.retrodeck'), isTrue);
        expect(byName['Older Steam']!.name, 'Older Steam');
        expect(byName['Older Steam']!.appId, 42);
      },
    );

    test('the same file behind two roots is only read once', () async {
      writeShortcuts('1', [
        {'appid': 7, 'appname': 'Once'},
      ]);
      final link = Link('${dir.path}/link');
      link.createSync(dir.path);
      final shortcuts = await readSteamShortcuts(roots: [dir.path, link.path]);
      expect(shortcuts, hasLength(1));
    });

    test('entries without an id or a name are skipped', () async {
      writeShortcuts('1', [
        {'appname': 'No id'},
        {'appid': 3},
        {'appid': 4, 'appname': '   '},
        {'appid': 5, 'appname': 'Kept'},
      ]);
      final shortcuts = await readSteamShortcuts(roots: [dir.path]);
      expect(shortcuts.map((s) => s.name).toList(), ['Kept']);
    });

    test(
      'one pair of surrounding quotes is stripped from exe and startDir',
      () async {
        writeShortcuts('1', [
          {
            'appid': 9,
            'appname': 'Quoted',
            'exe': '"/games/quoted/Game.AppImage"',
            'StartDir': '"/games/quoted"',
          },
        ]);
        final shortcuts = await readSteamShortcuts(roots: [dir.path]);
        expect(shortcuts.single.exe, '/games/quoted/Game.AppImage');
        expect(shortcuts.single.startDir, '/games/quoted');
      },
    );

    test('an unquoted exe path-matches the game a source discovered', () async {
      // Real Valve files quote the exe; without the strip the name match can
      // never verify the install path and the game keeps its bare command.
      writeShortcuts('1', [
        {
          'appid': retroDeckSignedId,
          'appname': 'RetroDECK',
          'exe': '"/games/retrodeck/RetroDECK.AppImage"',
        },
      ]);
      final shortcuts = await readSteamShortcuts(roots: [dir.path]);
      final games = await preferSteamShortcuts([
        game(
          id: 'appimage:/games/retrodeck/RetroDECK.AppImage',
          key: '/games/retrodeck/RetroDECK.AppImage',
          name: 'retrodeck',
          source: SourceKind.appimage,
          command: ['/games/retrodeck/RetroDECK.AppImage'],
        ),
      ], shortcuts);
      expect(games.single.command.last, '$retroDeckUnsignedId');
      expect(games.single.extra['launchedViaSteam'], isTrue);
    });

    test('a missing root is not an error', () async {
      expect(await readSteamShortcuts(roots: ['${dir.path}/nope']), isEmpty);
    });

    test('the default roots include the flatpak sandbox', () {
      expect(
        defaultSteamRoots(),
        contains(
          endsWith('.var/app/com.valvesoftware.Steam/.local/share/Steam'),
        ),
      );
    });
  });

  group('preferring Steam', () {
    const shortcut = SteamShortcut(
      appId: retroDeckUnsignedId,
      name: 'RetroDECK',
      flatpakAppId: 'net.retrodeck.retrodeck',
      launchOptions: 'run net.retrodeck.retrodeck',
    );

    test('a flatpak game with a shortcut is launched through Steam', () async {
      final games = await preferSteamShortcuts([game()], [shortcut]);
      expect(games, hasLength(1));
      final result = games.single;
      // The prefix is resolved from the machine (steam on PATH, or the flatpak
      // when that is the only one installed), so only the launch form is
      // asserted here.
      expect(result.command.sublist(result.command.length - 2), [
        '-applaunch',
        '$retroDeckUnsignedId',
      ]);
      expect(result.extra['launchedViaSteam'], isTrue);
      expect(result.extra['steamShortcut'], retroDeckUnsignedId);
      // Identity and presentation must not move.
      expect(result.id, 'flatpak:net.retrodeck.retrodeck');
      expect(result.key, 'net.retrodeck.retrodeck');
      expect(result.name, 'RetroDECK');
      expect(result.icon, 'net.retrodeck.retrodeck');
      expect(result.path, '/games/retrodeck');
      expect(result.source, SourceKind.flatpak);
    });

    test('a bare name match does not hijack a non-flatpak game', () async {
      // Two unrelated games can share a display name; without a path link the
      // shortcut must not take over the other game's command.
      final original = game(
        id: 'appimage:/games/RetroDECK.AppImage',
        key: '/games/RetroDECK.AppImage',
        name: 'retrodeck',
        source: SourceKind.appimage,
        command: ['/games/RetroDECK.AppImage'],
      );
      final games = await preferSteamShortcuts([original], [shortcut]);
      expect(games.single.command, original.command);
      expect(games.single.extra.containsKey('launchedViaSteam'), isFalse);
    });

    test('a shortcut whose exe sits in the install path still wins', () async {
      // RetroDECK-style: the file Steam launches is the install this source
      // found, so the name match is safe to apply.
      const pointing = SteamShortcut(
        appId: retroDeckUnsignedId,
        name: 'RetroDECK',
        exe: '/games/retrodeck/RetroDECK.AppImage',
      );
      final games = await preferSteamShortcuts(
        [
          game(
            id: 'appimage:/games/RetroDECK.AppImage',
            key: '/games/RetroDECK.AppImage',
            name: 'retrodeck',
            source: SourceKind.appimage,
            command: ['/games/RetroDECK.AppImage'],
          ),
        ],
        [pointing],
      );
      expect(games.single.command.last, '$retroDeckUnsignedId');
      expect(games.single.extra['launchedViaSteam'], isTrue);
    });

    test('a visible shortcut beats a hidden one', () async {
      final games = await preferSteamShortcuts(
        [game()],
        [
          const SteamShortcut(
            appId: 1,
            name: 'RetroDECK',
            flatpakAppId: 'net.retrodeck.retrodeck',
            hidden: true,
          ),
          shortcut,
        ],
      );
      expect(games.single.extra['steamShortcut'], retroDeckUnsignedId);
    });

    test(
      'a name-only shortcut is consumed by the first flatpak game',
      () async {
        // Two flatpak games share the shortcut's display name; without a
        // `FlatpakAppID` the shortcut can only safely take over one of them.
        const nameOnly = SteamShortcut(
          appId: retroDeckUnsignedId,
          name: 'RetroDECK',
        );
        final first = game(id: 'flatpak:one.retrodeck', key: 'one.retrodeck');
        final second = game(id: 'flatpak:two.retrodeck', key: 'two.retrodeck');
        final games = await preferSteamShortcuts([first, second], [nameOnly]);
        expect(games, hasLength(2));
        expect(games[0].extra['launchedViaSteam'], isTrue);
        expect(games[0].command.last, '$retroDeckUnsignedId');
        expect(games[1].extra.containsKey('launchedViaSteam'), isFalse);
        expect(games[1].command, second.command);
      },
    );

    test(
      'an exact flatpak appId match is never consumed by a name match',
      () async {
        final games = await preferSteamShortcuts(
          [game(id: 'flatpak:impostor', key: 'impostor'), game()],
          [shortcut],
        );
        // The impostor shares only the name; the shortcut carries the real
        // flatpak key, so it must reach the genuine game instead.
        expect(games[0].extra.containsKey('launchedViaSteam'), isFalse);
        expect(games[1].extra['steamShortcut'], retroDeckUnsignedId);
      },
    );

    test('nothing matches, nothing changes', () async {
      final original = game(
        name: 'Terraria',
        key: '105600',
        id: 'flatpak:105600',
      );
      final games = await preferSteamShortcuts([original], [shortcut]);
      expect(games.single.command, original.command);
      expect(games.single.extra.containsKey('launchedViaSteam'), isFalse);
    });

    test('no shortcuts at all returns the same list', () async {
      final original = [game()];
      expect(await preferSteamShortcuts(original, const []), same(original));
    });
  });

  group('end to end', () {
    test('discoverAll routes a shortcut match through Steam', () async {
      final games = await discoverAll(
        AppConfig(),
        sources: [
          _FixedSource(SourceKind.flatpak, [game()]),
        ],
        shortcuts: [
          const SteamShortcut(
            appId: retroDeckUnsignedId,
            name: 'RetroDECK',
            flatpakAppId: 'net.retrodeck.retrodeck',
          ),
        ],
      );
      expect(games.single.command.last, '$retroDeckUnsignedId');
      expect(games.single.extra['launchedViaSteam'], isTrue);
    });
  });
}

class _FixedSource implements GameSource {
  _FixedSource(this.kind, this.games);

  @override
  final SourceKind kind;
  final List<Game> games;

  @override
  Future<List<Game>> discover(AppConfig cfg) async => games;
}
