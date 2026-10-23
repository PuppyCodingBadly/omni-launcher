import '../model/game.dart';

/// Score [game] against a free text [query], higher being a better match.
///
/// The query is split on whitespace and matched case-insensitively; every word
/// must match at least one field, otherwise the result is `null`. An empty or
/// blank query scores 0.
///
/// A word matches the best of: the whole field (100), a prefix of the field
/// (80), a prefix of one of its words (70), a substring (50), the initials of
/// the name or subtitle (40), or a subsequence of a name, subtitle or id (20,
/// only for words of at least three characters). The score is multiplied by
/// the field's weight; the whole query also earns a bonus when it spells out
/// the initials of the name or subtitle.
///
/// [tags] are the game's tags, scored like the built-in fields.
int? gameSearchScore(
  Game game,
  String query, {
  Iterable<String> tags = const [],
}) {
  final tokens = _tokens(query);
  if (tokens.isEmpty) return 0;

  final fields = _fields(game, tags);
  var total = 0;
  for (final token in tokens) {
    final score = _bestTokenScore(token, fields);
    if (score == null) return null;
    total += score;
  }
  return total + _wholeQueryAcronymBonus(query, fields);
}

/// The lowercase, whitespace separated words of [query].
List<String> _tokens(String query) => [
  for (final word in query.toLowerCase().split(_whitespace))
    if (word.isNotEmpty) word,
];

int? _bestTokenScore(String token, List<_Field> fields) {
  var best = 0;
  for (final field in fields) {
    final score = field.score(token);
    if (score > best) best = score;
  }
  return best == 0 ? null : best;
}

/// The whole query, stripped to letters and digits, matched against the
/// initials of the name or subtitle: "tf 2" and "tf2" both spell "Team
/// Fortress 2" and earn an extra 60.
int _wholeQueryAcronymBonus(String query, List<_Field> fields) {
  final compact = _compact(query);
  if (compact.isEmpty) return 0;
  for (final field in fields) {
    if (field.acronym && field.initials == compact) return 60;
  }
  return 0;
}

List<_Field> _fields(Game game, Iterable<String> tags) {
  final fields = <_Field>[
    _Field(game.name, 3, acronym: true, subsequence: true),
    _Field(game.displaySubtitle, 2, acronym: true, subsequence: true),
    _Field(game.source.label, 2),
    _Field(game.source.id, 2),
    _Field(game.id, 2, subsequence: true),
  ];
  for (final tag in tags) {
    fields.add(_Field(tag, 2));
  }
  final path = game.path;
  if (path != null) fields.add(_Field(path, 1));
  if (game.command.isNotEmpty) fields.add(_Field(game.command.join(' '), 1));
  final store = game.extra['store'];
  if (store != null) fields.add(_Field('$store', 1));
  fields.removeWhere((field) => field.text.isEmpty);
  return fields;
}

final _whitespace = RegExp(r'\s+');
final _nonAlphanumeric = RegExp(r'[^a-z0-9]+');

String _compact(String value) =>
    value.toLowerCase().replaceAll(_nonAlphanumeric, '');

/// One searchable string of a game, with its words and initials worked out
/// once so every query word can be scored against it cheaply.
class _Field {
  _Field(
    String text,
    this.weight, {
    this.acronym = false,
    this.subsequence = false,
  }) : text = text.toLowerCase();

  final String text;
  final int weight;

  /// Whether the initials of this field can be matched as an acronym.
  final bool acronym;

  /// Whether a query word may match as a subsequence of this field.
  final bool subsequence;

  late final List<String> words = [
    for (final word in text.split(_nonAlphanumeric))
      if (word.isNotEmpty) word,
  ];

  late final String initials = words.map((word) => word[0]).join();

  /// How well one lowercase query word matches this field, 0 for no match.
  int score(String token) {
    if (text == token) return 100 * weight;
    if (text.startsWith(token)) return 80 * weight;
    for (final word in words) {
      if (word.startsWith(token)) return 70 * weight;
    }
    if (text.contains(token)) return 50 * weight;
    if (acronym) {
      final compact = _compact(token);
      if (compact.isNotEmpty && compact == initials) return 40 * weight;
    }
    if (subsequence && token.length >= 3 && _isSubsequence(token, text)) {
      return 20 * weight;
    }
    return 0;
  }
}

/// Whether the letters of [needle] appear in [haystack] in order.
bool _isSubsequence(String needle, String haystack) {
  var matched = 0;
  for (var i = 0; i < haystack.length && matched < needle.length; i++) {
    if (haystack.codeUnitAt(i) == needle.codeUnitAt(matched)) matched++;
  }
  return matched == needle.length;
}
