import 'dart:io';
import 'dart:ui';

import 'package:bestandskluis/crypto/vault_manager.dart';
import 'package:bestandskluis/screens/photo_editor_screen.dart';
import 'package:bestandskluis/services/memory_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  test('draaien en bijsnijden van een foto in een kluis', () async {
    final tmp = await Directory.systemTemp.createTemp('edit');
    addTearDown(() => tmp.delete(recursive: true));
    final vm = VaultManager(iterations: 1000);
    final vault = Directory(p.join(tmp.path, 'k'))..createSync();
    final src = img.Image(width: 200, height: 100);
    img.fill(src, color: img.ColorRgb8(10, 120, 200));
    File(p.join(vault.path, 'foto.jpg')).writeAsBytesSync(img.encodeJpg(src));
    await vm.create(vault.path, 'pw');
    final key = vm.keyFor(vault.path)!;
    final f = File(p.join(vault.path, 'foto.jpg.bkv'));

    final bytes = await MemoryFiles.readBytes(f, key);
    // Kwartslag rechtsom (100×200), dan de bovenste helft (100×100).
    final out = await PhotoEdit.apply(
        bytes, 1, const Rect.fromLTWH(0, 0, 1, 0.5), png: false);
    await MemoryFiles.writeBytes(f, out, key);

    final result = img.decodeJpg(await MemoryFiles.readBytes(f, key))!;
    expect([result.width, result.height], [100, 100]);
    // Nog steeds versleuteld op schijf.
    expect(f.readAsBytesSync().take(2), isNot([0xFF, 0xD8]));
  });
}
