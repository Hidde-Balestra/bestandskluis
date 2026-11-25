import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';
import 'file_ops.dart';

/// Zip-bestanden maken en uitpakken, ook in en uit kluizen.
///
/// Inpakken: bestanden uit een kluis worden in een tijdelijke map
/// ontsleuteld, de zip wordt daar gemaakt en daarna naar de doelmap
/// verplaatst (en dus versleuteld als die in een kluis ligt). Uitpakken
/// werkt andersom. Tijdelijke bestanden worden altijd opgeruimd.
class ZipOps {
  ZipOps(this.ops, {Directory? tempBase}) : _tempBase = tempBase;

  final FileOps ops;
  final Directory? _tempBase;

  VaultManager get vaults => ops.vaults;

  Future<Directory> _temp() async =>
      (_tempBase ?? Directory.systemTemp).createTemp('bk_zip');

  /// Leesbare naam van een item (versleutelde namen ontsleuteld).
  String _plainName(FileSystemEntity e) {
    final name = p.basename(e.path);
    if (e is! File || !VaultCrypto.isEncryptedName(name)) return name;
    final root = vaults.vaultRootFor(e.parent.path);
    return root == null
        ? name
        : VaultCrypto.plainName(name, vaults.keyFor(root));
  }

  /// Pakt [items] in als [zipName] in [destDir]. Geeft de leesbare naam.
  Future<void> zip(List<FileSystemEntity> items, String destDir, String zipName,
      {void Function(String)? onItem}) async {
    final tmp = await _temp();
    try {
      final zipFile = File(p.join(tmp.path, zipName));
      final enc = ZipFileEncoder()..create(zipFile.path);
      final work = Directory(p.join(tmp.path, 'werk'))..createSync();
      Future<void> add(FileSystemEntity e, String inZip) async {
        if (e is Directory) {
          await for (final c in e.list(followLinks: false)) {
            final n = p.basename(c.path);
            if (n == VaultManager.markerName || n.endsWith('.part')) continue;
            await add(c, '$inZip/${_plainName(c)}');
          }
        } else if (e is File) {
          onItem?.call(inZip);
          final key = ops.keyForFile(e);
          if (VaultCrypto.isEncryptedName(p.basename(e.path)) &&
              vaults.vaultRootFor(e.parent.path) != null) {
            if (key == null) throw StateError('Kluis is vergrendeld');
            final plain = File(p.join(work.path, 'f'));
            await VaultCrypto.decryptFile(e, plain, key);
            await enc.addFile(plain, inZip);
            await plain.delete();
          } else {
            await enc.addFile(e, inZip);
          }
        }
      }

      for (final e in items) {
        await add(e, _plainName(e));
      }
      await enc.close();
      await ops.transfer([zipFile], destDir, move: true);
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  /// Pakt [zip] uit in een nieuwe map naast het zip-bestand (of in
  /// [destDir]). Paden die buiten de doelmap wijzen worden genegeerd.
  Future<void> unzip(File zip, {String? destDir, void Function(String)? onItem}) async {
    final tmp = await _temp();
    try {
      var source = zip;
      final key = ops.keyForFile(zip);
      if (VaultCrypto.isEncryptedName(p.basename(zip.path)) &&
          vaults.vaultRootFor(zip.parent.path) != null) {
        if (key == null) throw StateError('Kluis is vergrendeld');
        source = File(p.join(tmp.path, 'bron.zip'));
        await VaultCrypto.decryptFile(zip, source, key);
      }
      final name = p.basenameWithoutExtension(_plainName(zip));
      final out = Directory(p.join(tmp.path, name))..createSync();
      final input = InputFileStream(source.path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        for (final f in archive) {
          final rel = p.normalize(f.name.replaceAll('\\', '/'));
          final target = p.join(out.path, rel);
          // Bescherming tegen "zip slip" (../ in namen).
          if (rel.startsWith('..') || p.isAbsolute(rel) || !p.isWithin(out.path, target)) {
            continue;
          }
          if (f.isFile) {
            onItem?.call(rel);
            Directory(p.dirname(target)).createSync(recursive: true);
            final os = OutputFileStream(target);
            f.writeContent(os);
            await os.close();
          } else {
            Directory(target).createSync(recursive: true);
          }
        }
      } finally {
        await input.close();
      }
      await ops.transfer([out], destDir ?? zip.parent.path, move: true);
    } finally {
      await tmp.delete(recursive: true);
    }
  }
}
