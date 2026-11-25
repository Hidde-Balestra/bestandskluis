import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bestandskluis/crypto/vault_crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _data(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Future<List<int>> _collect(Stream<List<int>> s) =>
    s.fold<List<int>>([], (a, b) => a..addAll(b));

void main() {
  late Directory tmp;
  final key = SecretKey(List.generate(32, (i) => i));

  setUp(() async => tmp = await Directory.systemTemp.createTemp('bkv'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<File> encrypt(List<int> plain, {int chunk = 1024}) async {
    final f = File('${tmp.path}/x.bkv');
    await f.writeAsBytes(await _collect(
        VaultCrypto.encryptStream(Stream.value(plain), key, chunkSize: chunk)));
    return f;
  }

  for (final n in [0, 1, 1023, 1024, 1025, 4096, 5000]) {
    test('round-trip $n bytes', () async {
      final plain = _data(n);
      final f = await encrypt(plain);
      expect(await f.length(), VaultCrypto.cipherLength(n, chunkSize: 1024));
      expect(VaultCrypto.plainLength(await f.length(), chunkSize: 1024), n);
      expect(await _collect(VaultCrypto.decryptStream(f, key)), plain);
    });
  }

  test('ontsleutelen vanaf een positie (REST)', () async {
    final plain = _data(5000);
    final f = await encrypt(plain);
    for (final start in [0, 1, 1023, 1024, 3000, 4999, 5000]) {
      expect(await _collect(VaultCrypto.decryptStream(f, key, start: start)),
          plain.sublist(start),
          reason: 'start $start');
    }
  });

  test('stroom in kleine stukjes geeft hetzelfde resultaat', () async {
    final plain = _data(3000);
    final pieces = Stream.fromIterable([
      for (var i = 0; i < plain.length; i += 7)
        plain.sublist(i, min(i + 7, plain.length))
    ]);
    final f = File('${tmp.path}/y.bkv');
    await f.writeAsBytes(await _collect(
        VaultCrypto.encryptStream(pieces, key, chunkSize: 1024)));
    expect(await _collect(VaultCrypto.decryptStream(f, key)), plain);
  });

  test('verkeerde sleutel wordt geweigerd', () async {
    final f = await encrypt(_data(100));
    expect(
        _collect(VaultCrypto.decryptStream(f, SecretKey(List.filled(32, 9)))),
        throwsA(isA<VaultAuthException>()));
  });

  test('gewijzigde byte wordt gedetecteerd', () async {
    final f = await encrypt(_data(2000));
    final bytes = await f.readAsBytes();
    bytes[500] ^= 1;
    await f.writeAsBytes(bytes);
    expect(_collect(VaultCrypto.decryptStream(f, key)),
        throwsA(isA<VaultAuthException>()));
  });

  test('afgekapt bestand op blokgrens wordt gedetecteerd', () async {
    final f = await encrypt(_data(3000));
    final bytes = await f.readAsBytes();
    await f.writeAsBytes(
        bytes.sublist(0, VaultCrypto.headerLength + 2 * (1024 + 16)));
    expect(_collect(VaultCrypto.decryptStream(f, key)),
        throwsA(isA<VaultAuthException>()));
  });

  test('geen kluisbestand', () async {
    final f = File('${tmp.path}/z.bkv')..writeAsBytesSync(_data(100));
    expect(_collect(VaultCrypto.decryptStream(f, key)),
        throwsA(isA<VaultFormatException>()));
  });

  test('encryptFile / decryptFile met standaard blokgrootte', () async {
    final plain = _data(VaultCrypto.defaultChunkSize * 2 + 10);
    final src = File('${tmp.path}/a.jpg')..writeAsBytesSync(plain);
    final enc = File('${tmp.path}/a.jpg.bkv');
    await VaultCrypto.encryptFile(src, enc, key);
    expect(VaultCrypto.plainLength(await enc.length()), plain.length);
    final out = File('${tmp.path}/b.jpg');
    await VaultCrypto.decryptFile(enc, out, key);
    expect(await out.readAsBytes(), plain);
    expect(File('${out.path}.part').existsSync(), isFalse);
  });

  test('namen', () {
    expect(VaultCrypto.isEncryptedName('a.jpg.bkv'), isTrue);
    expect(VaultCrypto.isEncryptedName('.bkv'), isFalse);
    expect(VaultCrypto.plainName('a.jpg.bkv'), 'a.jpg');
    expect(VaultCrypto.encryptedName('a.jpg'), 'a.jpg.bkv');
  });

  test('wachtwoordcontrole', () async {
    final k = await VaultCrypto.deriveKey('geheim', [1, 2, 3, 4], 1000);
    final check = await VaultCrypto.makeCheck(k);
    expect(await VaultCrypto.verifyCheck(k, check), isTrue);
    final wrong = await VaultCrypto.deriveKey('fout', [1, 2, 3, 4], 1000);
    expect(await VaultCrypto.verifyCheck(wrong, check), isFalse);
  });
}
