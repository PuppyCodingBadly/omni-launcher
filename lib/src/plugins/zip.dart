/// Reading the zip archives the plugin store hands out.
///
/// Only what a plugin archive needs: stored and deflated entries, no
/// encryption, no zip64. Everything else is refused, and no entry may leave the
/// folder it is unpacked into — an archive from a catalogue is still an archive
/// from somewhere else.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The largest archive the store will take.
const int maxArchiveBytes = 8 * 1024 * 1024;

/// The most an archive may unpack to, in total.
const int maxPluginBytes = 4 * 1024 * 1024;

/// The most files an archive may hold.
const int maxPluginEntries = 64;

const int _endOfCentralDirectory = 0x06054b50;
const int _centralFileHeader = 0x02014b50;
const int _localFileHeader = 0x04034b50;

/// Unpack the zip in [bytes] into [target], creating the folder if it is not
/// there yet.
///
/// Throws [FormatException] with a reason when the archive is not one this
/// launcher will unpack.
void unpackZip(List<int> bytes, String target) {
  if (bytes.length > maxArchiveBytes) {
    throw FormatException(
      'the archive is larger than ${maxArchiveBytes ~/ (1024 * 1024)} MiB',
    );
  }
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final entries = _centralDirectory(data);
  final root = Directory(target)..createSync(recursive: true);
  var total = 0;
  for (final entry in entries) {
    final path = _inside(root.path, entry.name);
    if (entry.isDirectory) {
      Directory(path).createSync(recursive: true);
      continue;
    }
    if (entry.isSpecial) {
      throw FormatException(
        'the archive holds something that is not a file: ${entry.name}',
      );
    }
    // The budget is what is left of the limit; what an entry claims is only
    // believed once its bytes are counted on the way out of the inflater.
    final content = _content(data, entry, maxPluginBytes - total);
    total += content.length;
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(content);
  }
}

