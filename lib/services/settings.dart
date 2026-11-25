import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-instellingen (bewaard in SharedPreferences).
class AppSettings extends ChangeNotifier {
  static const _biometricKey = 'instellingen.vingerafdruk';
  static const _autoLockKey = 'instellingen.autoVergrendelMinuten';

  /// Keuzes voor automatisch vergrendelen; 0 = nooit.
  static const autoLockChoices = [1, 5, 15, 30, 0];

  bool _biometric = false;
  int _autoLockMinutes = 5;

  /// Kluizen met vingerafdruk ontgrendelen.
  bool get biometric => _biometric;

  /// Minuten op de achtergrond voordat kluizen vergrendelen; 0 = nooit.
  int get autoLockMinutes => _autoLockMinutes;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _biometric = prefs.getBool(_biometricKey) ?? false;
    _autoLockMinutes = prefs.getInt(_autoLockKey) ?? 5;
    notifyListeners();
  }

  Future<void> setBiometric(bool value) async {
    _biometric = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricKey, value);
  }

  Future<void> setAutoLockMinutes(int value) async {
    _autoLockMinutes = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoLockKey, value);
  }
}
