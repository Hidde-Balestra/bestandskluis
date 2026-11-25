import 'dart:io';

import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:bestandskluis/ftp/ftp_client.dart';
import 'package:bestandskluis/ftp/ftp_server.dart';
import 'package:bestandskluis/services/backup.dart';
import 'package:bestandskluis/services/ftp_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('back-up stuurt alleen versleutelde bestanden en is incrementeel',
      () async {
    final tmp = await Directory.systemTemp.createTemp('backup');
    addTearDown(() => tmp.delete(recursive: true));
    final vm = VaultManager(iterations: 1000);

    // Kluis op de "telefoon".
    final vault = Directory(p.join(tmp.path, 'telefoon', 'Foto\'s'))
      ..createSync(recursive: true);
    File(p.join(vault.path, 'a.jpg')).writeAsStringSync('A' * 1000);
    Directory(p.join(vault.path, 'sub')).createSync();
    File(p.join(vault.path, 'sub', 'b.txt')).writeAsStringSync('B');
    await vm.create(vault.path, 'pw', encryptNames: true);
    vm.lockAll(); // back-up werkt ook met een vergrendelde kluis
    // Een onversleuteld bestand (bijv. door een andere app neergezet)
    // mag nooit naar de server.
    File(p.join(vault.path, 'los.txt')).writeAsStringSync('geheim');

    // Doelserver.
    final remoteRoot = Directory(p.join(tmp.path, 'server'))..createSync();
    final server = FtpServer(
        config: FtpServerConfig(
            rootPath: remoteRoot.path, port: 0, username: 'u', password: 'p'),
        vaults: VaultManager(),
        bindAddress: InternetAddress.loopbackIPv4);
    await server.start();
    addTearDown(server.dispose);
    final c = await FtpClient.connect('127.0.0.1',
        port: server.port, user: 'u', password: 'p');
    addTearDown(c.quit);

    final first = await VaultBackup.run(c, [vault.path], '/backup');
    expect(first.errors, isEmpty);
    expect(first.uploaded, 3); // kluisbestand + 2 versleutelde bestanden

    final copy = Directory(p.join(remoteRoot.path, 'backup', 'Foto\'s'));
    final names = copy
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toList();
    expect(names, contains(VaultManager.markerName));
    expect(names.where((n) => n.endsWith('.bkx')).length, 2);
    expect(names.any((n) => n.contains('los') || n.contains('a.jpg')), isFalse);

    // De kopie is een werkende kluis.
    expect(await vm.unlock(copy.path, 'pw'), isTrue);

    // Tweede keer: alleen het (kleine) kluisbestand opnieuw.
    final second = await VaultBackup.run(c, [vault.path], '/backup');
    expect(second.uploaded, 1);
    expect(second.unchanged, 2);
  });

  test('ftp-link uit QR-code', () {
    final fp = List.filled(32, 'AB').join();
    final (c, pw) = SavedConnection.fromUrl(
        'ftps://gebruiker:ge%20heim@192.168.1.5:2121?fp=$fp')!;
    expect(c.host, '192.168.1.5');
    expect(c.port, 2121);
    expect(c.user, 'gebruiker');
    expect(pw, 'ge heim');
    expect(c.tls, isTrue);
    expect(c.fingerprint, List.filled(32, 'AB').join(':'));
    expect(SavedConnection.fromUrl('http://x'), isNull);
    final (plain, nopw) = SavedConnection.fromUrl('ftp://10.0.0.2')!;
    expect(plain.port, 21);
    expect(plain.tls, isFalse);
    expect(nopw, isNull);
  });
}
