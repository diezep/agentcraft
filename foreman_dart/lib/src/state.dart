import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

typedef Json = Map<String, dynamic>;
int now() => DateTime.now().millisecondsSinceEpoch;
String text(Json value, String key) {
  final s = value[key];
  if (s is! String || s.trim().isEmpty) {
    throw FormatException('$key must be non-empty text');
  }
  return s;
}

List<Json> rows(Object? value) => (value as List<dynamic>? ?? []).cast<Json>();
String short(String value, [int limit = 2000]) =>
    value.length <= limit ? value : '${value.substring(0, limit)}…';

class StateStore {
  StateStore(String directory) : dir = p.absolute(directory) {
    Directory(dir).createSync(recursive: true);
    _lock = File(p.join(dir, 'profile.lock')).openSync(mode: FileMode.append);
    try {
      _lock.lockSync(FileLock.exclusive);
    } on FileSystemException {
      _lock.closeSync();
      throw StateError('Profile is already in use: $dir');
    }
    try {
      final file = File(p.join(dir, 'state.json'));
      data = file.existsSync()
          ? jsonDecode(file.readAsStringSync()) as Json
          : {
              'version': 1,
              'createdAt': now(),
              'agents': <Json>[],
              'tasks': <Json>[],
              'decisions': <Json>[],
              'repos': <Json>[],
              'goals': <Json>[],
              'feed': <Json>[],
              'memory': <Json>[],
              'messages': <Json>[],
              'sessions': <String, dynamic>{},
              'jobs': <Json>[],
              'logs': <String, dynamic>{},
              'counters': <String, dynamic>{},
            };
      if (data['version'] != 1 || data['jobs'] is! List) {
        throw FormatException('Unsupported Dart profile');
      }
    } on Object {
      _lock.closeSync();
      rethrow; // Never discard a corrupt profile or mistake legacy state for our own.
    }
  }
  final String dir;
  late final RandomAccessFile _lock;
  late final Json data;
  List<Json> list(String key) => rows(data[key]);
  Json? find(String key, String id) {
    for (final row in list(key)) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  String id(String prefix) {
    final counters = data['counters'] as Json;
    final n = (counters[prefix] as int? ?? 0) + 1;
    counters[prefix] = n;
    return '$prefix$n';
  }

  void save() {
    final temp = File(p.join(dir, 'state.json.tmp'));
    temp.writeAsStringSync(jsonEncode(data), flush: true);
    temp.renameSync(p.join(dir, 'state.json'));
  }

  void close() {
    save();
    _lock.closeSync();
  }
}
