import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../crypto/vault_manager.dart';
import '../ftp/ftp_client.dart';
import '../ftp/ftp_server.dart';
import '../ftp/ftp_tls.dart';
import 'system_bridge.dart';

/// Een eerder gebruikte (of voor back-ups ingestelde) FTP-verbinding.
class SavedConnection {
  const SavedConnection({
    required this.host,
    this.port = 21,
    this.user = '',
    this.label = '',
    this.tls = false,
    this.fingerprint,
  });

  final String host;
  final int port;
  final String user;
  final String label;

  /// FTPS (AUTH TLS).
  final bool tls;

  /// Vastgepinde certificaatvingerafdruk (na de eerste verbinding).
  final String? fingerprint;

  String get id => '$host:$port';

  SavedConnection copyWith({String? fingerprint, bool? tls}) => SavedConnection(
      host: host,
      port: port,
      user: user,
      label: label,
      tls: tls ?? this.tls,
      fingerprint: fingerprint ?? this.fingerprint);

  String encode() =>
      [host, port, user, label, tls ? '1' : '0', fingerprint ?? ''].join('\u0001');

  static SavedConnection? decode(String s) {
    final parts = s.split('\u0001');
    if (parts.length < 4) return null;
    return SavedConnection(
        host: parts[0],
        port: int.tryParse(parts[1]) ?? 21,
        user: parts[2],
        label: parts[3],
        tls: parts.length > 4 && parts[4] == '1',
        fingerprint: parts.length > 5 && parts[5].isNotEmpty ? parts[5] : null);
  }

  /// Uit een ftp://- of ftps://-link (bijv. een QR-code). Het wachtwoord
  /// komt in [password] terecht.
  static (SavedConnection, String?)? fromUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || (u.scheme != 'ftp' && u.scheme != 'ftps') || u.host.isEmpty) {
      return null;
    }
    String user = '';
    String? password;
    if (u.userInfo.isNotEmpty) {
      final i = u.userInfo.indexOf(':');
      user = Uri.decodeComponent(i < 0 ? u.userInfo : u.userInfo.substring(0, i));
      if (i >= 0) password = Uri.decodeComponent(u.userInfo.substring(i + 1));
    }
    // Vingerafdruk als hex zonder dubbele punten; terug naar "AB:CD:…".
    final hex = (u.queryParameters['fp'] ?? '')
        .toUpperCase()
        .replaceAll(RegExp('[^0-9A-F]'), '');
    final fp = hex.length == 64
        ? [for (var i = 0; i < 64; i += 2) hex.substring(i, i + 2)].join(':')
        : null;
    return (
      SavedConnection(
          host: u.host,
          port: u.hasPort ? u.port : 21,
          user: user,
          tls: u.scheme == 'ftps',
          fingerprint: fp),
      password
    );
  }
}

/// Bewaart de instellingen van de FTP-server en bestuurt hem.
class FtpController extends ChangeNotifier {
  FtpController(this.vaults);

  final VaultManager vaults;
  static const _secure = FlutterSecureStorage();

  FtpServerConfig config =
      const FtpServerConfig(rootPath: '/storage/emulated/0');
  bool keepScreenOn = false;

  /// Server laten doorlopen op de achtergrond (voorgronddienst met melding).
  bool background = true;
  List<SavedConnection> saved = [];

  /// Certificaat voor FTPS (wordt bij de eerste start gemaakt).
  FtpTlsIdentity? identity;

  FtpServer? _server;
  StreamSubscription<FtpEvent>? _sub;
  final List<FtpEvent> log = [];
  String? error;

