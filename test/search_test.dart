import 'package:flutter_test/flutter_test.dart';
import 'package:omni_launcher/src/model/game.dart';
import 'package:omni_launcher/src/util/search.dart';

Game game({
  String name = 'Game',
  String id = 'steam:1',
  SourceKind source = SourceKind.steam,
  List<String> command = const [],
  String? path,
  String? subtitle,
  Map<String, Object?> extra = const {},
}) => Game(
  id: id,
  name: name,
  source: source,
  command: command,
  path: path,
  subtitle: subtitle,
  extra: extra,
);

void main() {
  group('the search score', () {
    test('finds a substring inside a word', () {
      final portal = game(name: 'Portal 2');

      expect(gameSearchScore(portal, 'tal'), 150);
    });

    test('ranks a name prefix above a path prefix', () {
      final byName = game(name: 'Portal 2');
      final byPath = game(
        name: 'Something Else',
        id: 'manual:2',
        source: SourceKind.manual,
        path: '/games/portal2',
      );

      expect(gameSearchScore(byName, 'portal'), 240);
      // The path's words start with "portal", but the path itself does not.
      expect(gameSearchScore(byPath, 'portal'), 70);
      expect(
        gameSearchScore(byName, 'portal')!,
        greaterThan(gameSearchScore(byPath, 'portal')!),
      );
    });

    test('matches an acronym above a path prefix', () {
      final teamFortress = game(name: 'Team Fortress 2', id: 'steam:440');

      // 40 x 3 for the acronym, plus 60 for the whole query being the
      // initials of the name.
      expect(gameSearchScore(teamFortress, 'tf2'), 180);
    });

    test('matches a subsequence for words of three letters or more', () {
      final accounting = game(
        name: 'Accounting',
        id: 'manual:accounting',
        source: SourceKind.manual,
      );

      expect(gameSearchScore(accounting, 'accntg'), 60);
    });

    test('matches tags', () {
      final hades = game(name: 'Hades');

      expect(gameSearchScore(hades, 'rogue', tags: const ['Roguelike']), 160);
      expect(gameSearchScore(hades, 'rogue'), isNull);
    });

    test('matches the source of the game', () {
      final widget = game(name: 'Widget', subtitle: 'Utility', id: 'steam:1');

      // The source label matches exactly; the best field wins for one word.
      expect(gameSearchScore(widget, 'steam'), 200);
    });

    test('returns null when a word matches nothing', () {
      final portal = game(name: 'Portal 2');

      expect(gameSearchScore(portal, 'zzz'), isNull);
      expect(gameSearchScore(portal, 'portal zzz'), isNull);
    });

    test('returns 0 for an empty or blank query', () {
      final portal = game(name: 'Portal 2');

      expect(gameSearchScore(portal, ''), 0);
      expect(gameSearchScore(portal, '   '), 0);
    });
  });
}
