import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/vault_manager.dart';

/// Onthoudt welke kluizen er op het toestel zijn, zodat ze op het
/// startscherm staan (ook als ze vergrendeld zijn).
class KnownVaults extends ChangeNotifier {
  KnownVaults(this.vaults);

  static const _prefsKey = 'kluizen.bekend';

  final VaultManager vaults;
  List<String> _paths = [];

  /// Bekende kluizen die nog bestaan, op naam gesorteerd.
  List<String> get paths {
    final list = _paths.where(vaults.isVaultRoot).toList()
      ..sort((a, b) =>
          p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    return list;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _paths = prefs.getStringList(_prefsKey) ?? [];
    notifyListeners();
  }

  Future<void> _save() async {
    _paths = _paths.where(vaults.isVaultRoot).toSet().toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _paths);
    notifyListeners();
  }

  Future<void> add(String path) async {
    path = p.normalize(path);
    if (_paths.contains(path)) return;
    _paths.add(path);
    await _save();
  }

  Future<void> remove(String path) async {
    _paths.remove(p.normalize(path));
    await _save();
  }
}
