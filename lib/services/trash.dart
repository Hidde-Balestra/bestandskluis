import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';

/// Eén item in de prullenbak.
class TrashItem {
  TrashItem({
    required this.trashDir,
    required this.stored,
    required this.original,
    required this.deleted,
    required this.isDir,
    required this.name,
    required this.vaultRoot,
  });

  /// Map van de prullenbak waar het item in staat.
  final String trashDir;

  /// Naam in de prullenbak.
  final String stored;

  /// Oorspronkelijk pad.
  final String original;
  final DateTime deleted;
  final bool isDir;

  /// Leesbare naam (versleutelde namen alleen met ontgrendelde kluis).
  final String name;

  /// Kluis waar het uit komt (null = gewone map).
  final String? vaultRoot;

  String get path => p.join(trashDir, stored);
  DateTime get expires => deleted.add(const Duration(days: Trash.keepDays));
}

/// Prullenbak: verwijderde bestanden zijn 30 dagen terug te zetten.
///
/// Items uit een kluis gaan naar `.bestandskluis-prullenbak` in die kluis en
/// blijven dus versleuteld; andere items naar dezelfde map in de hoofdmap
/// van de opslag (zodat verplaatsen een snelle hernoeming is).
class Trash extends ChangeNotifier {
  Trash(this.vaults, this.roots);

  final VaultManager vaults;

  /// Hoofdmappen van de opslag (intern, SD-kaart).
  final Future<List<String>> Function() roots;

  static const dirName = VaultManager.trashDirName;
  static const _index = 'index.json';
  static const keepDays = 30;

  static bool isTrashPath(String path) =>
      p.split(path).contains(dirName);

  Future<String> _trashDirFor(String path) async {
    final vr = vaults.vaultRootFor(p.dirname(path));
    if (vr != null) return p.join(vr, dirName);
    final all = await roots();
    String? best;
    for (final r in all) {
      if (p.isWithin(r, path) && (best == null || r.length > best.length)) {
        best = r;
      }
    }
    return p.join(best ?? p.dirname(path), dirName);
  }

  static Future<Map<String, dynamic>> _readIndex(String dir) async {
    final f = File(p.join(dir, _index));
    if (!await f.exists()) return {};
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeIndex(String dir, Map<String, dynamic> idx) async {
    final f = File(p.join(dir, '$_index.tmp'));
    await f.writeAsString(jsonEncode(idx), flush: true);
    await f.rename(p.join(dir, _index));
  }

  static Future<void> _move(FileSystemEntity e, String target) async {
    try {
      await e.rename(target);
    } on FileSystemException {
      // Andere opslag: kopiëren en verwijderen.
      if (e is File) {
        await e.copy(target);
        await e.delete();
      } else if (e is Directory) {
        await _copyDir(e, target);
        await e.delete(recursive: true);
      }
    }
  }

  static Future<void> _copyDir(Directory src, String target) async {
    await Directory(target).create(recursive: true);
    await for (final c in src.list(followLinks: false)) {
      final t = p.join(target, p.basename(c.path));
      if (c is Directory) {
        await _copyDir(c, t);
      } else if (c is File) {
        await c.copy(t);
      }
    }
  }

  /// Verplaatst [e] naar de prullenbak.
  Future<void> moveToTrash(FileSystemEntity e) async {
    final path = p.normalize(p.absolute(e.path));
    if (isTrashPath(path)) {
      // Al in de prullenbak: echt verwijderen.
      await e.delete(recursive: true);
      return;
    }
    final dir = await _trashDirFor(path);
    await Directory(dir).create(recursive: true);
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final stored = '${id}_${p.basename(path)}';
    final isDir = e is Directory;
    await _move(e, p.join(dir, stored));
    final idx = await _readIndex(dir);
    idx[stored] = {
      'pad': path,
      'tijd': DateTime.now().millisecondsSinceEpoch,
      'map': isDir,
    };
    await _writeIndex(dir, idx);
    notifyListeners();
  }

  /// Alle prullenbakken: in de opslag en in de opgegeven kluizen.
  Future<List<String>> _allDirs(Iterable<String> vaultRoots) async {
    final out = <String>[
      for (final r in await roots()) p.join(r, dirName),
      for (final v in vaultRoots) p.join(v, dirName),
    ];
    return [
      for (final d in out.toSet())
        if (await Directory(d).exists()) d
    ];
  }

  /// Inhoud van alle prullenbakken, nieuwste eerst. Items uit vergrendelde
  /// kluizen worden alleen getoond als [vaultRoots] die kluis bevat.
  Future<List<TrashItem>> list(Iterable<String> vaultRoots) async {
    final items = <TrashItem>[];
    for (final dir in await _allDirs(vaultRoots)) {
      final vr = vaults.vaultRootFor(dir);
      final key = vr == null ? null : vaults.keyFor(vr);
      final idx = await _readIndex(dir);
      for (final MapEntry(key: stored, value: v) in idx.entries) {
        final m = v as Map<String, dynamic>;
        if (!await FileSystemEntity.isDirectory(p.join(dir, stored)) &&
            !await File(p.join(dir, stored)).exists()) {
          continue;
        }
        final original = m['pad'] as String;
        final real = p.basename(original);
        items.add(TrashItem(
          trashDir: dir,
          stored: stored,
          original: original,
          deleted: DateTime.fromMillisecondsSinceEpoch(m['tijd'] as int),
          isDir: m['map'] == true,
          name: VaultCrypto.isEncryptedName(real)
              ? VaultCrypto.plainName(real, key)
              : real,
          vaultRoot: vr,
        ));
      }
    }
    items.sort((a, b) => b.deleted.compareTo(a.deleted));
    return items;
  }

  Future<void> _forget(TrashItem item) async {
    final idx = await _readIndex(item.trashDir);
    idx.remove(item.stored);
    await _writeIndex(item.trashDir, idx);
  }

  /// Zet terug op de oude plek (met een volgnummer als de naam bezet is).
  Future<String> restore(TrashItem item) async {
    final parent = p.dirname(item.original);
    await Directory(parent).create(recursive: true);
    final key = item.vaultRoot == null ? null : vaults.keyFor(item.vaultRoot!);
    if (VaultCrypto.hasEncryptedName(p.basename(item.original)) && key == null) {
      throw StateError('Ontgrendel eerst de kluis');
    }
    final target = VaultManager.uniqueFile(
        parent, p.basename(item.original),
        encryptWith: VaultCrypto.isEncryptedName(p.basename(item.original))
            ? key
            : null);
    final src = item.isDir ? Directory(item.path) : File(item.path);
    await _move(src, target.path);
    await _forget(item);
    notifyListeners();
    return target.path;
  }

  Future<void> deleteForever(TrashItem item) async {
    final t = FileSystemEntity.typeSync(item.path);
    if (t == FileSystemEntityType.directory) {
      await Directory(item.path).delete(recursive: true);
    } else if (t != FileSystemEntityType.notFound) {
      await File(item.path).delete();
    }
    await _forget(item);
    notifyListeners();
  }

  /// Items ouder dan [keepDays] definitief verwijderen. Geeft het aantal.
  Future<int> purgeExpired(Iterable<String> vaultRoots, {DateTime? now}) async {
    final limit = (now ?? DateTime.now())
        .subtract(const Duration(days: keepDays));
    var n = 0;
    for (final item in await list(vaultRoots)) {
      if (item.deleted.isBefore(limit)) {
        await deleteForever(item);
        n++;
      }
    }
    return n;
  }
}
