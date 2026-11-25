import 'dart:io';

import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:bestandskluis/services/file_ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late VaultManager vm;
  late FileOps ops;
  late String plainDir, vaultA, vaultB;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ops');
    vm = VaultManager(iterations: 1000);
    ops = FileOps(vm);
    plainDir = (Directory(p.join(tmp.path, 'gewoon'))..createSync()).path;
    vaultA = (Directory(p.join(tmp.path, 'A'))..createSync()).path;
    vaultB = (Directory(p.join(tmp.path, 'B'))..createSync()).path;
    await vm.create(vaultA, 'a');
    await vm.create(vaultB, 'b');
  });
  tearDown(() async => tmp.delete(recursive: true));

  File f(String dir, String name) => File(p.join(dir, name));

  test('in een kluis plakken versleutelt, eruit halen ontsleutelt', () async {
    f(plainDir, 'x.txt').writeAsStringSync('inhoud');
    await ops.transfer([f(plainDir, 'x.txt')], vaultA, move: true);
    expect(f(plainDir, 'x.txt').existsSync(), isFalse);
    expect(f(vaultA, 'x.txt.bkv').existsSync(), isTrue);

    await ops.transfer([f(vaultA, 'x.txt.bkv')], plainDir, move: false);
    expect(f(plainDir, 'x.txt').readAsStringSync(), 'inhoud');
    expect(f(vaultA, 'x.txt.bkv').existsSync(), isTrue);
  });

  test('van kluis naar kluis wordt opnieuw versleuteld', () async {
    f(plainDir, 'y.txt').writeAsStringSync('y');
    await ops.transfer([f(plainDir, 'y.txt')], vaultA, move: true);
    await ops.transfer([f(vaultA, 'y.txt.bkv')], vaultB, move: true);
    expect(f(vaultB, 'y.txt.bkv').existsSync(), isTrue);
    await ops.transfer([f(vaultB, 'y.txt.bkv')], plainDir, move: true);
    expect(f(plainDir, 'y.txt').readAsStringSync(), 'y');
  });

  test('mappen worden recursief versleuteld', () async {
    final d = Directory(p.join(plainDir, 'map'))..createSync();
    Directory(p.join(d.path, 'sub')).createSync();
    f(p.join(d.path, 'sub'), 'z.jpg').writeAsBytesSync([1, 2]);
    await ops.transfer([d], vaultA, move: true);
    expect(f(p.join(vaultA, 'map', 'sub'), 'z.jpg.bkv').existsSync(), isTrue);
    expect(d.existsSync(), isFalse);
  });

  test('vergrendelde kluis en kluis-in-kluis worden geweigerd', () async {
    f(plainDir, 'q.txt').writeAsStringSync('q');
    vm.lock(vaultA);
    await expectLater(
        ops.transfer([f(plainDir, 'q.txt')], vaultA, move: false),
        throwsStateError);
    await expectLater(
        ops.transfer([Directory(vaultB)], vaultA, move: false),
        throwsStateError);
  });

  test('hernoemen in een kluis houdt .bkv', () async {
    f(plainDir, 'r.txt').writeAsStringSync('r');
    await ops.transfer([f(plainDir, 'r.txt')], vaultA, move: true);
    await ops.rename(f(vaultA, 'r.txt.bkv'), 's.txt');
    expect(f(vaultA, 's.txt.bkv').existsSync(), isTrue);
  });
}
