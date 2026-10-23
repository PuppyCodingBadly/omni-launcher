import 'dart:convert';
import 'dart:io';

/// The last [maxLines] lines of the launcher's launch log at [path].
///
/// At most [maxBytes] are read from the end of the file, so the whole log is
/// never pulled into memory. When the read starts mid-line, that partial line
/// is dropped.
///
/// With a [gameId], the text starts at the last line recording that game's
/// launch (`... launched steam:440 pid=123 :: cmd`), so what follows is the
/// game's own output. Returns the plain tail when that line is not in the
/// window.
///
/// Returns `null` when the file is missing or cannot be read, and `''` when it
/// is empty.
String? readLogTail(
  String path, {
  String? gameId,
  int maxLines = 200,
  int maxBytes = 131072,
}) {
  RandomAccessFile? file;
  try {
    final log = File(path);
    if (!log.existsSync()) return null;
    file = log.openSync();
    final length = file.lengthSync();
    if (length == 0) return '';

    final window = maxBytes < 0 ? 0 : maxBytes;
    if (window == 0) return '';

    final start = length > window ? length - window : 0;
    var startsMidLine = false;
    if (start > 0) {
      // A window that begins just after a newline holds whole lines only.
      file.setPositionSync(start - 1);
      final probe = file.readSync(1);
      startsMidLine = probe.isEmpty || probe.first != 0x0A;
    }

    file.setPositionSync(start);
    var text = utf8.decode(file.readSync(length - start), allowMalformed: true);

    if (startsMidLine) {
      final newline = text.indexOf('\n');
      text = newline < 0 ? '' : text.substring(newline + 1);
    }
    if (text.isEmpty) return '';

    if (gameId != null && gameId.isNotEmpty) {
      final marker = ' launched $gameId ';
      final launched = text.lastIndexOf(marker);
      if (launched >= 0) {
        text = text.substring(text.lastIndexOf('\n', launched) + 1);
      }
    }

    if (maxLines <= 0) return '';
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    if (text.isEmpty) return '';

    final lines = text.split('\n');
    if (lines.length > maxLines) {
      lines.removeRange(0, lines.length - maxLines);
    }
    return lines.join('\n');
  } on FileSystemException {
    return null;
  } finally {
    try {
      file?.closeSync();
    } on FileSystemException {
      // Closing a handle to a file that vanished is not worth reporting.
    }
  }
}
