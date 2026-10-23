import 'dart:convert';
import 'dart:ffi';

// Lutris keeps a game's categories in its SQLite database (`pga.db`), not in
// the per-game YAML: the YAML only says what the installer was told. Reading
// the database directly needs SQLite and the launcher ships no third-party
// dependencies, so the few functions needed are called through dart:ffi.

/// Returned by `sqlite3_step` while there are rows left.
const int _sqliteRow = 100;

/// `SQLITE_OPEN_READONLY`.
const int _sqliteOpenReadonly = 1;

/// Columns are NUL terminated, but a corrupt database must not walk off the
/// end of memory forever.
const int _maxCString = 64 * 1024;

/// The slug -> category names map of the Lutris databases at [dbPaths].
///
/// A native install, the flatpak and a hand-made copy can all be there and
/// they describe the same games, so every readable database is folded into one
/// map. Any failure - no `libsqlite3`, no database, no table - yields an empty
/// map rather than an exception: the games are still worth listing without
/// tags.
Future<Map<String, Set<String>>> lutrisCategoryTags(
  List<String> dbPaths,
) async {
  final tags = <String, Set<String>>{};
  final library = _openLibrary();
  if (library == null) return tags;
  final api = _SqliteApi.open(library);
  if (api == null) return tags;
  for (final path in dbPaths) {
    final found = api.read(path);
    for (final entry in found.entries) {
      tags.putIfAbsent(entry.key, () => <String>{}).addAll(entry.value);
    }
  }
  return tags;
}

/// `libsqlite3.so.0` is what the runtime package provides; the bare name is
/// the development package's link.
DynamicLibrary? _openLibrary() {
  for (final name in const ['libsqlite3.so.0', 'libsqlite3.so']) {
    try {
      return DynamicLibrary.open(name);
    } on ArgumentError {
      continue;
    }
  }
  return null;
}

typedef _OpenNative = Int32 Function(
  Pointer<Uint8>,
  Pointer<Pointer<Void>>,
  Int32,
  Pointer<Uint8>,
);
typedef _OpenDart = int Function(
  Pointer<Uint8>,
  Pointer<Pointer<Void>>,
  int,
  Pointer<Uint8>,
);

typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);

typedef _PrepareNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Int32,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
);
typedef _PrepareDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
);

typedef _StepNative = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);

typedef _ColumnTextNative = Pointer<Uint8> Function(Pointer<Void>, Int32);
typedef _ColumnTextDart = Pointer<Uint8> Function(Pointer<Void>, int);

typedef _FinalizeNative = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);

typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

/// The handful of SQLite entry points this reader needs.
///
/// Strings handed to SQLite are allocated with `sqlite3_malloc` and released
/// with `sqlite3_free`, so no libc lookup is needed on top of the database's
/// own library.
class _SqliteApi {
  _SqliteApi(
    this._open,
    this._close,
    this._prepare,
    this._step,
    this._columnText,
    this._finalize,
    this._malloc,
    this._free,
  );

  static _SqliteApi? open(DynamicLibrary library) {
    try {
      return _SqliteApi(
        library.lookupFunction<_OpenNative, _OpenDart>('sqlite3_open_v2'),
        library.lookupFunction<_CloseNative, _CloseDart>('sqlite3_close'),
        library.lookupFunction<_PrepareNative, _PrepareDart>(
          'sqlite3_prepare_v2',
        ),
        library.lookupFunction<_StepNative, _StepDart>('sqlite3_step'),
        library.lookupFunction<_ColumnTextNative, _ColumnTextDart>(
          'sqlite3_column_text',
        ),
        library.lookupFunction<_FinalizeNative, _FinalizeDart>(
          'sqlite3_finalize',
        ),
        library.lookupFunction<_MallocNative, _MallocDart>('sqlite3_malloc'),
        library.lookupFunction<_FreeNative, _FreeDart>('sqlite3_free'),
      );
    } on ArgumentError {
      return null;
    }
  }

  final _OpenDart _open;
  final _CloseDart _close;
  final _PrepareDart _prepare;
  final _StepDart _step;
  final _ColumnTextDart _columnText;
  final _FinalizeDart _finalize;
  final _MallocDart _malloc;
  final _FreeDart _free;

  /// Slug -> category names from one database, or an empty map when it cannot
  /// be read. Nothing here throws: a database belongs to another program and
  /// may be missing, empty or mid-write.
  Map<String, Set<String>> read(String path) {
    final tags = <String, Set<String>>{};
    final pathPtr = _string(path);
    final sqlPtr = _string(_query);
    final db = _malloc(sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
    Pointer<Void> handle = nullptr;
    try {
      if (pathPtr == null || sqlPtr == null || db == nullptr) return tags;
      db.value = nullptr;
      // A failed open can still hand back a connection object to close.
      _open(pathPtr, db, _sqliteOpenReadonly, nullptr);
      handle = db.value;
      if (handle == nullptr) return tags;
      final statementPtr = _malloc(sizeOf<Pointer<Void>>())
          .cast<Pointer<Void>>();
      if (statementPtr == nullptr) return tags;
      try {
        statementPtr.value = nullptr;
        if (_prepare(handle, sqlPtr, -1, statementPtr, nullptr) != 0) {
          return tags;
        }
        final statement = statementPtr.value;
        if (statement == nullptr) return tags;
        while (_step(statement) == _sqliteRow) {
          final slug = _readString(_columnText(statement, 0));
          final name = _readString(_columnText(statement, 1));
          if (slug.trim().isEmpty || name.trim().isEmpty) continue;
          tags.putIfAbsent(slug, () => <String>{}).add(name);
        }
      } finally {
        // The statement has to be finalized before its connection closes.
        if (statementPtr.value != nullptr) _finalize(statementPtr.value);
        _free(statementPtr.cast<Uint8>());
      }
    } finally {
      if (handle != nullptr) _close(handle);
      if (pathPtr != null) _free(pathPtr);
      if (sqlPtr != null) _free(sqlPtr);
      if (db != nullptr) _free(db.cast<Uint8>());
    }
    return tags;
  }

  /// A NUL terminated copy of [value], owned by the caller of SQLite.
  Pointer<Uint8>? _string(String value) {
    final bytes = utf8.encode(value);
    final ptr = _malloc(bytes.length + 1);
    if (ptr == nullptr) return null;
    final view = ptr.asTypedList(bytes.length + 1);
    view.setRange(0, bytes.length, bytes);
    view[bytes.length] = 0;
    return ptr;
  }

  String _readString(Pointer<Uint8> ptr) {
    if (ptr == nullptr) return '';
    final bytes = <int>[];
    for (var i = 0; i < _maxCString; i++) {
      final byte = ptr[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// Games and their category names; both sides are filtered so the INNER JOIN
/// cannot hand back a null in the first place.
const String _query =
    'SELECT games.slug, categories.name FROM games '
    'INNER JOIN games_categories '
    'ON games.id = games_categories.game_id '
    'INNER JOIN categories ON categories.id = '
    'games_categories.category_id '
    'WHERE games.slug IS NOT NULL AND categories.name IS NOT NULL';
