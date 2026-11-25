import 'dart:io';

import 'package:bestandskluis/crypto/vault_crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late VaultManager vm;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vm');
    vm = VaultManager(iterations: 1000);
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('kluis maken, vergrendelen, ontgrendelen en opheffen', () async {
    final dir = Directory(p.join(tmp.path, 'Prive'))..createSync();
    File(p.join(dir.path, 'a.txt')).writeAsStringSync('hallo');
    Directory(p.join(dir.path, 'sub')).createSync();
    File(p.join(dir.path, 'sub', 'b.jpg')).writeAsBytesSync([1, 2, 3]);

    await vm.create(dir.path, 'wachtwoord');
    expect(vm.isVaultRoot(dir.path), isTrue);
    expect(File(p.join(dir.path, 'a.txt')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'a.txt.bkv')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'sub', 'b.jpg.bkv')).existsSync(), isTrue);
    expect(vm.vaultRootFor(p.join(dir.path, 'sub')), p.normalize(dir.path));
    expect(vm.isUnlocked(dir.path), isTrue);

    vm.lock(dir.path);
    expect(vm.keyFor(dir.path), isNull);
    expect(await vm.unlock(dir.path, 'fout'), isFalse);
    expect(await vm.unlock(dir.path, 'wachtwoord'), isTrue);

    // Bestand dat een andere app heeft toegevoegd.
    File(p.join(dir.path, 'nieuw.txt')).writeAsStringSync('x');
    expect((await vm.plainFiles(dir.path)).length, 1);
    expect(await vm.encryptPlainFiles(dir.path), 1);
    expect(await vm.plainFiles(dir.path), isEmpty);

    await vm.removeVault(dir.path);
    expect(vm.isVaultRoot(dir.path), isFalse);
    expect(File(p.join(dir.path, 'a.txt')).readAsStringSync(), 'hallo');
    expect(File(p.join(dir.path, 'sub', 'b.jpg')).readAsBytesSync(), [1, 2, 3]);
    expect(File(p.join(dir.path, 'nieuw.txt')).readAsStringSync(), 'x');
  });

  test('geen geneste kluizen', () async {
    final outer = Directory(p.join(tmp.path, 'o'))..createSync();
    final inner = Directory(p.join(outer.path, 'i'))..createSync();
    await vm.create(inner.path, 'a');
    await expectLater(vm.create(outer.path, 'a'), throwsStateError);
    final deeper = Directory(p.join(inner.path, 'x'))..createSync();
    await expectLater(vm.create(deeper.path, 'a'), throwsStateError);
  });

  test('ontgrendelen met bewaarde sleutel (vingerafdruk)', () async {
    final a = Directory(p.join(tmp.path, 'a'))..createSync();
    final b = Directory(p.join(tmp.path, 'b'))..createSync();
    await vm.create(a.path, 'een');
    await vm.create(b.path, 'twee');
    final keyA = vm.keyFor(a.path)!;
    final bytes = await keyA.extractBytes();
    vm.lockAll();

    // Sleutel van een andere kluis wordt geweigerd.
    expect(await vm.unlockWithKey(b.path, keyA), isFalse);
    expect(vm.isUnlocked(b.path), isFalse);

    expect(await vm.unlockWithKey(a.path, SecretKey(bytes)), isTrue);
    expect(vm.isUnlocked(a.path), isTrue);
  });

  test('uniqueFile voorkomt overschrijven', () {
    File(p.join(tmp.path, 'f.jpg')).writeAsStringSync('');
    expect(p.basename(VaultManager.uniqueFile(tmp.path, 'f.jpg').path),
        'f (1).jpg');
    File(p.join(tmp.path, 'g.jpg.bkv')).writeAsStringSync('');
    expect(p.basename(VaultManager.uniqueFile(tmp.path, 'g.jpg.bkv').path),
        'g (1).jpg${VaultCrypto.extension}');
  });
}
