import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One file in a test archive.
class Entry {
  const Entry(this.name, this.content, {this.mode = 0x81a4, this.method = 8});

  final String name;
  final String content;

  /// The unix mode the entry claims; 0x81a4 is a plain file, 0xa1ff a symlink.
  final int mode;

  /// 8 is deflate, 0 is stored.
  final int method;
}

/// A zip archive, built here so the reader and the installer can be shown the
/// shapes an unpacker has to survive. Real archives are made by
/// `plugins/build.sh`.
Uint8List archive(List<Entry> files, {int flags = 0, int? centralFlags}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final file in files) {
    final name = utf8.encode(file.name);
    final raw = utf8.encode(file.content);
    final data = file.method == 0 ? raw : ZLibCodec(raw: true).encode(raw);
    final offset = out.length;
    out.add(_u32(0x04034b50));
    out.add(_u16(20));
    out.add(_u16(flags));
    out.add(_u16(file.method));
    out.add(_u16(0));
    out.add(_u16(0));
    out.add(_u32(0));
    out.add(_u32(data.length));
    out.add(_u32(raw.length));
    out.add(_u16(name.length));
    out.add(_u16(0));
    out.add(name);
    out.add(data);

    central.add(_u32(0x02014b50));
    central.add(_u16(0x031e));
    central.add(_u16(20));
    central.add(_u16(centralFlags ?? flags));
    central.add(_u16(file.method));
    central.add(_u16(0));
    central.add(_u16(0));
    central.add(_u32(0));
    central.add(_u32(data.length));
    central.add(_u32(raw.length));
    central.add(_u16(name.length));
    central.add(_u16(0));
    central.add(_u16(0));
    central.add(_u16(0));
    central.add(_u16(0));
    central.add(_u32(file.mode << 16));
    central.add(_u32(offset));
    central.add(name);
  }
  final start = out.length;
  out.add(central.takeBytes());
  out.add(_u32(0x06054b50));
  out.add(_u16(0));
  out.add(_u16(0));
  out.add(_u16(files.length));
  out.add(_u16(files.length));
  out.add(_u32(out.length - start));
  out.add(_u32(start));
  out.add(_u16(0));
  return out.takeBytes();
}

List<int> _u16(int value) => [value & 0xff, value >> 8 & 0xff];

List<int> _u32(int value) =>
    [value & 0xff, value >> 8 & 0xff, value >> 16 & 0xff, value >> 24 & 0xff];
