import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'vault_crypto.dart';

/// Wat de FTP-server en andere diensten van de kluizen moeten weten.
abstract class VaultAccess {
  /// Hoofdmap van de kluis waar [dirPath] in ligt, of null.
  String? vaultRootFor(String dirPath);

  /// Sleutel van een ontgrendelde kluis, of null als die vergrendeld is.
  SecretKey? keyFor(String vaultRoot);
}

typedef VaultProgress = void Function(int done, int total, String name);

/// Beheert versleutelde mappen ("kluizen").
///
/// Een kluis is een gewone map met een verborgen bestand `.bestandskluis`
/// (salt, PBKDF2-parameters en een controlewaarde). Alle bestanden in de map en
/// submappen worden opgeslagen als `naam.ext.bkv`. Sleutels van ontgrendelde
/// kluizen staan alleen in het werkgeheugen.
class VaultManager extends ChangeNotifier implements VaultAccess {
  VaultManager({this.iterations = 210000});

  static const markerName = '.bestandskluis';

  /// PBKDF2-iteraties voor nieuwe kluizen.
  final int iterations;

  final Map<String, SecretKey> _keys = {};

  static String _norm(String path) => p.normalize(p.absolute(path));

  Iterable<String> get unlockedVaults => _keys.keys;

  bool isVaultRoot(String dir) =>
      File(p.join(dir, markerName)).existsSync();

  @override
  String? vaultRootFor(String dirPath) {
    var dir = _norm(dirPath);
    while (true) {
      if (isVaultRoot(dir)) return dir;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  @override
  SecretKey? keyFor(String vaultRoot) => _keys[_norm(vaultRoot)];

  bool isUnlocked(String vaultRoot) => _keys.containsKey(_norm(vaultRoot));

  /// Sleutel voor de map [dirPath]: null als die niet in een kluis ligt of
  /// als de kluis vergrendeld is.
  SecretKey? keyForDir(String dirPath) {
    final root = vaultRootFor(dirPath);
    return root == null ? null : keyFor(root);
  }

  Future<Map<String, dynamic>> _readMarker(String root) async {
    final raw = await File(p.join(root, markerName)).readAsString();
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Maakt van [dir] een kluis en versleutelt alle bestanden erin.
  Future<void> create(String dir, String password,
      {VaultProgress? onProgress}) async {
    dir = _norm(dir);
    if (password.isEmpty) {
      throw ArgumentError('Wachtwoord mag niet leeg zijn');
    }
    if (vaultRootFor(dir) != null) {
      throw StateError('Deze map ligt al in een kluis');
    }
    await for (final e in Directory(dir).list(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path) == markerName) {
        throw StateError('Er staat al een kluis in een submap');
      }
    }
    final salt = VaultCrypto.randomBytes(16);
    final key = await VaultCrypto.deriveKey(password, salt, iterations);
    final marker = {
      'versie': 1,
      'kdf': 'pbkdf2-sha256',
      'iteraties': iterations,
      'salt': base64.encode(salt),
      'controle': await VaultCrypto.makeCheck(key),
    };
    await File(p.join(dir, markerName))
        .writeAsString(const JsonEncoder.withIndent('  ').convert(marker));
    _keys[dir] = key;
    notifyListeners();
    await encryptPlainFiles(dir, onProgress: onProgress);
  }

  /// Ontgrendelt een kluis. Geeft false bij een verkeerd wachtwoord.
  Future<bool> unlock(String root, String password) async {
    root = _norm(root);
    final m = await _readMarker(root);
    final key = await VaultCrypto.deriveKey(
        password, base64.decode(m['salt'] as String), m['iteraties'] as int);
    if (!await VaultCrypto.verifyCheck(key, m['controle'] as String)) {
      return false;
    }
    _keys[root] = key;
    notifyListeners();
    return true;
  }

  void lock(String root) {
    if (_keys.remove(_norm(root)) != null) notifyListeners();
  }

  void lockAll() {
    if (_keys.isEmpty) return;
    _keys.clear();
    notifyListeners();
  }

  Future<List<File>> _files(String root, bool Function(String name) test) async {
    final out = <File>[];
    await for (final e
        in Directory(root).list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name == markerName || name.endsWith('.part')) continue;
      if (test(name)) out.add(e);
    }
    return out;
  }

  /// Onversleutelde bestanden in de kluis (bijv. door een andere app
  /// toegevoegd).
  Future<List<File>> plainFiles(String root) =>
      _files(_norm(root), (n) => !VaultCrypto.isEncryptedName(n));

  /// Versleutelt alle nog onversleutelde bestanden in een ontgrendelde kluis.
  Future<int> encryptPlainFiles(String root, {VaultProgress? onProgress}) async {
    root = _norm(root);
    final key = keyFor(root);
    if (key == null) throw StateError('Kluis is vergrendeld');
    final files = await plainFiles(root);
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      onProgress?.call(i, files.length, p.basename(f.path));
      await encryptInto(f, f.parent.path, key, deleteSource: true);
    }
    onProgress?.call(files.length, files.length, '');
    return files.length;
  }

  /// Ontsleutelt de hele kluis permanent en verwijdert het kluisbestand.
  Future<void> removeVault(String root, {VaultProgress? onProgress}) async {
    root = _norm(root);
    final key = keyFor(root);
    if (key == null) throw StateError('Kluis is vergrendeld');
    final files = await _files(root, VaultCrypto.isEncryptedName);
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      onProgress?.call(i, files.length, p.basename(f.path));
      await decryptInto(f, f.parent.path, key, deleteSource: true);
    }
    await File(p.join(root, markerName)).delete();
    _keys.remove(root);
    notifyListeners();
    onProgress?.call(files.length, files.length, '');
  }

  /// Versleutelt [source] naar map [targetDir]. Geeft het nieuwe bestand.
  static Future<File> encryptInto(File source, String targetDir, SecretKey key,
      {bool deleteSource = false}) async {
    final name = VaultCrypto.encryptedName(p.basename(source.path));
    final target = uniqueFile(targetDir, name);
    await VaultCrypto.encryptFile(source, target, key);
    if (deleteSource) await source.delete();
    return target;
  }

  /// Ontsleutelt [source] naar map [targetDir]. Geeft het nieuwe bestand.
  static Future<File> decryptInto(File source, String targetDir, SecretKey key,
      {bool deleteSource = false, String? name}) async {
    final target = uniqueFile(
        targetDir, name ?? VaultCrypto.plainName(p.basename(source.path)));
    await VaultCrypto.decryptFile(source, target, key);
    if (deleteSource) await source.delete();
    return target;
  }

  /// Een bestandsnaam in [dir] die nog niet bestaat ("foto (1).jpg").
  static File uniqueFile(String dir, String name) {
    var f = File(p.join(dir, name));
    if (!f.existsSync() && !Directory(f.path).existsSync()) return f;
    final enc = VaultCrypto.isEncryptedName(name);
    final base = enc ? VaultCrypto.plainName(name) : name;
    final ext = p.extension(base);
    final stem = p.basenameWithoutExtension(base);
    for (var i = 1;; i++) {
      var candidate = '$stem ($i)$ext';
      if (enc) candidate = VaultCrypto.encryptedName(candidate);
      f = File(p.join(dir, candidate));
      if (!f.existsSync() && !Directory(f.path).existsSync()) return f;
    }
  }
}
