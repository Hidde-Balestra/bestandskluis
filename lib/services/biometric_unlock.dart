import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;

/// Kluizen ontgrendelen met de vingerafdruk.
///
/// Na een ontgrendeling met wachtwoord wordt de kluissleutel (niet het
/// wachtwoord) bewaard in versleutelde opslag die door de Android Keystore
/// wordt beschermd. Die sleutel wordt pas gebruikt na een geslaagde
/// vingerafdrukcontrole.
class BiometricUnlock extends ChangeNotifier {
  static const _prefix = 'kluissleutel:';

  final _auth = LocalAuthentication();
  final _store = const FlutterSecureStorage();

  Set<String> _enrolled = {};

  /// Kluizen waarvan een sleutel voor de vingerafdruk is bewaard.
  Set<String> get enrolled => Set.unmodifiable(_enrolled);

  static String _id(String root) => '$_prefix${p.normalize(root)}';

  bool isEnrolled(String root) => _enrolled.contains(p.normalize(root));

  Future<void> load() async {
    try {
      final all = await _store.readAll();
      _enrolled = {
        for (final k in all.keys)
          if (k.startsWith(_prefix)) k.substring(_prefix.length)
      };
    } catch (_) {
      _enrolled = {};
    }
    notifyListeners();
  }

  /// Of het toestel een vingerafdruk (of andere sterke biometrie) heeft
  /// ingesteld.
  Future<bool> available() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      final types = await _auth.getAvailableBiometrics();
      return types.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Toont de vingerafdrukprompt van het systeem.
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> saveKey(String root, SecretKey key) async {
    final bytes = await key.extractBytes();
    await _store.write(key: _id(root), value: base64.encode(bytes));
    _enrolled.add(p.normalize(root));
    notifyListeners();
  }

  Future<SecretKey?> readKey(String root) async {
    try {
      final v = await _store.read(key: _id(root));
      return v == null ? null : SecretKey(base64.decode(v));
    } catch (_) {
      return null;
    }
  }

  Future<void> removeKey(String root) async {
    try {
      await _store.delete(key: _id(root));
    } catch (_) {}
    _enrolled.remove(p.normalize(root));
    notifyListeners();
  }

  /// Alle bewaarde kluissleutels wissen.
  Future<void> removeAll() async {
    for (final root in _enrolled.toList()) {
      await removeKey(root);
    }
  }
}
