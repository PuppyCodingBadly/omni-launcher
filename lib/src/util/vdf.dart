/// Minimal Valve KeyValues parser (libraryfolders.vdf, appmanifest_*.acf).
library;

final RegExp _token = RegExp(r'\s*(?:"((?:[^"\\]|\\.)*)"|([{}])|//[^\n]*)');

Map<String, Object?> parseKeyValues(String text) {
  final tokens = <String>[];
  var pos = 0;
  // A UTF-8 BOM is not part of the grammar.
  if (text.startsWith('\uFEFF')) pos = 1;
  while (pos < text.length) {
    final match = _token.matchAsPrefix(text, pos);
    if (match == null) {
      if (text[pos] == '[') {
        // A KeyValues conditional tag such as `[$WIN32]` or `[!$X360]`
        // following a value: the platform filter is not evaluated, the tag is
        // simply skipped.
        final close = text.indexOf(']', pos);
        pos = close < 0 ? text.length : close + 1;
      } else {
        // Anything else the grammar does not know is skipped a byte at a time
        // rather than aborting the whole parse.
        pos++;
      }
      continue;
    }
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
