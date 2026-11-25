import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class StorageRoot {
  const StorageRoot(this.name, this.path);
  final String name;
  final String path;
}

/// Toegang tot de opslag van het apparaat.
class Storage {
  Storage._();

  /// Vraagt volledige bestandstoegang (Android 11+: "Toegang tot alle
  /// bestanden"; ouder: lees/schrijfrechten).
  static Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return true;
    if (await hasPermission()) return true;
    final manage = await Permission.manageExternalStorage.request();
    if (manage.isGranted) return true;
    final legacy = await Permission.storage.request();
    return legacy.isGranted;
  }

  static Future<bool> hasPermission() async {
    if (!Platform.isAndroid) return true;
    return await Permission.manageExternalStorage.isGranted ||
        await Permission.storage.isGranted;
  }

  /// Interne opslag en eventuele SD-kaarten.
  static Future<List<StorageRoot>> roots() async {
    if (!Platform.isAndroid) {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.current.path;
      return [StorageRoot('Thuismap', home)];
    }
    final dirs = await getExternalStorageDirectories() ?? [];
    final roots = <StorageRoot>[];
    for (final d in dirs) {
      final i = d.path.indexOf('/Android/');
      final path = i > 0 ? d.path.substring(0, i) : d.path;
      if (roots.any((r) => r.path == path)) continue;
      roots.add(StorageRoot(
          path == '/storage/emulated/0' || roots.isEmpty
              ? 'Interne opslag'
              : 'SD-kaart (${p.basename(path)})',
          path));
    }
    if (roots.isEmpty) {
      roots.add(const StorageRoot('Interne opslag', '/storage/emulated/0'));
    }
    return roots;
  }

  static Future<String> downloadDir() async {
    final roots = await Storage.roots();
    final d = Directory(p.join(roots.first.path, 'Download'));
    if (await d.exists()) return d.path;
    return (await getApplicationDocumentsDirectory()).path;
  }
}
