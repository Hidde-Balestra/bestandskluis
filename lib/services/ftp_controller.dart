import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../crypto/vault_manager.dart';
import '../ftp/ftp_server.dart';

class SavedConnection {
  const SavedConnection(
      {required this.host, this.port = 21, this.user = '', this.label = ''});
  final String host;
  final int port;
  final String user;
  final String label;

  String encode() => [host, port, user, label].join('\u0001');
  static SavedConnection? decode(String s) {
    final parts = s.split('\u0001');
    if (parts.length < 4) return null;
    return SavedConnection(
        host: parts[0],
        port: int.tryParse(parts[1]) ?? 21,
        user: parts[2],
        label: parts[3]);
  }
}

/// Bewaart de instellingen van de FTP-server en bestuurt hem.
class FtpController extends ChangeNotifier {
  FtpController(this.vaults);

  final VaultManager vaults;

  FtpServerConfig config =
      const FtpServerConfig(rootPath: '/storage/emulated/0');
  bool keepScreenOn = true;
  List<SavedConnection> saved = [];

  FtpServer? _server;
  StreamSubscription<FtpEvent>? _sub;
  final List<FtpEvent> log = [];
  String? error;

  bool get isRunning => _server?.isRunning ?? false;
  int get clientCount => _server?.clientCount ?? 0;

  static String randomPassword() {
    const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<void> load(String defaultRoot) async {
    final prefs = await SharedPreferences.getInstance();
    var password = prefs.getString('ftp.password');
    if (password == null || password.isEmpty) {
      password = randomPassword();
      await prefs.setString('ftp.password', password);
    }
    config = FtpServerConfig(
      rootPath: prefs.getString('ftp.root') ?? defaultRoot,
      port: prefs.getInt('ftp.port') ?? 2121,
      username: prefs.getString('ftp.user') ?? 'gebruiker',
      password: password,
      allowAnonymous: prefs.getBool('ftp.anonymous') ?? false,
      readOnly: prefs.getBool('ftp.readOnly') ?? false,
      decryptVaults: prefs.getBool('ftp.decrypt') ?? true,
    );
    keepScreenOn = prefs.getBool('ftp.wakelock') ?? true;
    saved = (prefs.getStringList('ftp.saved') ?? [])
        .map(SavedConnection.decode)
        .whereType<SavedConnection>()
        .toList();
    notifyListeners();
  }

  Future<void> save(FtpServerConfig c, {bool? wakelock}) async {
    config = c;
    if (wakelock != null) keepScreenOn = wakelock;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ftp.root', c.rootPath);
    await prefs.setInt('ftp.port', c.port);
    await prefs.setString('ftp.user', c.username);
    await prefs.setString('ftp.password', c.password);
    await prefs.setBool('ftp.anonymous', c.allowAnonymous);
    await prefs.setBool('ftp.readOnly', c.readOnly);
    await prefs.setBool('ftp.decrypt', c.decryptVaults);
    await prefs.setBool('ftp.wakelock', keepScreenOn);
    notifyListeners();
    if (isRunning) {
      await stop();
      await start();
    }
  }

  Future<void> saveConnection(SavedConnection c) async {
    saved = [
      c,
      ...saved.where((s) => !(s.host == c.host && s.port == c.port)),
    ].take(10).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'ftp.saved', saved.map((s) => s.encode()).toList());
    notifyListeners();
  }

  Future<void> removeConnection(SavedConnection c) async {
    saved = saved.where((s) => s != c).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'ftp.saved', saved.map((s) => s.encode()).toList());
    notifyListeners();
  }

  Future<void> start() async {
    if (isRunning) return;
    error = null;
    final server = FtpServer(config: config, vaults: vaults);
    _sub = server.events.listen((e) {
      log.insert(0, e);
      if (log.length > 200) log.removeLast();
      notifyListeners();
    });
    try {
      await server.start();
      _server = server;
      if (keepScreenOn) await WakelockPlus.enable().catchError((_) {});
    } on SocketException catch (e) {
      error = 'Poort ${config.port} is niet beschikbaar (${e.osError?.message ?? e.message})';
      await _sub?.cancel();
    } catch (e) {
      error = '$e';
      await _sub?.cancel();
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.dispose();
    await _sub?.cancel();
    _sub = null;
    await WakelockPlus.disable().catchError((_) {});
    notifyListeners();
  }

  /// IPv4-adressen waarop de server bereikbaar is.
  static Future<List<String>> localAddresses() async {
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      final out = <String>[];
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.isLinkLocal) out.add(a.address);
        }
      }
      // Wifi (wlan) bovenaan
      out.sort((a, b) => (a.startsWith('192.168.') ? 0 : 1)
          .compareTo(b.startsWith('192.168.') ? 0 : 1));
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
