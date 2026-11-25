import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../crypto/vault_manager.dart';
import '../util/format.dart';
import 'storage.dart';

/// Verplaatst nieuwe camerafoto's en -video's automatisch naar een kluis.
///
/// Draait als de app open is en de doelkluis ontgrendeld is (bij het
/// openen van de app en bij het ontgrendelen van die kluis). Alleen
/// bestanden van na het inschakelen worden verplaatst.
class CameraMover {
  CameraMover._();

  static bool _busy = false;

  /// Mappen waarin camera-apps opslaan.
  static Future<List<Directory>> _cameraDirs() async {
    final roots = await Storage.roots();
    return [
      for (final r in roots) Directory(p.join(r.path, 'DCIM', 'Camera')),
    ].where((d) => d.existsSync()).toList();
  }

  /// Geeft het aantal verplaatste bestanden.
  static Future<int> run() async {
    final s = services.settings;
    final target = s.cameraVault;
    final since = s.cameraSince;
    if (_busy || target == null || since == null) return 0;
    final key = services.vaults.keyFor(target);
    if (key == null || !services.vaults.isVaultRoot(target)) return 0;
    _busy = true;
    var moved = 0;
    var newest = since;
    try {
      // Bestanden die nog geschreven worden overslaan.
      final settle = DateTime.now().subtract(const Duration(seconds: 10));
      for (final dir in await _cameraDirs()) {
        await for (final e in dir.list(followLinks: false)) {
          if (e is! File || !isMedia(p.basename(e.path))) continue;
          if (p.basename(e.path).startsWith('.')) continue;
          final m = (await e.stat()).modified;
          if (!m.isAfter(since) || m.isAfter(settle)) continue;
          try {
            await VaultManager.encryptInto(e, target, key, deleteSource: true);
            moved++;
            if (m.isAfter(newest)) newest = m;
          } catch (_) {
            // Volgende keer opnieuw.
          }
        }
      }
      if (newest.isAfter(since)) await s.setCameraSince(newest);
    } finally {
      _busy = false;
    }
    return moved;
  }
}
