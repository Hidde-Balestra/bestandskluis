import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Hoe de sleutel van een kluis voor de vingerafdruk is bewaard.
enum BiometricMode {
  /// In een Keystore-sleutel die Android alleen na een geslaagde
  /// vingerafdrukscan vrijgeeft (Android 9+). Een nieuw toegevoegde
  /// vingerafdruk maakt de sleutel ongeldig.
  hardware,

  /// In Keystore-beschermde opslag; de app controleert de vingerafdruk.
  /// Alleen als de hardwaremodus niet beschikbaar is.
  app,
}

/// Kluizen ontgrendelen met de vingerafdruk.
///
/// Na een ontgrendeling met wachtwoord wordt de kluissleutel (niet het
/// wachtwoord) bewaard. Bij voorkeur in een Keystore-sleutel die aan de
/// vingerafdruk gebonden is: zonder scan kan zelfs de app de sleutel niet
/// lezen.
class BiometricUnlock extends ChangeNotifier {
  static const _prefix = 'kluissleutel:';
  static const _modesKey = 'vingerafdruk.modi';

  final _auth = LocalAuthentication();

  /// Oude/terugval-opslag (geen vingerafdruk nodig om te lezen).
  final _soft = const FlutterSecureStorage();

  /// Aan de vingerafdruk gebonden opslag.
  final _hard = const FlutterSecureStorage(
    aOptions: AndroidOptions.biometric(
      enforceBiometrics: true,
      requireBiometricsPerOperation: true,
      biometricType: AndroidBiometricType.strongBiometricOnly,
      storageNamespace: 'kluissleutels_vingerafdruk',
      biometricPromptTitle: 'Kluis ontgrendelen',
      biometricPromptSubtitle: 'Gebruik je vingerafdruk',
      biometricPromptNegativeButton: 'Wachtwoord gebruiken',
    ),
  );

  Map<String, BiometricMode> _modes = {};

  /// Kluizen waarvan een sleutel voor de vingerafdruk is bewaard.
  Set<String> get enrolled => _modes.keys.toSet();

  static String _norm(String root) => p.normalize(root);
  static String _id(String root) => '$_prefix${_norm(root)}';

  bool isEnrolled(String root) => _modes.containsKey(_norm(root));
  BiometricMode? modeOf(String root) => _modes[_norm(root)];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_modesKey);
    _modes = {};
    if (raw != null) {
      (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
        _modes[k] = v == 'hardware' ? BiometricMode.hardware : BiometricMode.app;
      });
    } else {
      // Overstap van v1.2: sleutels in de gewone opslag.
      try {
        final all = await _soft.readAll();
        for (final k in all.keys) {
          if (k.startsWith(_prefix)) {
            _modes[k.substring(_prefix.length)] = BiometricMode.app;
          }
        }
      } catch (_) {}
      await _saveModes();
    }
    notifyListeners();
  }

  Future<void> _saveModes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _modesKey, jsonEncode(_modes.map((k, v) => MapEntry(k, v.name))));
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
  Future<bool> authenticate(String reason, {bool biometricOnly = true}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: biometricOnly,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }

  /// Bewaart de sleutel; vraagt daarbij om de vingerafdruk als de
  /// hardwaremodus wordt gebruikt.
  Future<BiometricMode> saveKey(String root, SecretKey key) async {
    final value = base64.encode(await key.extractBytes());
    BiometricMode mode;
    try {
      await _hard.write(key: _id(root), value: value);
      mode = BiometricMode.hardware;
      await _soft.delete(key: _id(root)).catchError((_) {});
    } catch (_) {
      // Android 7/8 of geen sterke biometrie: terugvallen.
      await _soft.write(key: _id(root), value: value);
      mode = BiometricMode.app;
    }
    _modes[_norm(root)] = mode;
    await _saveModes();
    notifyListeners();
    return mode;
  }

  /// Leest de sleutel na een vingerafdrukscan.
  Future<BiometricResult> unlockKey(String root, String reason) async {
    final mode = modeOf(root);
    if (mode == null) return const BiometricResult.invalid();
    try {
      final String? v;
      if (mode == BiometricMode.hardware) {
        v = await _hard.read(key: _id(root));
      } else {
        if (!await authenticate(reason)) {
          return const BiometricResult.canceled();
        }
        v = await _soft.read(key: _id(root));
      }
      // Geen waarde: de Keystore-sleutel is ongeldig geworden (bijv. een
      // nieuwe vingerafdruk toegevoegd) en de opslag is gewist.
      if (v == null) return const BiometricResult.invalid();
      return BiometricResult(SecretKey(base64.decode(v)));
    } catch (e) {
      final s = e.toString().toLowerCase();
      if (s.contains('invalidated') || s.contains('permanently')) {
        return const BiometricResult.invalid();
      }
      return const BiometricResult.canceled();
    }
  }

  Future<void> removeKey(String root) async {
    await _hard.delete(key: _id(root)).catchError((_) {});
    await _soft.delete(key: _id(root)).catchError((_) {});
    _modes.remove(_norm(root));
    await _saveModes();
    notifyListeners();
  }

  /// Alle bewaarde kluissleutels wissen.
  Future<void> removeAll() async {
    for (final root in _modes.keys.toList()) {
      await removeKey(root);
    }
  }
}

/// Uitkomst van ontgrendelen met de vingerafdruk.
class BiometricResult {
  const BiometricResult(SecretKey this.key) : invalid = false;
  const BiometricResult.canceled()
      : key = null,
        invalid = false;
  const BiometricResult.invalid()
      : key = null,
        invalid = true;

  final SecretKey? key;

  /// De bewaarde sleutel is niet meer bruikbaar; opnieuw aanmelden nodig.
  final bool invalid;
}