  bool get isRunning => _server?.isRunning ?? false;
  int get clientCount => _server?.clientCount ?? 0;
  int get port => _server?.port ?? config.port;

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
      tls: FtpTls.values[(prefs.getInt('ftp.tls') ?? FtpTls.optional.index)
          .clamp(0, FtpTls.values.length - 1)],
    );
    keepScreenOn = prefs.getBool('ftp.wakelock') ?? false;
    background = prefs.getBool('ftp.achtergrond') ?? true;
    saved = (prefs.getStringList('ftp.saved') ?? [])
        .map(SavedConnection.decode)
        .whereType<SavedConnection>()
        .toList();
    notifyListeners();
  }

  Future<void> save(FtpServerConfig c,
      {bool? wakelock, bool? inBackground}) async {
    config = c;
    if (wakelock != null) keepScreenOn = wakelock;
    if (inBackground != null) background = inBackground;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ftp.root', c.rootPath);
    await prefs.setInt('ftp.port', c.port);
    await prefs.setString('ftp.user', c.username);
    await prefs.setString('ftp.password', c.password);
    await prefs.setBool('ftp.anonymous', c.allowAnonymous);
    await prefs.setBool('ftp.readOnly', c.readOnly);
    await prefs.setBool('ftp.decrypt', c.decryptVaults);
    await prefs.setInt('ftp.tls', c.tls.index);
    await prefs.setBool('ftp.wakelock', keepScreenOn);
    await prefs.setBool('ftp.achtergrond', background);
    notifyListeners();
    if (isRunning) {
      await stop();
      await start();
    }
  }

  // --- Opgeslagen verbindingen ----------------------------------------------

  Future<void> _saveList() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'ftp.saved', saved.map((s) => s.encode()).toList());
    notifyListeners();
  }

  Future<void> saveConnection(SavedConnection c) async {
    saved = [
      c,
      ...saved.where((s) => s.id != c.id),
    ].take(10).toList();
    await _saveList();
  }

  Future<void> removeConnection(SavedConnection c) async {
    saved = saved.where((s) => s.id != c.id).toList();
    await forgetPassword(c);
    await _saveList();
  }

  static String _pwKey(SavedConnection c) => 'ftp.wachtwoord:${c.id}:${c.user}';

  static Future<void> rememberPassword(SavedConnection c, String pw) =>
      _secure.write(key: _pwKey(c), value: pw);

  static Future<String?> savedPassword(SavedConnection c) async {
    try {
      return await _secure.read(key: _pwKey(c));
    } catch (_) {
      return null;
    }
  }

  static Future<void> forgetPassword(SavedConnection c) async {
    try {
      await _secure.delete(key: _pwKey(c));
    } catch (_) {}
  }

  /// Verbindt met [c]. Bij FTPS wordt het certificaat de eerste keer
  /// onthouden en daarna gecontroleerd.
  Future<FtpClient> connect(SavedConnection c, String password,
      {bool remember = false}) async {
    final client = await FtpClient.connect(c.host,
        port: c.port,
        user: c.user.isEmpty ? 'anonymous' : c.user,
        password: c.user.isEmpty ? 'gast@' : password,
        tls: c.tls,
        pinnedFingerprint: c.fingerprint);
    await saveConnection(
        c.tls ? c.copyWith(fingerprint: client.fingerprint) : c);
    if (remember && c.user.isNotEmpty) await rememberPassword(c, password);
    return client;
  }

  /// Vergeet het onthouden certificaat (als de server echt een nieuw
  /// certificaat heeft).
  Future<void> resetFingerprint(SavedConnection c) => saveConnection(
      SavedConnection(
          host: c.host, port: c.port, user: c.user, label: c.label, tls: c.tls));

  // --- Server ---------------------------------------------------------------

  Future<FtpTlsIdentity?> _loadIdentity() async {
    if (identity != null) return identity;
    try {
      final dir = await getApplicationSupportDirectory();
      identity = await FtpTlsIdentity.loadOrCreate(
          Directory(p.join(dir.path, 'ftps')));
    } catch (e) {
      identity = null;
    }
    return identity;
  }

  /// Link voor clients (en de QR-code).
  String link(String address, {bool withPassword = false}) {
    final tls = config.tls != FtpTls.off && identity != null;
    final user = config.allowAnonymous ? '' : config.username;
    final info = user.isEmpty
        ? ''
        : '${Uri.encodeComponent(user)}'
            '${withPassword ? ':${Uri.encodeComponent(config.password)}' : ''}@';
    final fp = tls ? '?fp=${identity!.fingerprint.replaceAll(':', '')}' : '';
    return '${tls ? 'ftps' : 'ftp'}://$info$address:$port$fp';
  }

  Future<void> start() async {
    if (isRunning) return;
    error = null;
    final id = config.tls == FtpTls.off ? null : await _loadIdentity();
    final server = FtpServer(
        config: config, vaults: vaults, securityContext: id?.context());
    _sub = server.events.listen((e) {
      log.insert(0, e);
      if (log.length > 200) log.removeLast();
      notifyListeners();
    });
    try {
      await server.start();
      _server = server;
      if (keepScreenOn) await WakelockPlus.enable().catchError((_) {});
      if (background) {
        await Permission.notification.request().catchError((_) => PermissionStatus.denied);
        final addrs = await localAddresses();
        await SystemBridge.startServerService(addrs.isEmpty
            ? 'Actief op poort ${server.port}'
            : 'Bereikbaar op ${addrs.first}:${server.port}');
      }
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
    await SystemBridge.stopServerService();
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
