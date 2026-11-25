import 'package:bestandskluis/ftp/ftp_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unix-regel heen en terug', () {
    final now = DateTime(2026, 11, 25, 12);
    final t = DateTime(2026, 11, 20, 9, 5);
    final line = unixListLine('mijn foto.jpg', false, 1234, t, now);
    final e = parseUnixListLine(line, now: now)!;
    expect(e.name, 'mijn foto.jpg');
    expect(e.size, 1234);
    expect(e.isDir, isFalse);
    expect(e.modified, t);
    final old = parseUnixListLine(
        unixListLine('map', true, 0, DateTime(2020, 3, 4), now),
        now: now)!;
    expect(old.isDir, isTrue);
    expect(old.modified, DateTime(2020, 3, 4));
  });

  test('MLSD heen en terug', () {
    final t = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final e = parseMlsdLine(mlsxFacts('a b.txt', false, 42, t))!;
    expect(e.name, 'a b.txt');
    expect(e.size, 42);
    expect(e.modified!.toUtc(), t);
    expect(parseMlsdLine('type=cdir; .'), isNull);
    expect(mdtm(t), '20260102030405');
  });
}
