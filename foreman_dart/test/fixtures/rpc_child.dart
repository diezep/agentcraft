import 'dart:convert';
import 'dart:io';

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final packet = jsonDecode(line) as Map<String, dynamic>;
    if (packet['method'] == 'crash') exit(12);
    if (packet['method'] == 'invalid') {
      stdout.writeln('not json');
      return;
    }
    if (packet['method'] == 'server-request') {
      stdout.writeln(jsonEncode(
          {'id': 'server-1', 'method': 'ask', 'params': <String, dynamic>{}}));
    }
    if (packet.containsKey('method') && packet.containsKey('id')) {
      stdout.writeln(jsonEncode({
        'id': packet['id'],
        'result': {'ok': true}
      }));
    }
  });
}
