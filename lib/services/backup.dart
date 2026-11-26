import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';
import '../ftp/ftp_client.dart';
import 'ftp_controller.dart';

/// Resultaat van een back-up.
class BackupResult {
  BackupResult({this.uploaded = 0, this.unchanged = 0, this.errors = const []});
  int uploaded;
  int unchanged;
  List<String> errors;

  String get summary => errors.isEmpty
      ? '$uploaded bijgewerkt, $unchanged ongewijzigd'
      : '$uploaded bijgewerkt, ${errors.length} mislukt: ${errors.first}';
}

/// Zet de versleutelde kluisbestanden op een FTP-server.
///
/// Alleen versleutelde bestanden (`.bkv`/`.bkx`) en het kluisbestand worden
/// verstuurd, precies zoals ze op de telefoon staan. De kluis hoeft dus niet
/// ontgrendeld te zijn en de server ziet nooit iets onversleuteld. Bestanden
/// die al met dezelfde grootte op de server staan worden overgeslagen;
/// verwijderde bestanden blijven op de server staan.
class VaultBackup {
  VaultBackup._();

  static bool _include(String name) =>
      name == VaultManager.markerName ||
      (VaultCrypto.isEncryptedName(name) && !name.endsWith('.part'));

  static Future<void> _ensureDir(FtpClient c, String dir) async {
    var cur = '';
    for (final seg in dir.split('/').where((s) => s.isNotEmpty)) {
      cur = '$cur/$seg';
      try {
        await c.mkdir(cur);
      } on FtpException {
        // Bestaat al.
      }
    }
  }

  static Future<BackupResult> run(
    FtpClient c,
    List<String> vaultRoots,
    String remoteBase, {
    void Function(String name)? onFile,
  }) async {
    final result = BackupResult(errors: []);
    final base = remoteBase.startsWith('/') ? remoteBase : '/$remoteBase';
    for (final root in vaultRoots) {
      if (!File(p.join(root, VaultManager.markerName)).existsSync()) {
        result.errors.add('${p.basename(root)}: geen kluis meer');
        continue;
      }
      final remoteRoot = p.posix.join(base, p.basename(root));
      // Bestanden per map verzamelen.
      final byDir = <String, List<File>>{};
      await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
        if (e is! File || !_include(p.basename(e.path))) continue;
        if (p.split(e.path).contains(VaultManager.trashDirName)) continue;
        final rel = p.relative(e.parent.path, from: root);
        final dir = rel == '.'
            ? remoteRoot
            : p.posix.join(remoteRoot, p.split(rel).join('/'));
        byDir.putIfAbsent(dir, () => []).add(e);
      }
      for (final MapEntry(key: dir, value: files) in byDir.entries) {
        await _ensureDir(c, dir);
        final remote = <String, int>{};
        try {
          for (final r in await c.list(dir)) {
            if (!r.isDir) remote[r.name] = r.size;
          }
        } on FtpException {
          // Lege of onleesbare map: alles uploaden.
        }
        for (final f in files) {
          final name = p.basename(f.path);
          final size = await f.length();
          // Het kluisbestand is klein en kan veranderen zonder dat de
          // grootte verandert (nieuw wachtwoord): altijd versturen.
          if (name != VaultManager.markerName && remote[name] == size) {
            result.unchanged++;
            continue;
          }
          onFile?.call(name);
          try {
            await c.upload(f, p.posix.join(dir, name));
            result.uploaded++;
          } catch (e) {
            result.errors.add('$name: $e');
          }
        }
      }
    }
    return result;
  }
}

/// Een kluis terughalen van de back-upserver.
class VaultRestore {
  VaultRestore._();

