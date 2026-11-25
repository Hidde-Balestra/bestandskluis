import 'dart:io';

import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:bestandskluis/ftp/ftp_client.dart';
import 'package:bestandskluis/ftp/ftp_server.dart';
import 'package:bestandskluis/ftp/ftp_tls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory root;
  late VaultManager vm;
  late FtpTlsIdentity id;

  setUpAll(() async {
    final d = await Directory.systemTemp.createTemp('cert');
    id = await FtpTlsIdentity.loadOrCreate(d);
    // Tweede keer laden geeft hetzelfde certificaat.
    final again = await FtpTlsIdentity.loadOrCreate(d);
    expect(again.fingerprint, id.fingerprint);
    await d.delete(recursive: true);
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ftps');
    root = Directory(p.join(tmp.path, 'root'))..createSync();
    File(p.join(root.path, 'hallo.txt')).writeAsStringSync('Hallo TLS');
    Directory(p.join(root.path, 'Kluis')).createSync();
    File(p.join(root.path, 'Kluis', 'geheim.txt')).writeAsStringSync('Geheim!');
    vm = VaultManager(iterations: 1000);
    await vm.create(p.join(root.path, 'Kluis'), 'pw', encryptNames: true);
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<FtpServer> start(FtpTls mode) async {
    final s = FtpServer(
        config: FtpServerConfig(
            rootPath: root.path,
            port: 0,
            username: 'u',
            password: 'p',
            tls: mode),
        vaults: vm,
        bindAddress: InternetAddress.loopbackIPv4,
        securityContext: id.context());
    await s.start();
    return s;
  }

  test('FTPS: lijst, download en upload versleuteld', () async {
    final server = await start(FtpTls.optional);
    final c = await FtpClient.connect('127.0.0.1',
        port: server.port, user: 'u', password: 'p', tls: true);
    try {
      expect(c.secure, isTrue);
      expect(c.fingerprint, id.fingerprint);
      expect((await c.list('/')).map((e) => e.name), ['Kluis', 'hallo.txt']);
      final out = File(p.join(tmp.path, 'dl.txt'));
      await c.download('/Kluis/geheim.txt', out);
      expect(out.readAsStringSync(), 'Geheim!');
      final up = File(p.join(tmp.path, 'up.txt'))..writeAsStringSync('x' * 100000);
      await c.upload(up, '/nieuw.txt');
      expect(File(p.join(root.path, 'nieuw.txt')).lengthSync(), 100000);
    } finally {
      await c.quit();
      await server.dispose();
    }
  });

  test('vastgepind certificaat', () async {
    final server = await start(FtpTls.optional);
    try {
      final ok = await FtpClient.connect('127.0.0.1',
          port: server.port,
          user: 'u',
          password: 'p',
          tls: true,
          pinnedFingerprint: id.fingerprint);
      await ok.quit();
      await expectLater(
          FtpClient.connect('127.0.0.1',
              port: server.port,
              user: 'u',
              password: 'p',
              tls: true,
              pinnedFingerprint: 'AA:BB'),
          throwsA(isA<FtpCertificateException>()));
    } finally {
      await server.dispose();
    }
  });

  test('TLS verplicht: zonder TLS inloggen kan niet', () async {
    final server = await start(FtpTls.required);
    try {
      await expectLater(
          FtpClient.connect('127.0.0.1',
              port: server.port, user: 'u', password: 'p'),
          throwsA(isA<FtpException>()));
      final c = await FtpClient.connect('127.0.0.1',
          port: server.port, user: 'u', password: 'p', tls: true);
      expect((await c.list('/')).length, 2);
      await c.quit();
    } finally {
      await server.dispose();
    }
  });

  test('TLS uit: AUTH TLS wordt geweigerd', () async {
    final server = await start(FtpTls.off);
    try {
      await expectLater(
          FtpClient.connect('127.0.0.1',
              port: server.port, user: 'u', password: 'p', tls: true),
          throwsA(isA<FtpException>()));
    } finally {
      await server.dispose();
    }
  });
}
