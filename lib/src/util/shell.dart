/// POSIX-ish word splitting, standing in for Python's `shlex`.
library;

/// Split a command line into words, honouring single/double quotes and
/// backslash escapes outside single quotes.
///
/// Inside double quotes only `"` and `\` may be escaped; a backslash before
/// anything else is a literal backslash, as in `shlex` (and in POSIX shells),
/// so `"C:\Program Files"` keeps its backslashes.
List<String> splitShellWords(String line) {
  final words = <String>[];
  final buffer = StringBuffer();
  var hasWord = false;
  var quote = '';
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quote == "'") {
      if (char == "'") {
        quote = '';
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (quote == '"') {
      if (char == '"') {
        quote = '';
      } else if (char == r'\' && i + 1 < line.length) {
        final next = line[i + 1];
        if (next == '"' || next == r'\') {
          i++;
          buffer.write(next);
        } else {
          buffer.write(char);
        }
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      hasWord = true;
      continue;
    }
    if (char == r'\' && i + 1 < line.length) {
      i++;
      buffer.write(line[i]);
      hasWord = true;
      continue;
    }
    if (char == ' ' || char == '\t' || char == '\n' || char == '\r') {
      if (hasWord) {
        words.add(buffer.toString());
        buffer.clear();
        hasWord = false;
      }
      continue;
    }
    buffer.write(char);
    hasWord = true;
  }
  if (hasWord) words.add(buffer.toString());
  return words;
}

/// Shell-quote [argv] for display and for the "copy launch command" action.
String quoteCommand(List<String> argv) => argv.map(_quoteWord).join(' ');

String _quoteWord(String word) {
  if (word.isEmpty) return "''";
  if (RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(word)) return word;
  return "'${word.replaceAll("'", r"'\''")}'";
}
