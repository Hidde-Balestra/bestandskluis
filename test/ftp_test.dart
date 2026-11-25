import 'dart:io';

import 'package:bestandskluis/crypto/vault_crypto.dart';
import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:bestandskluis/ftp/ftp_client.dart';
import 'package:bestandskluis/ftp/ftp_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory root;
  late VaultManager vm;
  late FtpServer server;
  late FtpClient client;

  Future<FtpServer> startServer(FtpServerConfig cfg) async {
    final s = FtpServer(
        config: cfg, vaults: vm, bindAddress: InternetAddress.loopbackIPv4);
    await s.start();
    return s;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ftp');
    root = Directory(p.join(tmp.path, 'root'))..createSync();
    File(p.join(root.path, 'hallo.txt')).writeAsStringSync('Hallo wereld');
    Directory(p.join(root.path, 'Kluis')).createSync();
    File(p.join(root.path, 'Kluis', 'geheim.txt')).writeAsStringSync('Geheim!');
    vm = VaultManager(iterations: 1000);
    await vm.create(p.join(root.path, 'Kluis'), 'pw');
    server = await startServer(FtpServerConfig(
        rootPath: root.path, port: 0, username: 'u', password: 'p'));
    client = await FtpClient.connect('127.0.0.1',
        port: server.port, user: 'u', password: 'p');
  });

  tearDown(() async {
    await client.quit();
    await server.dispose();
    await tmp.delete(recursive: true);
  });

  test('verkeerd wachtwoord', () async {
    await expectLater(
        FtpClient.connect('127.0.0.1',
            port: server.port, user: 'u', password: 'fout'),
        throwsA(isA<FtpException>()));
  });

  test('lijst, download en upload buiten een kluis', () async {
    final list = await client.list('/');
    expect(list.map((e) => e.name), ['Kluis', 'hallo.txt']);
    expect(list.first.isDir, isTrue);
    expect(list.last.size, 12);

    final out = File(p.join(tmp.path, 'dl.txt'));
    await client.download('/hallo.txt', out);
    expect(out.readAsStringSync(), 'Hallo wereld');

    final up = File(p.join(tmp.path, 'up.txt'))..writeAsStringSync('upload');
    await client.upload(up, '/nieuw.txt');
    expect(File(p.join(root.path, 'nieuw.txt')).readAsStringSync(), 'upload');
    expect(await client.size('/nieuw.txt'), 6);
  });

  test('ontgrendelde kluis wordt ontsleuteld gedeeld', () async {
    final list = await client.list('/Kluis');
    expect(list.map((e) => e.name), ['geheim.txt']); // geen .bkv, geen marker
    expect(list.single.size, 7);

    final out = File(p.join(tmp.path, 'g.txt'));
    await client.download('/Kluis/geheim.txt', out);
    expect(out.readAsStringSync(), 'Geheim!');

    // Upload in de kluis wordt versleuteld opgeslagen.
    final up = File(p.join(tmp.path, 'up.txt'))
      ..writeAsStringSync('nieuw geheim');
    await client.upload(up, '/Kluis/b.txt');
    expect(File(p.join(root.path, 'Kluis', 'b.txt')).existsSync(), isFalse);
    final stored = File(p.join(root.path, 'Kluis', 'b.txt.bkv'));
    expect(stored.existsSync(), isTrue);
    expect(stored.readAsBytesSync().take(4), VaultCrypto.magic);
    await client.download('/Kluis/b.txt', out);
    expect(out.readAsStringSync(), 'nieuw geheim');

    await client.rename('/Kluis/b.txt', '/Kluis/c.txt');
    expect(File(p.join(root.path, 'Kluis', 'c.txt.bkv')).existsSync(), isTrue);
    await expectLater(client.rename('/Kluis/c.txt', '/c.txt'),
        throwsA(isA<FtpException>()));
    await client.delete('/Kluis/c.txt');
    expect(File(p.join(root.path, 'Kluis', 'c.txt.bkv')).existsSync(), isFalse);
  });

  test('vergrendelde kluis: alleen versleutelde bestanden, geen upload',
      () async {
    vm.lock(p.join(root.path, 'Kluis'));
    final list = await client.list('/Kluis');
    expect(list.map((e) => e.name), ['geheim.txt.bkv']);
    final up = File(p.join(tmp.path, 'up.txt'))..writeAsStringSync('x');
    await expectLater(
        client.upload(up, '/Kluis/x.txt'), throwsA(isA<FtpException>()));
    expect(File(p.join(root.path, 'Kluis', 'x.txt')).existsSync(), isFalse);
  });

  test('ontsleutelen via FTP uitgeschakeld', () async {
    final s2 = await startServer(FtpServerConfig(
        rootPath: root.path,
        port: 0,
        username: 'u',
        password: 'p',
        decryptVaults: false));
    final c2 = await FtpClient.connect('127.0.0.1',
        port: s2.port, user: 'u', password: 'p');
    expect((await c2.list('/Kluis')).single.name, 'geheim.txt.bkv');
    await c2.quit();
    await s2.dispose();
  });

  test('geen toegang buiten de hoofdmap of tot het kluisbestand', () async {
    await expectLater(
        client.download('/../../etc/passwd', File(p.join(tmp.path, 'x'))),
        throwsA(isA<FtpException>()));
    // Het kluisbestand is niet zichtbaar en kan niet worden verwijderd of
    // hernoemd (wel gelezen door een gebruiker met schrijfrechten, voor
    // back-ups).
    expect((await client.list('/Kluis')).map((e) => e.name),
        isNot(contains('.bestandskluis')));
    await expectLater(
        client.delete('/Kluis/.bestandskluis'), throwsA(isA<FtpException>()));
    await expectLater(client.rename('/Kluis/.bestandskluis', '/Kluis/x'),
        throwsA(isA<FtpException>()));
    expect(File(p.join(root.path, 'Kluis', '.bestandskluis')).existsSync(),
        isTrue);
    await client.cd('/../..');
    expect(await client.pwd(), '/');
  });

  test('mappen maken en verwijderen', () async {
    await client.mkdir('/map');
    expect(Directory(p.join(root.path, 'map')).existsSync(), isTrue);
    await client.cd('map');
    expect(await client.pwd(), '/map');
    await client.rmdir('/map');
    expect(Directory(p.join(root.path, 'map')).existsSync(), isFalse);
  });

  test('alleen-lezen en anoniem', () async {
    final s2 = await startServer(FtpServerConfig(
        rootPath: root.path, port: 0, allowAnonymous: true, readOnly: true));
    final c2 = await FtpClient.connect('127.0.0.1', port: s2.port);
    await expectLater(c2.delete('/hallo.txt'), throwsA(isA<FtpException>()));
    expect(File(p.join(root.path, 'hallo.txt')).existsSync(), isTrue);
    // Anoniem: kluisbestand niet leesbaar.
    await expectLater(
        c2.download('/Kluis/.bestandskluis', File(p.join(tmp.path, 'x'))),
        throwsA(isA<FtpException>()));
    await c2.quit();
    await s2.dispose();
  });
}
