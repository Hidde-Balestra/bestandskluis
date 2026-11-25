import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-instellingen (bewaard in SharedPreferences).
class AppSettings extends ChangeNotifier {
  static const _biometricKey = 'instellingen.vingerafdruk';
  static const _autoLockKey = 'instellingen.autoVergrendelMinuten';
  static const _intruderKey = 'instellingen.indringersfoto';
  static const _secureScreenKey = 'instellingen.schermbeveiliging';
  static const _cameraVaultKey = 'instellingen.cameraNaarKluis';
  static const _cameraSinceKey = 'instellingen.cameraSinds';
  static const _sortKey = 'instellingen.sorteren';

  /// Keuzes voor automatisch vergrendelen; 0 = nooit.
  static const autoLockChoices = [1, 5, 15, 30, 0];

  late SharedPreferences _prefs;
  bool _biometric = false;
  int _autoLockMinutes = 5;
  bool _intruderPhoto = false;
  bool _secureScreen = true;
  String? _cameraVault;
  DateTime? _cameraSince;
  String _sort = 'naam';

  /// Kluizen met vingerafdruk ontgrendelen.
  bool get biometric => _biometric;

  /// Minuten op de achtergrond voordat kluizen vergrendelen; 0 = nooit.
  int get autoLockMinutes => _autoLockMinutes;

  /// Foto met de voorcamera bij herhaald verkeerd wachtwoord.
  bool get intruderPhoto => _intruderPhoto;

  /// Schermafbeeldingen blokkeren en app verbergen in "recente apps" zolang
  /// een kluis open is.
  bool get secureScreen => _secureScreen;

  /// Kluis waar nieuwe camerafoto's automatisch heen gaan (of null).
  String? get cameraVault => _cameraVault;

  /// Alleen foto's van na dit moment worden automatisch verplaatst.
  DateTime? get cameraSince => _cameraSince;

  /// Sortering in de bestandsbrowser: naam, datum, grootte (met "-" ervoor
  /// = aflopend).
  String get sort => _sort;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _biometric = _prefs.getBool(_biometricKey) ?? false;
    _autoLockMinutes = _prefs.getInt(_autoLockKey) ?? 5;
    _intruderPhoto = _prefs.getBool(_intruderKey) ?? false;
    _secureScreen = _prefs.getBool(_secureScreenKey) ?? true;
    _cameraVault = _prefs.getString(_cameraVaultKey);
    final since = _prefs.getInt(_cameraSinceKey);
    _cameraSince =
        since == null ? null : DateTime.fromMillisecondsSinceEpoch(since);
    _sort = _prefs.getString(_sortKey) ?? 'naam';
    notifyListeners();
  }

  Future<void> setBiometric(bool value) async {
    _biometric = value;
    notifyListeners();
    await _prefs.setBool(_biometricKey, value);
  }

  Future<void> setAutoLockMinutes(int value) async {
    _autoLockMinutes = value;
    notifyListeners();
    await _prefs.setInt(_autoLockKey, value);
  }

  Future<void> setIntruderPhoto(bool value) async {
    _intruderPhoto = value;
    notifyListeners();
    await _prefs.setBool(_intruderKey, value);
  }

  Future<void> setSecureScreen(bool value) async {
    _secureScreen = value;
    notifyListeners();
    await _prefs.setBool(_secureScreenKey, value);
  }

  Future<void> setCameraVault(String? root) async {
    _cameraVault = root;
    if (root == null) {
      await _prefs.remove(_cameraVaultKey);
      await _prefs.remove(_cameraSinceKey);
      _cameraSince = null;
    } else {
      await _prefs.setString(_cameraVaultKey, root);
      _cameraSince = DateTime.now();
      await _prefs.setInt(_cameraSinceKey, _cameraSince!.millisecondsSinceEpoch);
    }
    notifyListeners();
  }

  Future<void> setCameraSince(DateTime t) async {
    _cameraSince = t;
    await _prefs.setInt(_cameraSinceKey, t.millisecondsSinceEpoch);
  }

  Future<void> setSort(String value) async {
    _sort = value;
    notifyListeners();
    await _prefs.setString(_sortKey, value);
  }
}
