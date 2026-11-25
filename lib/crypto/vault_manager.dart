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

  /// Schrijft het kluisbestand atomair (eerst naar een tijdelijk bestand).
  Future<void> _writeMarker(String root, Map<String, dynamic> m) async {
    final tmp = File(p.join(root, '$markerName.tmp'));
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(m),
        flush: true);
    await tmp.rename(p.join(root, markerName));
  }

  /// Instellingen van een kluis die zonder sleutel leesbaar zijn.
  Future<VaultInfo> info(String root) async {
    final m = await _readMarker(_norm(root));
    return VaultInfo(
      version: m['versie'] as int? ?? 1,
      encryptedNames: m['namen'] == true,
      hasRecoveryCode: m['herstel'] != null,
    );
  }

  /// Maakt van [dir] een kluis en versleutelt alle bestanden erin. Met
  /// [encryptNames] worden ook de bestandsnamen versleuteld.
  ///
  /// Kluisversie 2: een willekeurige kluissleutel, ingepakt met een sleutel
  /// uit het wachtwoord. Zo kan het wachtwoord later worden gewijzigd zonder
  /// alle bestanden opnieuw te versleutelen.
  Future<void> create(String dir, String password,
      {bool encryptNames = false, VaultProgress? onProgress}) async {
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
    final master = VaultCrypto.randomBytes(32);
    final salt = VaultCrypto.randomBytes(16);
    final kek = await VaultCrypto.deriveKey(password, salt, iterations);
    final marker = <String, dynamic>{
      'versie': 2,
      'kdf': 'pbkdf2-sha256',
      'iteraties': iterations,
      'salt': base64.encode(salt),
      'sleutel': await VaultCrypto.wrapKey(kek, master),
      'controle': await VaultCrypto.makeCheck(SecretKey(master)),
      'namen': encryptNames,
    };
    await _writeMarker(dir, marker);
    await _setKey(dir, master, marker);
    await encryptPlainFiles(dir, onProgress: onProgress);
  }

  Future<void> _setKey(
      String root, List<int> master, Map<String, dynamic> marker) async {
    final names = marker['namen'] == true
        ? await VaultCrypto.deriveNamesKey(SecretKey(master))
        : null;
    _keys[root] = VaultCrypto.vaultKey(master, names: names);
    notifyListeners();
  }

  /// Kluissleutel uit een wachtwoord-achtige geheime waarde, of null.
  Future<List<int>?> _openWith(Map<String, dynamic> wrapper, String secret,
      Map<String, dynamic> marker) async {
    final kek = await VaultCrypto.deriveKey(secret,
        base64.decode(wrapper['salt'] as String), wrapper['iteraties'] as int);
    final List<int>? master;
    if (wrapper['sleutel'] is String) {
      master = await VaultCrypto.unwrapKey(kek, wrapper['sleutel'] as String);
    } else {
      master = await kek.extractBytes(); // versie 1
    }
    if (master == null) return null;
    final ok = await VaultCrypto.verifyCheck(
        SecretKey(master), marker['controle'] as String);
    return ok ? master : null;
  }

  /// Ontgrendelt een kluis. Geeft false bij een verkeerd wachtwoord.
  Future<bool> unlock(String root, String password) async {
    root = _norm(root);
    final m = await _readMarker(root);
    final master = await _openWith(m, password, m);
    if (master == null) return false;
    await _setKey(root, master, m);
    return true;
  }

  /// Ontgrendelt een kluis met een eerder bewaarde sleutel (vingerafdruk).
  /// Geeft false als de sleutel niet (meer) bij de kluis hoort.
  Future<bool> unlockWithKey(String root, SecretKey key) async {
    root = _norm(root);
    final m = await _readMarker(root);
    if (!await VaultCrypto.verifyCheck(key, m['controle'] as String)) {
      return false;
    }
    await _setKey(root, await key.extractBytes(), m);
    return true;
  }

  /// Wijzigt het wachtwoord van een ontgrendelde kluis. De bestanden
  /// blijven ongewijzigd; een kluis van versie 1 wordt versie 2.
  Future<void> changePassword(String root, String newPassword) async {
    root = _norm(root);
    final key = keyFor(root);
    if (key == null) throw StateError('Kluis is vergrendeld');
    if (newPassword.isEmpty) {
      throw ArgumentError('Wachtwoord mag niet leeg zijn');
    }
    final m = await _readMarker(root);
    final salt = VaultCrypto.randomBytes(16);
    final kek = await VaultCrypto.deriveKey(newPassword, salt, iterations);
    m
      ..['versie'] = 2
      ..['iteraties'] = iterations
      ..['salt'] = base64.encode(salt)
      ..['sleutel'] = await VaultCrypto.wrapKey(kek, await key.extractBytes());
    await _writeMarker(root, m);
  }

  static const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static String normalizeRecoveryCode(String code) =>
      code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  /// Maakt een (nieuwe) herstelcode voor een ontgrendelde kluis. Een
  /// eerdere herstelcode werkt daarna niet meer.
  Future<String> createRecoveryCode(String root) async {
    root = _norm(root);
    final key = keyFor(root);
    if (key == null) throw StateError('Kluis is vergrendeld');
    final rnd = VaultCrypto.randomBytes(24);
    final raw = String.fromCharCodes(
        rnd.map((b) => _codeAlphabet.codeUnitAt(b % _codeAlphabet.length)));
    final salt = VaultCrypto.randomBytes(16);
    final kek = await VaultCrypto.deriveKey(raw, salt, iterations);
    final m = await _readMarker(root);
    m['herstel'] = {
      'iteraties': iterations,
      'salt': base64.encode(salt),
      'sleutel': await VaultCrypto.wrapKey(kek, await key.extractBytes()),
    };
    await _writeMarker(root, m);
    // In groepjes van 4 voor de leesbaarheid.
    return [
      for (var i = 0; i < raw.length; i += 4) raw.substring(i, i + 4)
    ].join('-');
  }

  /// Ontgrendelt een kluis met de herstelcode.
  Future<bool> unlockWithRecoveryCode(String root, String code) async {
    root = _norm(root);
    final m = await _readMarker(root);
    final r = m['herstel'];
    if (r is! Map<String, dynamic>) return false;
    final master = await _openWith(r, normalizeRecoveryCode(code), m);
    if (master == null) return false;
    await _setKey(root, master, m);
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
    final target = uniqueFile(targetDir, p.basename(source.path),
        encryptWith: key);
    await VaultCrypto.encryptFile(source, target, key);
    if (deleteSource) await source.delete();
    return target;
  }

  /// Ontsleutelt [source] naar map [targetDir]. Geeft het nieuwe bestand.
  static Future<File> decryptInto(File source, String targetDir, SecretKey key,
      {bool deleteSource = false, String? name}) async {
    final target = uniqueFile(
        targetDir, name ?? VaultCrypto.plainName(p.basename(source.path), key));
    await VaultCrypto.decryptFile(source, target, key);
    if (deleteSource) await source.delete();
    return target;
  }

  /// Een bestand in [dir] dat nog niet bestaat ("foto (1).jpg").
  ///
  /// [name] is de leesbare naam. Met [encryptWith] wordt het resultaat de
  /// versleutelde naam voor die kluissleutel ("foto (1).jpg.bkv" of een
  /// versleutelde naam). Een [name] die al versleuteld is, wordt eerst
  /// teruggezet naar de leesbare naam (met [encryptWith] als sleutel).
  static File uniqueFile(String dir, String name, {SecretKey? encryptWith}) {
    var base = name;
    var enc = encryptWith != null;
    if (VaultCrypto.isEncryptedName(name)) {
      base = VaultCrypto.plainName(name, encryptWith);
      enc = true;
    }
    String real(String plain) =>
        enc ? VaultCrypto.encryptedName(plain, encryptWith) : plain;
    var f = File(p.join(dir, real(base)));
    if (!f.existsSync() && !Directory(f.path).existsSync()) return f;
    final ext = p.extension(base);
    final stem = p.basenameWithoutExtension(base);
    for (var i = 1;; i++) {
      f = File(p.join(dir, real('$stem ($i)$ext')));
      if (!f.existsSync() && !Directory(f.path).existsSync()) return f;
    }
  }
}

/// Instellingen van een kluis.
class VaultInfo {
  const VaultInfo(
      {required this.version,
      required this.encryptedNames,
      required this.hasRecoveryCode});
  final int version;
  final bool encryptedNames;
  final bool hasRecoveryCode;
}
