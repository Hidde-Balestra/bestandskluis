import 'dart:io';
import 'dart:typed_data';

import 'package:bestandskluis/crypto/vault_crypto.dart';
import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:bestandskluis/ftp/ftp_client.dart';
import 'package:bestandskluis/ftp/ftp_server.dart';
import 'package:bestandskluis/services/backup.dart';
import 'package:bestandskluis/services/file_ops.dart';
import 'package:bestandskluis/services/file_tools.dart';
import 'package:bestandskluis/services/media_server.dart';
import 'package:bestandskluis/services/memory_files.dart';
import 'package:bestandskluis/services/trash.dart';
import 'package:bestandskluis/services/vault_meta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late VaultManager vm;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('v14');
    vm = VaultManager(iterations: 1000);
  });
  tearDown(() async => tmp.delete(recursive: true));

  Directory dir(String rel) =>
      Directory(p.join(tmp.path, rel))..createSync(recursive: true);

  group('prullenbak', () {
    test('gewone bestanden en kluisbestanden terugzetten', () async {
      final root = dir('opslag');
      final ops = FileOps(vm)..trash = Trash(vm, () async => [root.path]);
      final docs = dir('opslag/Documenten');
      final f = File(p.join(docs.path, 'brief.txt'))..writeAsStringSync('hoi');
      await ops.delete([f]);
      expect(f.existsSync(), isFalse);

      final vault = dir('opslag/Kluis');
      File(p.join(vault.path, 'geheim.txt')).writeAsStringSync('x');
      await vm.create(vault.path, 'pw', encryptNames: true);
      final key = vm.keyFor(vault.path)!;
      final enc = File(p.join(vault.path, VaultCrypto.encryptedName('geheim.txt', key)));
      await ops.delete([enc]);
      // Versleuteld in de prullenbak van de kluis zelf.
      final vaultTrash = Directory(p.join(vault.path, Trash.dirName));
      expect(
          vaultTrash.listSync().any((e) => e.path.endsWith(VaultCrypto.nameExtension)),
          isTrue);
      // De prullenbak wordt niet opnieuw "versleuteld".
      expect(await vm.plainFiles(vault.path), isEmpty);

      final items = await ops.trash!.list([vault.path]);
      expect(items.map((i) => i.name).toSet(), {'brief.txt', 'geheim.txt'});

      for (final i in items) {
        await ops.trash!.restore(i);
      }
      expect(f.readAsStringSync(), 'hoi');
      expect(enc.existsSync(), isTrue);
      expect(await ops.trash!.list([vault.path]), isEmpty);
    });

    test('na 30 dagen definitief weg', () async {
      final root = dir('opslag');
      final trash = Trash(vm, () async => [root.path]);
      final f = File(p.join(root.path, 'oud.txt'))..writeAsStringSync('1');
      await trash.moveToTrash(f);
      expect(await trash.purgeExpired(const [],
          now: DateTime.now().add(const Duration(days: 29))), 0);
      expect(await trash.purgeExpired(const [],
          now: DateTime.now().add(const Duration(days: 31))), 1);
      expect(await trash.list(const []), isEmpty);
    });
  });

  test('favorieten en albums staan versleuteld in de kluis', () async {
    final vault = dir('k');
    File(p.join(vault.path, 'a.jpg')).writeAsBytesSync([1]);
    File(p.join(vault.path, 'b.jpg')).writeAsBytesSync([2]);
    await vm.create(vault.path, 'pw');
    final store = VaultMetaStore(vm);
    final a = File(p.join(vault.path, 'a.jpg.bkv'));
    final b = File(p.join(vault.path, 'b.jpg.bkv'));
    expect(await store.toggleFavorite(a), isTrue);
    await store.addToAlbum('Vakantie', [a, b]);
    expect(store.isFavorite(a), isTrue);
    expect(await store.albumNames(), ['Vakantie']);

    // Bestand is versleuteld en wordt na opnieuw laden gelezen.
    final metaFile = File(p.join(vault.path, VaultMetaStore.fileName));
    expect(String.fromCharCodes(metaFile.readAsBytesSync()).contains('Vakantie'),
        isFalse);
    vm.lockAll();
    expect(await vm.unlock(vault.path, 'pw'), isTrue);
    final again = VaultMetaStore(vm);
    expect(await again.contains(a, null), isTrue);
    expect(await again.contains(b, 'Vakantie'), isTrue);
    await again.deleteAlbum('Vakantie');
    expect(await again.albumNames(), isEmpty);
  });

  test('duplicaten, ook tussen versleuteld en gewoon', () async {
    final root = dir('d');
    File(p.join(root.path, 'x1.jpg')).writeAsStringSync('zelfde inhoud');
    final sub = dir('d/sub');
    File(p.join(sub.path, 'x2.jpg')).writeAsStringSync('zelfde inhoud');
    File(p.join(sub.path, 'y.jpg')).writeAsStringSync('andere inhoud');
    final vault = dir('d/kluis');
    File(p.join(vault.path, 'x3.jpg')).writeAsStringSync('zelfde inhoud');
    await vm.create(vault.path, 'pw', encryptNames: true);

    final tools = FileTools(vm);
    final groups = await tools.findDuplicates(root);
    expect(groups, hasLength(1));
    expect(groups.first.map((f) => f.name).toSet(), {'x1.jpg', 'x2.jpg', 'x3.jpg'});

    final report = await tools.analyze(root);
    expect(report.files, 4); // x1, x2, y en x3 (kluisbestand telt niet)
    expect(report.dirs.map((d) => p.basename(d.dir.path)).toSet(), {'sub', 'kluis'});
    expect(report.largest.any((f) => f.name == 'x3.jpg'), isTrue);
  });

  test('notitie lezen en schrijven in het geheugen', () async {
    final vault = dir('k');
    await vm.create(vault.path, 'pw');
    final key = vm.keyFor(vault.path)!;
    final f = File(p.join(vault.path, 'notitie.txt.bkv'));
    await MemoryFiles.writeText(f, 'Boodschappen: brood', key);
    expect(String.fromCharCodes(f.readAsBytesSync()).contains('brood'), isFalse);
    expect(await MemoryFiles.readText(f, key), 'Boodschappen: brood');
    final plain = File(p.join(tmp.path, 'gewoon.txt'));
    await MemoryFiles.writeText(plain, 'hallo', null);
    expect(plain.readAsStringSync(), 'hallo');
  });

  test('back-up terugzetten', () async {
    final vault = dir('telefoon/Foto\'s');
    File(p.join(vault.path, 'a.jpg')).writeAsStringSync('A' * 500);
    dir('telefoon/Foto\'s/sub');
    File(p.join(vault.path, 'sub', 'b.txt')).writeAsStringSync('B');
    await vm.create(vault.path, 'pw', encryptNames: true);
    final remoteRoot = dir('server');
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
    await VaultBackup.run(c, [vault.path], '/backup');

    expect(await VaultRestore.remoteVaults(c, '/backup'), ['Foto\'s']);
    final newPhone = dir('nieuw');
    final restored = await VaultRestore.restore(
        c, '/backup/Foto\'s', newPhone.path);
    final vm2 = VaultManager(iterations: 1000);
    expect(await vm2.unlock(restored, 'pw'), isTrue);
    final key = vm2.keyFor(restored)!;
    final b = File(p.join(restored, 'sub', VaultCrypto.encryptedName('b.txt', key)));
    expect(await MemoryFiles.readText(b, key), 'B');

    // Een map zonder kluisbestand wordt geweigerd.
    await c.mkdir('/backup/leeg');
    await expectLater(
        VaultRestore.restore(c, '/backup/leeg', newPhone.path), throwsStateError);
    expect(Directory(p.join(newPhone.path, 'leeg')).existsSync(), isFalse);
  });

  test('video-stream met Range, alleen met geldige token', () async {
    final vault = dir('k');
    final data = Uint8List.fromList(List.generate(700000, (i) => i % 251));
    File(p.join(vault.path, 'film.mp4')).writeAsBytesSync(data);
    await vm.create(vault.path, 'pw');
    final key = vm.keyFor(vault.path)!;
    final enc = File(p.join(vault.path, 'film.mp4.bkv'));
    final url = await MediaServer.instance.register(enc, key, 'film.mp4');
    final http = HttpClient();
    addTearDown(() => http.close(force: true));

    Future<(int, List<int>, String?)> get(Uri u, [String? range]) async {
      final req = await http.getUrl(u);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close();
      final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      return (res.statusCode, body, res.headers.value('content-range'));
    }

    final (s1, all, _) = await get(url);
    expect(s1, 200);
    expect(all, data);
    // Midden in de video (over een blokgrens van 256 KiB heen).
    final (s2, part, cr) = await get(url, 'bytes=262000-262200');
    expect(s2, 206);
    expect(part, data.sublist(262000, 262201));
    expect(cr, 'bytes 262000-262200/700000');
    // Verkeerde token.
    final (s3, _, _) = await get(url.replace(path: '/onzin.mp4'));
    expect(s3, 404);
    MediaServer.instance.revoke(url);
    final (s4, _, _) = await get(url);
    expect(s4, 404);
  });
}