/// The entries the archive's central directory lists.
///
/// The central directory is what an unpacker has to believe: a local header can
/// leave its sizes out, and a second copy of it can say anything.
List<_Entry> _centralDirectory(Uint8List data) {
  final end = _findEndOfCentralDirectory(data);
  final count = _u16(data, end + 10);
  final size = _u32(data, end + 12);
  final offset = _u32(data, end + 16);
  // Zip64 hides the real numbers behind a record this does not read.
  if (count == 0xffff || size == 0xffffffff || offset == 0xffffffff) {
    throw const FormatException('the archive is zip64, which is not supported');
  }
  if (count > maxPluginEntries) {
    throw FormatException(
      'the archive holds more than $maxPluginEntries files',
    );
  }
  if (offset + size > data.length) {
    throw const FormatException('the archive is truncated');
  }

  final entries = <_Entry>[];
  var cursor = offset;
  for (var index = 0; index < count; index++) {
    if (cursor + 46 > data.length || _u32(data, cursor) != _centralFileHeader) {
      throw const FormatException('the archive\'s index of files is damaged');
    }
    final flags = _u16(data, cursor + 8);
    final method = _u16(data, cursor + 10);
    final compressed = _u32(data, cursor + 20);
    final unpacked = _u32(data, cursor + 24);
    final nameLength = _u16(data, cursor + 28);
    final extraLength = _u16(data, cursor + 30);
    final commentLength = _u16(data, cursor + 32);
    final mode = _u32(data, cursor + 38) >> 16;
    final local = _u32(data, cursor + 42);
    // The entry's own lengths must fit in what is left of the archive, or the
    // name read below would run off the end of the data.
    if (cursor + 46 + nameLength + extraLength + commentLength > data.length) {
      throw const FormatException('the archive\'s index of files is damaged');
    }
    if (flags & 0x1 != 0) {
      throw const FormatException('the archive is encrypted');
    }
    if (method != 0 && method != 8) {
      throw FormatException(
        'the archive is compressed in a way this cannot read (method $method)',
      );
    }
    final raw = data.sublist(cursor + 46, cursor + 46 + nameLength);
    final name = flags & 0x800 != 0 ? utf8.decode(raw) : latin1.decode(raw);
    if (name.isEmpty) {
      throw const FormatException('the archive holds an entry with no name');
    }
    entries.add(
      _Entry(
        name: name,
        method: method,
        compressed: compressed,
        size: unpacked,
        offset: local,
        // A symlink or a device node is not a plugin file.
        mode: mode,
      ),
    );
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

/// Where the end of central directory record starts.
int _findEndOfCentralDirectory(Uint8List data) {
  final earliest = data.length - 22 - 0xffff < 0
      ? 0
      : data.length - 22 - 0xffff;
  for (var cursor = data.length - 22; cursor >= earliest; cursor--) {
    if (_u32(data, cursor) == _endOfCentralDirectory) return cursor;
  }
  throw const FormatException('this is not a zip archive');
}

/// The bytes of [entry], inflated where it has to be.
///
/// The inflater is fed in slices and its output counted as it arrives: an
/// archive that lies about a size — kilobytes that inflate to gigabytes — is
/// refused the moment it passes what it claimed, or what is left of [budget],
/// rather than after the memory is gone.
Uint8List _content(Uint8List data, _Entry entry, int budget) {
  if (entry.offset + 30 > data.length ||
      _u32(data, entry.offset) != _localFileHeader) {
    throw const FormatException('the archive\'s index points at nothing');
  }
  final start =
      entry.offset +
      30 +
      _u16(data, entry.offset + 26) +
      _u16(data, entry.offset + 28);
  if (start + entry.compressed > data.length) {
    throw const FormatException('the archive is truncated');
  }
  final raw = data.sublist(start, start + entry.compressed);
  if (entry.method == 0) {
    if (raw.length != entry.size) {
      throw const FormatException(
        'a file in the archive is not the size it claims',
      );
    }
    if (raw.length > budget) throw _tooBig();
    return raw;
  }
  if (entry.size > budget) throw _tooBig();
  final sink = _InflateSink(entry.size);
  final inflater = ZLibDecoder(raw: true).startChunkedConversion(sink);
  try {
    const slice = 64 * 1024;
    for (var at = 0; at < raw.length; at += slice) {
      final end = at + slice > raw.length ? raw.length : at + slice;
      inflater.add(raw.sublist(at, end));
    }
    inflater.close();
  } on _InflateOverflow {
    throw const FormatException(
      'a file in the archive inflates past the size it claims',
    );
  } on Exception {
    // zlib reports bad data as a FormatException; anything else it throws is
    // no better a reason to trust the archive.
    throw const FormatException('a file in the archive is not deflated data');
  }
  final unpacked = sink.bytes.takeBytes();
  if (unpacked.length != entry.size) {
    throw const FormatException(
      'a file in the archive is not the size it claims',
    );
  }
  return unpacked;
}

/// The "unpacks to too much" complaint.
FormatException _tooBig() => FormatException(
  'the archive unpacks to more than ${maxPluginBytes ~/ (1024 * 1024)} MiB',
);

/// Counts inflated bytes as they leave zlib and balks the moment there are
/// more than the entry claimed.
///
/// Throwing out of the sink stops the inflater in the middle of a slice, so a
/// bomb is refused after kilobytes of output, not after gigabytes.
class _InflateSink implements ChunkedConversionSink<List<int>> {
  _InflateSink(this.claimed);

  /// The size the archive's index states; no entry may inflate past it.
  final int claimed;

  final BytesBuilder bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    bytes.add(chunk);
    if (bytes.length > claimed) throw const _InflateOverflow();
  }

  @override
  void close() {}
}

class _InflateOverflow implements Exception {
  const _InflateOverflow();
}

/// [name] as a path inside [root], or a complaint.
String _inside(String root, String name) {
  final cleaned = name.replaceAll('\\', '/');
  if (cleaned.startsWith('/') || cleaned.contains(':')) {
    throw FormatException('the archive holds an absolute path: $name');
  }
  final parts = <String>[];
  for (final part in cleaned.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      throw FormatException('the archive reaches outside its folder: $name');
    }
    if (part.contains('\u0000')) {
      throw FormatException('the archive holds a strange name: $name');
    }
    parts.add(part);
  }
  if (parts.isEmpty) {
    throw FormatException('the archive holds an entry with no name: $name');
  }
  return '$root/${parts.join('/')}';
}

int _u16(Uint8List data, int at) => data[at] | data[at + 1] << 8;

int _u32(Uint8List data, int at) =>
    data[at] | data[at + 1] << 8 | data[at + 2] << 16 | data[at + 3] << 24;

class _Entry {
  const _Entry({
    required this.name,
    required this.method,
    required this.compressed,
    required this.size,
    required this.offset,
    required this.mode,
  });

  final String name;
  final int method;
  final int compressed;
  final int size;
  final int offset;

  /// The file's unix mode, which says whether it is a plain file.
  final int mode;

  bool get isDirectory => name.endsWith('/') || mode & 0xf000 == 0x4000;

  /// True for a symlink, a device or a fifo: none of which a plugin needs.
  bool get isSpecial =>
      mode & 0xf000 != 0 && mode & 0xf000 != 0x8000 && !isDirectory;
}
