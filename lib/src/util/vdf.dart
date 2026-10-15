/// Minimal Valve KeyValues parser (libraryfolders.vdf, appmanifest_*.acf).
library;

final RegExp _token = RegExp(r'\s*(?:"((?:[^"\\]|\\.)*)"|([{}])|//[^\n]*)');

Map<String, Object?> parseKeyValues(String text) {
  final tokens = <String>[];
  var pos = 0;
  while (pos < text.length) {
    final match = _token.matchAsPrefix(text, pos);
    if (match == null) break;
    pos = match.end;
    final quoted = match.group(1);
    if (quoted != null) {
      tokens.add(quoted.replaceAll(r'\"', '"').replaceAll(r'\\', r'\'));
    } else if (match.group(2) != null) {
      tokens.add(match.group(2)!);
    }
  }

  var index = 0;

  Map<String, Object?> block() {
    final result = <String, Object?>{};
    while (index < tokens.length) {
      final token = tokens[index];
      if (token == '}') {
        index++;
        return result;
      }
      if (token == '{') {
        index++;
        continue;
      }
      index++;
      if (index < tokens.length && tokens[index] == '{') {
        index++;
        result[token] = block();
      } else if (index < tokens.length) {
        result[token] = tokens[index];
        index++;
      } else {
        result[token] = '';
      }
    }
    return result;
  }

  return block();
}