  /// Mappen (kluizen) in de back-upmap op de server.
  static Future<List<String>> remoteVaults(FtpClient c, String remoteBase) async {
    final base = remoteBase.startsWith('/') ? remoteBase : '/$remoteBase';
    final list = await c.list(base);
    return [
      for (final e in list)
        if (e.isDir && e.name != '.' && e.name != '..') e.name
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Downloadt [remoteVaultDir] naar een nieuwe map in [localParent] en
  /// geeft het pad van de teruggezette kluis. De bestanden blijven
  /// versleuteld; ontgrendelen gaat met het wachtwoord (of de herstelcode).
  static Future<String> restore(
      FtpClient c, String remoteVaultDir, String localParent,
      {void Function(String name)? onFile}) async {
    final name = p.posix.basename(remoteVaultDir);
    final target = VaultManager.uniqueFile(localParent, name).path;

    Future<void> walk(String remote, String local) async {
      await Directory(local).create(recursive: true);
      for (final e in await c.list(remote)) {
        if (e.name == '.' || e.name == '..' || e.name.endsWith('.part')) {
          continue;
        }
        if (e.isDir) {
          if (e.name == VaultManager.trashDirName) continue;
          await walk(p.posix.join(remote, e.name), p.join(local, e.name));
        } else {
          onFile?.call(e.name);
          await c.download(
              p.posix.join(remote, e.name), File(p.join(local, e.name)));
        }
      }
    }

    try {
      await walk(remoteVaultDir, target);
      // Een Bestandskluis-server toont het kluisbestand niet in de lijst:
      // dan apart ophalen.
      final marker = File(p.join(target, VaultManager.markerName));
      if (!await marker.exists()) {
        try {
          await c.download(
              p.posix.join(remoteVaultDir, VaultManager.markerName), marker);
        } on FtpException {
          // Ontbreekt.
        }
      }
      if (!await marker.exists()) {
        throw StateError('Dit is geen kluis-back-up (het kluisbestand ontbreekt)');
      }
      return target;
    } catch (_) {
      final d = Directory(target);
      if (await d.exists()) await d.delete(recursive: true);
      rethrow;
    }
  }
}

/// Instellingen en planning van automatische back-ups.
class BackupService extends ChangeNotifier {
  static const taskName = 'kluisBackup';
  static const _uniqueName = 'kluis-backup';
  static const _kConn = 'backup.verbinding';
  static const _kDir = 'backup.map';
  static const _kVaults = 'backup.kluizen';
  static const _kEnabled = 'backup.aan';
  static const _kLast = 'backup.laatste';
  static const _kResult = 'backup.resultaat';

  SavedConnection? connection;
  String remoteDir = '/Bestandskluis-backup';
  List<String> vaults = [];
  bool enabled = false;
  DateTime? lastRun;
  String? lastResult;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final c = prefs.getString(_kConn);
    connection = c == null ? null : SavedConnection.decode(c);
    remoteDir = prefs.getString(_kDir) ?? remoteDir;
    vaults = prefs.getStringList(_kVaults) ?? [];
    enabled = prefs.getBool(_kEnabled) ?? false;
    final last = prefs.getInt(_kLast);
    lastRun = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    lastResult = prefs.getString(_kResult);
    notifyListeners();
  }

  Future<void> save({
    SavedConnection? connection,
    String? remoteDir,
    List<String>? vaults,
    bool? enabled,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (connection != null) {
      this.connection = connection;
      await prefs.setString(_kConn, connection.encode());
    }
    if (remoteDir != null) {
      this.remoteDir = remoteDir;
      await prefs.setString(_kDir, remoteDir);
    }
    if (vaults != null) {
      this.vaults = vaults;
      await prefs.setStringList(_kVaults, vaults);
    }
    if (enabled != null) {
      this.enabled = enabled;
      await prefs.setBool(_kEnabled, enabled);
    }
    notifyListeners();
    await _schedule();
  }

  Future<void> _schedule() async {
    if (!Platform.isAndroid) return;
    try {
      if (enabled && connection != null && vaults.isNotEmpty) {
        await Workmanager().registerPeriodicTask(_uniqueName, taskName,
            frequency: const Duration(hours: 24),
            initialDelay: const Duration(minutes: 15),
            existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
            constraints: Constraints(
                networkType: NetworkType.unmetered,
                requiresBatteryNotLow: true));
      } else {
        await Workmanager().cancelByUniqueName(_uniqueName);
      }
    } catch (_) {
      // Planner niet beschikbaar; handmatig back-uppen blijft werken.
    }
  }

  /// Verbinden met de ingestelde back-upserver.
  static Future<(FtpClient, String)> connectConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kConn);
    final conn = raw == null ? null : SavedConnection.decode(raw);
    if (conn == null) throw StateError('Stel eerst een back-upserver in');
    final password = await FtpController.savedPassword(conn) ?? '';
    final client = await FtpClient.connect(conn.host,
        port: conn.port,
        user: conn.user.isEmpty ? 'anonymous' : conn.user,
        password: conn.user.isEmpty ? 'gast@' : password,
        tls: conn.tls,
        pinnedFingerprint: conn.fingerprint);
    return (client, prefs.getString(_kDir) ?? '/Bestandskluis-backup');
  }

  /// Back-up nu uitvoeren met de opgeslagen instellingen.
  static Future<BackupResult> runConfigured(
      {void Function(String)? onFile}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_kConn);
    final conn = raw == null ? null : SavedConnection.decode(raw);
    final roots = prefs.getStringList(_kVaults) ?? [];
    if (conn == null || roots.isEmpty) {
      throw StateError('Stel eerst een server en kluizen in');
    }
    final password = await FtpController.savedPassword(conn) ?? '';
    BackupResult result;
    try {
      final client = await FtpClient.connect(conn.host,
          port: conn.port,
          user: conn.user.isEmpty ? 'anonymous' : conn.user,
          password: conn.user.isEmpty ? 'gast@' : password,
          tls: conn.tls,
          pinnedFingerprint: conn.fingerprint);
      if (conn.tls && conn.fingerprint == null) {
        await prefs.setString(
            _kConn, conn.copyWith(fingerprint: client.fingerprint).encode());
      }
      try {
        result = await VaultBackup.run(
            client, roots, prefs.getString(_kDir) ?? '/Bestandskluis-backup',
            onFile: onFile);
      } finally {
        await client.quit();
      }
    } catch (e) {
      result = BackupResult(errors: ['$e']);
    }
    await prefs.setInt(_kLast, DateTime.now().millisecondsSinceEpoch);
    await prefs.setString(_kResult, result.summary);
    return result;
  }
}

/// Startpunt voor de achtergrondtaak (WorkManager).
@pragma('vm:entry-point')
void backupDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    if (task != BackupService.taskName) return true;
    final r = await BackupService.runConfigured();
    // Bij een netwerkfout later opnieuw proberen.
    return r.errors.isEmpty || r.uploaded > 0;
  });
}
