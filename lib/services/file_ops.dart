import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';
import 'trash.dart';

/// Kopiëren, verplaatsen en verwijderen, met automatische versleuteling
/// bij het in of uit een kluis zetten.
class FileOps {
  FileOps(this.vaults);

  final VaultManager vaults;

  /// Prullenbak (in de app altijd gezet; in tests soms niet).
  Trash? trash;

  /// Kopieert of verplaatst [items] naar [destDir].
  ///
  /// * naar een ontgrendelde kluis → bestanden worden versleuteld;
  /// * uit een kluis naar een gewone map → bestanden worden ontsleuteld;
  /// * een complete kluismap wordt als geheel (versleuteld) meegenomen.
  Future<void> transfer(List<FileSystemEntity> items, String destDir,
      {required bool move, void Function(String name)? onItem}) async {
    final destRoot = vaults.vaultRootFor(destDir);
    if (destRoot != null && vaults.keyFor(destRoot) == null) {
      throw StateError('De doelkluis is vergrendeld');
    }
    for (final item in items) {
      final norm = p.normalize(p.absolute(item.path));
      final dest = p.normalize(p.absolute(destDir));
      if (item is Directory && (dest == norm || p.isWithin(norm, dest))) {
        throw StateError('Een map kan niet in zichzelf worden geplaatst');
      }
      await _transferOne(item, destDir, destRoot, move, onItem);
    }
  }

  Future<void> _transferOne(FileSystemEntity item, String destDir,
      String? destRoot, bool move, void Function(String)? onItem) async {
    final name = p.basename(item.path);
    final srcRoot = vaults.vaultRootFor(item.parent.path);
    onItem?.call(VaultCrypto.plainName(
        name, srcRoot == null ? null : vaults.keyFor(srcRoot)));

    if (item is Directory) {
      final isVault = vaults.isVaultRoot(item.path);
      if (isVault && destRoot != null) {
        throw StateError('Een kluis kan niet in een andere kluis');
      }
      // Zelfde "kluiswereld" of een complete kluis: gewoon verplaatsen/kopiëren.
      if (srcRoot == destRoot || isVault) {
        final target = VaultManager.uniqueFile(destDir, name).path;
        if (move && await _tryRename(item, target)) {
          if (isVault) vaults.lock(item.path);
          return;
        }
        await _copyDirRaw(item, target);
        if (move) {
          if (isVault) vaults.lock(item.path);
          await item.delete(recursive: true);
        }
        return;
      }
      final target = Directory(VaultManager.uniqueFile(destDir, name).path);
      await target.create();
      await for (final child in item.list(followLinks: false)) {
        if (p.basename(child.path) == VaultManager.markerName) continue;
        await _transferOne(child, target.path, destRoot, move, onItem);
      }
      if (move) await item.delete(recursive: true);
      return;
    }

    if (item is! File) return;
    final encrypted =
        srcRoot != null && VaultCrypto.isEncryptedName(name);
    final srcKey = srcRoot == null ? null : vaults.keyFor(srcRoot);
    final destKey = destRoot == null ? null : vaults.keyFor(destRoot);

    if (srcRoot == destRoot || (!encrypted && destRoot == null)) {
      final target = VaultManager.uniqueFile(destDir, name,
          encryptWith: srcRoot == destRoot ? srcKey : null);
      if (!(move && await _tryRename(item, target.path))) {
        await item.copy(target.path);
        if (move) await item.delete();
      }
      return;
    }
    if (encrypted && srcKey == null) {
      throw StateError('De bronkluis is vergrendeld');
    }

    if (encrypted && destKey == null) {
      await VaultManager.decryptInto(item, destDir, srcKey!);
    } else if (!encrypted && destKey != null) {
      await VaultManager.encryptInto(item, destDir, destKey);
    } else {
      // Van de ene kluis naar de andere: via een tijdelijke kopie.
      final tmp = await Directory.systemTemp.createTemp('bk');
      try {
        final plain = await VaultManager.decryptInto(item, tmp.path, srcKey!);
        await VaultManager.encryptInto(plain, destDir, destKey!);
      } finally {
        await tmp.delete(recursive: true);
      }
    }
    if (move) await item.delete();
  }

  static Future<bool> _tryRename(FileSystemEntity e, String target) async {
    try {
      await e.rename(target);
      return true;
    } on FileSystemException {
      return false; // bijv. naar een andere opslag
    }
  }

  static Future<void> _copyDirRaw(Directory src, String target) async {
    await Directory(target).create(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      final t = p.join(target, p.basename(e.path));
      if (e is Directory) {
        await _copyDirRaw(e, t);
      } else if (e is File) {
        await e.copy(t);
      }
    }
  }

  /// Hernoemt; in een kluis blijft de .bkv-extensie behouden.
  Future<FileSystemEntity> rename(FileSystemEntity e, String newName) async {
    if (newName.isEmpty || newName.contains('/') || newName.contains('\\')) {
      throw ArgumentError('Ongeldige naam');
    }
    final name = p.basename(e.path);
    final inVault = vaults.vaultRootFor(e.parent.path) != null;
    final key = vaults.keyForDir(e.parent.path);
    if (VaultCrypto.hasEncryptedName(name) && key == null) {
      throw StateError('Ontgrendel de kluis eerst');
    }
    final real = (e is File && inVault && VaultCrypto.isEncryptedName(name))
        ? VaultCrypto.encryptedName(newName, key)
        : newName;
    final target = p.join(e.parent.path, real);
    if (await FileSystemEntity.type(target) != FileSystemEntityType.notFound) {
      throw StateError('Er bestaat al een item met deze naam');
    }
    return e.rename(target);
  }

  /// Verwijdert; met een [trash] gaat het naar de prullenbak (tenzij
  /// [permanent]).
  Future<void> delete(List<FileSystemEntity> items,
      {bool permanent = false}) async {
    for (final e in items) {
      if (e is Directory && vaults.isVaultRoot(e.path)) vaults.lock(e.path);
      final t = trash;
      if (t != null && !permanent) {
        await t.moveToTrash(e);
      } else {
        await e.delete(recursive: true);
      }
    }
  }

  /// Sleutel om [file] te lezen, of null als dat geen kluisbestand is.
  SecretKey? keyForFile(File file) => VaultCrypto.isEncryptedName(
          p.basename(file.path))
      ? vaults.keyForDir(file.parent.path)
      : null;
}
