import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:bestandskluis/crypto/vault_crypto.dart';
import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:bestandskluis/services/file_ops.dart';
import 'package:bestandskluis/services/zip_ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late VaultManager vm;
  late ZipOps zips;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zip');
    vm = VaultManager(iterations: 1000);
    zips = ZipOps(FileOps(vm));
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('inpakken uit een kluis en uitpakken in een kluis', () async {
    final vault = Directory(p.join(tmp.path, 'kluis'))..createSync();
    Directory(p.join(vault.path, 'map')).createSync();
    File(p.join(vault.path, 'map', 'a.txt')).writeAsStringSync('A');
    File(p.join(vault.path, 'b.txt')).writeAsStringSync('B');
    await vm.create(vault.path, 'pw', encryptNames: true);
    final key = vm.keyFor(vault.path)!;
    File inVault(String dir, String name) =>
        File(p.join(dir, VaultCrypto.encryptedName(name, key)));

    // Inpakken naar een gewone map: zip is leesbaar en bevat de echte namen.
    final out = Directory(p.join(tmp.path, 'uit'))..createSync();
    await zips.zip([
      Directory(p.join(vault.path, 'map')),
      inVault(vault.path, 'b.txt'),
    ], out.path, 'pakket.zip');
    final zipFile = File(p.join(out.path, 'pakket.zip'));
    final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
    expect(archive.files.where((f) => f.isFile).map((f) => f.name).toSet(),
        {'map/a.txt', 'b.txt'});

    // Uitpakken in de kluis: alles versleuteld.
    await zips.unzip(zipFile, destDir: vault.path);
    final unpacked = Directory(p.join(vault.path, 'pakket'));
    expect(inVault(p.join(unpacked.path, 'map'), 'a.txt').existsSync(), isTrue);
    expect(inVault(unpacked.path, 'b.txt').existsSync(), isTrue);
    expect(
        unpacked.listSync(recursive: true).whereType<File>().any(
            (f) => !VaultCrypto.isEncryptedName(p.basename(f.path))),
        isFalse);

    // Zip in de kluis maken en weer uitpakken naar buiten.
    await zips.zip([inVault(vault.path, 'b.txt')], vault.path, 'k.zip');
    final encZip = inVault(vault.path, 'k.zip');
    expect(encZip.existsSync(), isTrue);
    await zips.unzip(encZip, destDir: out.path);
    expect(File(p.join(out.path, 'k', 'b.txt')).readAsStringSync(), 'B');
  });

  test('zip slip wordt genegeerd', () async {
    final a = Archive()
      ..addFile(ArchiveFile.string('../buiten.txt', 'x'))
      ..addFile(ArchiveFile.string('goed.txt', 'y'));
    final zip = File(p.join(tmp.path, 'kwaad.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(a));
    final dest = Directory(p.join(tmp.path, 'doel'))..createSync();
    await zips.unzip(zip, destDir: dest.path);
    expect(File(p.join(dest.path, 'kwaad', 'goed.txt')).readAsStringSync(), 'y');
    expect(File(p.join(tmp.path, 'buiten.txt')).existsSync(), isFalse);
    expect(File(p.join(dest.path, 'buiten.txt')).existsSync(), isFalse);
  });
}
