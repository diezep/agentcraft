import 'dart:convert';
import 'state.dart';

/// Structured protocol diff, with display limits independent of change counts.
Json parseDiff(String patch, {int maxLines = 5000}) {
  final files = <Json>[];
  Json? file, hunk;
  var oldNo = 0, newNo = 0, oldLeft = 0, newLeft = 0, shown = 0;
  var truncated = false;
  String path(String value, {bool prefix = true}) {
    if (value.startsWith('"')) {
      try {
        value = jsonDecode(value) as String;
      } on FormatException {/* Git octal escaping remains visible. */}
    }
    return prefix ? value.replaceFirst(RegExp(r'^[ab]/'), '') : value;
  }

  for (final line in const LineSplitter().convert(patch)) {
    if (line.startsWith(r'\')) continue;
    if (file != null && hunk != null && (oldLeft > 0 || newLeft > 0)) {
      final kind = line.startsWith('+')
          ? 'add'
          : line.startsWith('-')
              ? 'del'
              : 'ctx';
      final entry = <String, dynamic>{
        'kind': kind,
        'text': line.isEmpty ? '' : line.substring(1)
      };
      if (kind != 'add') {
        entry['oldNo'] = oldNo++;
        oldLeft--;
      }
      if (kind != 'del') {
        entry['newNo'] = newNo++;
        newLeft--;
      }
      if (kind == 'add') file['additions'] = (file['additions'] as int) + 1;
      if (kind == 'del') file['deletions'] = (file['deletions'] as int) + 1;
      if (shown++ < maxLines) {
        rows(hunk['lines']).add(entry);
      } else {
        truncated = true;
      }
      continue;
    }
    if (line.startsWith('diff --git ')) {
      final match =
          RegExp(r'^diff --git (".*?"|a/.*?) (".*?"|b/.*)$').firstMatch(line);
      file = {
        'path': match == null ? '' : path(match[2]!),
        'status': 'modified',
        'binary': false,
        'additions': 0,
        'deletions': 0,
        'hunks': <Json>[]
      };
      files.add(file);
      hunk = null;
      continue;
    }
    if (file == null) continue;
    if (line.startsWith('new file mode')) {
      file['status'] = 'added';
    } else if (line.startsWith('deleted file mode')) {
      file['status'] = 'deleted';
    } else if (line.startsWith('rename from ')) {
      file['status'] = 'renamed';
      file['oldPath'] = path(line.substring(12), prefix: false);
    } else if (line.startsWith('rename to ')) {
      file['path'] = path(line.substring(10), prefix: false);
    } else if (line.startsWith('Binary files ') || line == 'GIT binary patch') {
      file['binary'] = true;
    } else if (line.startsWith('--- ') || line.startsWith('+++ ')) {
      final name = path(line.substring(4));
      if (name != '/dev/null') file['path'] = name;
    } else {
      final match = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
          .firstMatch(line);
      if (match == null) continue;
      oldNo = int.parse(match[1]!);
      oldLeft = int.parse(match[2] ?? '1');
      newNo = int.parse(match[3]!);
      newLeft = int.parse(match[4] ?? '1');
      hunk = {
        'header': line,
        'oldStart': oldNo,
        'oldLines': oldLeft,
        'newStart': newNo,
        'newLines': newLeft,
        'lines': <Json>[]
      };
      rows(file['hunks']).add(hunk);
    }
  }
  return {'files': files, 'truncated': truncated};
}
