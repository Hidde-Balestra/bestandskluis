import 'dart:convert';
import 'dart:io';

import 'package:bestandskluis/crypto/vault_crypto.dart';
import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:bestandskluis/ftp/ftp_client.dart';
import 'package:bestandskluis/ftp/ftp_server.dart';
import 'package:bestandskluis/services/file_ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late VaultManager vm;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('v2');
    vm = VaultManager(iterations: 1000);
  });
  tearDown(() async => tmp.delete(recursive: true));

  Directory dir(String name) =>
      Directory(p.join(tmp.path, name))..createSync(recursive: true);
  List<String> names(Directory d) =>
      d.listSync().map((e) => p.basename(e.path)).toList()..sort();

  group('versleutelde namen', () {
    test('namen zijn onleesbaar op schijf en leesbaar met sleutel', () async {
      final d = dir('k');
      File(p.join(d.path, 'vakantie foto.jpg')).writeAsStringSync('x');
      await vm.create(d.path, 'pw', encryptNames: true);
      final onDisk = names(d).where((n) => !n.startsWith('.')).single;
      expect(onDisk, endsWith(VaultCrypto.nameExtension));
      expect(onDisk, isNot(contains('vakantie')));

      final key = vm.keyFor(d.path)!;
      expect(VaultCrypto.plainName(onDisk, key), 'vakantie foto.jpg');
      // Deterministisch: dezelfde naam geeft dezelfde bestandsnaam.
      expect(VaultCrypto.encryptedName('vakantie foto.jpg', key), onDisk);
      // Zonder sleutel blijft de naam onleesbaar.
      expect(VaultCrypto.plainName(onDisk), onDisk);
      expect((await vm.info(d.path)).encryptedNames, isTrue);

      // Na opnieuw ontgrendelen nog steeds leesbaar.
      vm.lockAll();
      expect(await vm.unlock(d.path, 'pw'), isTrue);
      expect(VaultCrypto.plainName(onDisk, vm.keyFor(d.path)),
          'vakantie foto.jpg');
    });

    test('dubbele namen krijgen een volgnummer', () async {
      final d = dir('k');
      await vm.create(d.path, 'pw', encryptNames: true);
      final key = vm.keyFor(d.path)!;
      final src = dir('src');
      final f = File(p.join(src.path, 'a.txt'))..writeAsStringSync('1');
      await VaultManager.encryptInto(f, d.path, key);
      await VaultManager.encryptInto(f, d.path, key);
      final plain = names(d)
          .where((n) => !n.startsWith('.'))
          .map((n) => VaultCrypto.plainName(n, key))
          .toList()
        ..sort();
      expect(plain, ['a (1).txt', 'a.txt']);
    });

    test('kopiëren, hernoemen en opheffen', () async {
      final d = dir('k');
      await vm.create(d.path, 'pw', encryptNames: true);
      final ops = FileOps(vm);
      final src = dir('src');
      final f = File(p.join(src.path, 'doc.pdf'))..writeAsStringSync('pdf');
      await ops.transfer([f], d.path, move: true);
      final key = vm.keyFor(d.path)!;
      final enc = File(p.join(d.path, VaultCrypto.encryptedName('doc.pdf', key)));
      expect(enc.existsSync(), isTrue);

      await ops.rename(enc, 'nieuw.pdf');
      final renamed =
          File(p.join(d.path, VaultCrypto.encryptedName('nieuw.pdf', key)));
      expect(renamed.existsSync(), isTrue);

      await ops.transfer([renamed], src.path, move: false);
      expect(File(p.join(src.path, 'nieuw.pdf')).readAsStringSync(), 'pdf');

      await vm.removeVault(d.path);
      expect(File(p.join(d.path, 'nieuw.pdf')).readAsStringSync(), 'pdf');
    });

    test('te lange naam wordt geweigerd', () async {
      final d = dir('k');
      await vm.create(d.path, 'pw', encryptNames: true);
      expect(() => VaultCrypto.encryptedName('${'x' * 200}.txt', vm.keyFor(d.path)),
          throwsStateError);
    });

    test('FTP toont en accepteert leesbare namen', () async {
      final root = dir('root');
      final k = Directory(p.join(root.path, 'Kluis'))..createSync();
      File(p.join(k.path, 'geheim.txt')).writeAsStringSync('Geheim!');
      await vm.create(k.path, 'pw', encryptNames: true);
      final server = FtpServer(
          config: FtpServerConfig(
              rootPath: root.path, port: 0, username: 'u', password: 'p'),
          vaults: vm,
          bindAddress: InternetAddress.loopbackIPv4);
      await server.start();
      final c = await FtpClient.connect('127.0.0.1',
          port: server.port, user: 'u', password: 'p');
      try {
        final list = await c.list('/Kluis');
        expect(list.map((e) => e.name), ['geheim.txt']);
        final out = File(p.join(tmp.path, 'dl.txt'));
        await c.download('/Kluis/geheim.txt', out);
        expect(out.readAsStringSync(), 'Geheim!');

        final up = File(p.join(tmp.path, 'up.txt'))..writeAsStringSync('nieuw');
        await c.upload(up, '/Kluis/upload.txt');
        expect(names(k).any((n) => n.contains('upload')), isFalse);
        await c.rename('/Kluis/upload.txt', '/Kluis/hernoemd.txt');
        expect((await c.list('/Kluis')).map((e) => e.name).toList()..sort(),
            ['geheim.txt', 'hernoemd.txt']);

        vm.lockAll();
        final locked = await c.list('/Kluis');
        expect(locked.every((e) => e.name.endsWith('.bkx')), isTrue);
      } finally {
        await c.quit();
        await server.dispose();
      }
    });
  });

  group('wachtwoord en herstelcode', () {
    test('wachtwoord wijzigen zonder bestanden opnieuw te versleutelen',
        () async {
      final d = dir('k');
      final f = File(p.join(d.path, 'a.txt'))..writeAsStringSync('inhoud');
      await vm.create(d.path, 'oud');
      final enc = File('${f.path}${VaultCrypto.extension}');
      final before = enc.readAsBytesSync();

      await vm.changePassword(d.path, 'nieuw');
      vm.lockAll();
      expect(await vm.unlock(d.path, 'oud'), isFalse);
      expect(await vm.unlock(d.path, 'nieuw'), isTrue);
      expect(enc.readAsBytesSync(), before);
      final out = File(p.join(tmp.path, 'out.txt'));
      await VaultCrypto.decryptFile(enc, out, vm.keyFor(d.path)!);
      expect(out.readAsStringSync(), 'inhoud');
    });

    test('herstelcode ontgrendelt; nieuwe code vervangt de oude', () async {
      final d = dir('k');
      await vm.create(d.path, 'pw');
      expect((await vm.info(d.path)).hasRecoveryCode, isFalse);
      final code = await vm.createRecoveryCode(d.path);
      expect(code, matches(RegExp(r'^([A-Z2-9]{4}-){5}[A-Z2-9]{4}$')));
      expect((await vm.info(d.path)).hasRecoveryCode, isTrue);
      vm.lockAll();

      expect(await vm.unlockWithRecoveryCode(d.path, 'FOUT-CODE'), isFalse);
      // Kleine letters en zonder streepjes werkt ook.
      expect(
          await vm.unlockWithRecoveryCode(
              d.path, code.toLowerCase().replaceAll('-', ' ')),
          isTrue);

      final code2 = await vm.createRecoveryCode(d.path);
      vm.lockAll();
      expect(await vm.unlockWithRecoveryCode(d.path, code), isFalse);
      expect(await vm.unlockWithRecoveryCode(d.path, code2), isTrue);
      // Daarna kan een nieuw wachtwoord worden ingesteld.
      await vm.changePassword(d.path, 'opnieuw');
      vm.lockAll();
      expect(await vm.unlock(d.path, 'opnieuw'), isTrue);
    });

    test('kluis van versie 1 blijft werken en wordt versie 2', () async {
      final d = dir('oud');
      // Versie-1-kluis zoals v1.x van de app die maakte.
      final salt = VaultCrypto.randomBytes(16);
      final key = await VaultCrypto.deriveKey('pw', salt, 1000);
      File(p.join(d.path, VaultManager.markerName)).writeAsStringSync(jsonEncode({
        'versie': 1,
        'kdf': 'pbkdf2-sha256',
        'iteraties': 1000,
        'salt': base64.encode(salt),
        'controle': await VaultCrypto.makeCheck(key),
      }));
      final src = File(p.join(tmp.path, 'a.txt'))..writeAsStringSync('v1');
      final enc = await VaultManager.encryptInto(src, d.path, key);

      expect(await vm.unlock(d.path, 'fout'), isFalse);
      expect(await vm.unlock(d.path, 'pw'), isTrue);
      expect((await vm.info(d.path)).version, 1);

      await vm.changePassword(d.path, 'nieuw');
      vm.lockAll();
      expect(await vm.unlock(d.path, 'nieuw'), isTrue);
      expect((await vm.info(d.path)).version, 2);
      final out = File(p.join(tmp.path, 'out.txt'));
      await VaultCrypto.decryptFile(enc, out, vm.keyFor(d.path)!);
      expect(out.readAsStringSync(), 'v1');
    });
  });
}
