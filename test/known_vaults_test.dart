import 'dart:io';

import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:bestandskluis/services/known_vaults.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late VaultManager vm;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('bekend');
    vm = VaultManager(iterations: 1000);
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('kluizen worden onthouden en verdwenen kluizen vallen weg', () async {
    final a = (Directory(p.join(tmp.path, 'B-kluis'))..createSync()).path;
    final b = (Directory(p.join(tmp.path, 'a-kluis'))..createSync()).path;
    await vm.create(a, 'x');
    await vm.create(b, 'y');

    final known = KnownVaults(vm);
    await known.load();
    await known.add(a);
    await known.add(b);
    await known.add(a);
    expect(known.paths, [b, a]);

    // Opnieuw laden (nieuwe app-start) geeft dezelfde lijst.
    final again = KnownVaults(vm);
    await again.load();
    expect(again.paths, [b, a]);

    // Kluis opgeheven of verwijderd: verdwijnt uit de lijst.
    await vm.removeVault(a);
    expect(again.paths, [b]);
    await again.remove(b);
    expect(again.paths, isEmpty);
  });
}
