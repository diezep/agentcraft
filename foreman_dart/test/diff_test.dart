import 'package:agentcraft_dart/src/diff.dart';
import 'package:agentcraft_dart/src/state.dart';
import 'package:test/test.dart';

void main() {
  test('diff preserves line numbers, header-like content, and truncation', () {
    final result = parseDiff(
        'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n same\n--- old\n+++ new\n',
        maxLines: 2);
    final f = rows(result['files']).single;
    expect(f['path'], 'a.txt');
    expect(f['additions'], 1);
    expect(f['deletions'], 1);
    expect(result['truncated'], true);
    expect(rows(rows(f['hunks']).single['lines']).last,
        {'kind': 'del', 'text': '-- old', 'oldNo': 2});
  });
  test('binary rename without hunks remains visible', () {
    final f = rows(parseDiff(
                'diff --git a/old b/new\nrename from old\nrename to new\nBinary files a/old and b/new differ\n')[
            'files'])
        .single;
    expect(f['status'], 'renamed');
    expect(f['binary'], true);
    expect(f['oldPath'], 'old');
  });
}
