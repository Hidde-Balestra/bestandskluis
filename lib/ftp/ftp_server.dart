import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';
import 'ftp_format.dart';

class FtpServerConfig {
  const FtpServerConfig({
    required this.rootPath,
    this.port = 2121,
    this.username = 'gebruiker',
    this.password = '',
    this.allowAnonymous = false,
    this.readOnly = false,
    this.decryptVaults = true,
  });

  final String rootPath;
  final int port;
  final String username;
  final String password;
  final bool allowAnonymous;
  final bool readOnly;

  /// Bestanden in ontgrendelde kluizen worden tijdens het downloaden
  /// ontsleuteld (en uploads versleuteld). Op schijf blijft alles versleuteld.
  final bool decryptVaults;

  FtpServerConfig copyWith({
    String? rootPath,
    int? port,
    String? username,
    String? password,
    bool? allowAnonymous,
    bool? readOnly,
    bool? decryptVaults,
  }) =>
      FtpServerConfig(
        rootPath: rootPath ?? this.rootPath,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        allowAnonymous: allowAnonymous ?? this.allowAnonymous,
        readOnly: readOnly ?? this.readOnly,
        decryptVaults: decryptVaults ?? this.decryptVaults,
      );
}

class FtpEvent {
  FtpEvent(this.message, {this.client}) : time = DateTime.now();
  final DateTime time;
  final String message;
  final String? client;
}

/// Eenvoudige, zelfstandige FTP-server (RFC 959 + MLSD/EPSV/SIZE/MDTM/REST).
///
/// Ontgrendelde kluizen worden transparant aangeboden: `foto.jpg.bkv` verschijnt
/// als `foto.jpg` en wordt ontsleuteld tijdens de overdracht. Op de schijf
/// wordt niets ontsleuteld opgeslagen.
class FtpServer {
  FtpServer({required this.config, required this.vaults, this.bindAddress});

  final FtpServerConfig config;
  final VaultAccess vaults;

  /// Standaard alle IPv4-adressen.
  final InternetAddress? bindAddress;

  ServerSocket? _server;
  final _sessions = <_Session>{};
  final _events = StreamController<FtpEvent>.broadcast();

  Stream<FtpEvent> get events => _events.stream;
  bool get isRunning => _server != null;
  int get port => _server?.port ?? config.port;
  int get clientCount => _sessions.length;

  Future<void> start() async {
    if (_server != null) return;
    final root = Directory(config.rootPath);
    if (!await root.exists()) {
      throw FileSystemException('Hoofdmap bestaat niet', config.rootPath);
    }
    _server = await ServerSocket.bind(
        bindAddress ?? InternetAddress.anyIPv4, config.port);
    _log('Server gestart op poort ${_server!.port}');
    _server!.listen((socket) {
      final s = _Session(this, socket);
      _sessions.add(s);
      _log('Verbonden', s.peer);
      s.run().whenComplete(() {
        _sessions.remove(s);
        _log('Verbinding verbroken', s.peer);
      });
    });
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close();
    for (final s in _sessions.toList()) {
      s.close();
    }
    _sessions.clear();
    if (server != null) _log('Server gestopt');
  }

  void _log(String msg, [String? client]) {
    if (!_events.isClosed) _events.add(FtpEvent(msg, client: client));
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

/// Een pad op de FTP-server, gekoppeld aan het echte bestand.
class _Entry {
  _Entry({
    required this.name,
    required this.real,
    required this.isDir,
    required this.size,
    required this.modified,
    this.key,
  });

  final String name;
  final String real;
  final bool isDir;
  final int size;
  final DateTime modified;

  /// Gezet als het bestand tijdens de overdracht ontsleuteld moet worden.
  final SecretKey? key;

  bool get decrypt => key != null;
}

class _FtpError implements Exception {
  _FtpError(this.code, this.message);
  final int code;
  final String message;
}

class _Session {
  _Session(this.server, this.socket)
      : peer = '${socket.remoteAddress.address}:${socket.remotePort}';

  final FtpServer server;
  final Socket socket;
  final String peer;

  FtpServerConfig get cfg => server.config;
  String get root => p.normalize(p.absolute(cfg.rootPath));

  String? _user;
  bool _loggedIn = false;
  int _failedLogins = 0;
  String _cwd = '/';
  String? _renameFrom;
  int _restOffset = 0;

  ServerSocket? _passive;
  Future<Socket>? _pendingData;
  InternetAddress? _activeHost;
  int? _activePort;
  bool _closed = false;

  void _reply(int code, String msg) {
    if (_closed) return;
    socket.write('$code $msg\r\n');
  }

  void _multi(int code, List<String> lines, String end) {
    if (_closed) return;
    final b = StringBuffer('$code-${lines.first}\r\n');
    for (final l in lines.skip(1)) {
      b.write(' $l\r\n');
    }
    b.write('$code $end\r\n');
    socket.write(b.toString());
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _passive?.close();
    socket.destroy();
  }

  Future<void> run() async {
    _reply(220, 'Bestandskluis FTP-server gereed');
    final lines = StreamIterator(socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter()));
    try {
      while (!_closed && await lines.moveNext()) {
        final line = lines.current.trim();
        if (line.isEmpty) continue;
        final sp = line.indexOf(' ');
        final cmd = (sp < 0 ? line : line.substring(0, sp)).toUpperCase();
        final arg = sp < 0 ? '' : line.substring(sp + 1);
        try {
          await _handle(cmd, arg);
        } on _FtpError catch (e) {
          _reply(e.code, e.message);
        } on VaultAuthException {
          _reply(551, 'Ontsleutelen mislukt');
        } on FileSystemException catch (e) {
          _reply(550, e.osError?.message ?? e.message);
        } on SocketException {
          _reply(426, 'Gegevensverbinding verbroken');
        } on TimeoutException {
          _reply(425, 'Geen gegevensverbinding');
        }
      }
    } catch (_) {
      // Verbinding weg.
    } finally {
      await lines.cancel().catchError((_) {});
      close();
    }
  }

  static const _noLogin = {
    'USER', 'PASS', 'QUIT', 'FEAT', 'SYST', 'OPTS', 'NOOP', 'AUTH', 'HELP'
  };
  static const _writing = {
    'STOR', 'APPE', 'DELE', 'MKD', 'XMKD', 'RMD', 'XRMD', 'RNFR', 'RNTO'
  };

  Future<void> _handle(String cmd, String arg) async {
    if (!_loggedIn && !_noLogin.contains(cmd)) {
      throw _FtpError(530, 'Log eerst in');
    }
    if (cfg.readOnly && _writing.contains(cmd)) {
      throw _FtpError(550, 'Server is alleen-lezen');
    }
    if (cmd != 'RNTO' && cmd != 'RNFR') {
      // Een hernoeming moet direct volgen.
      if (cmd != 'NOOP') _renameFrom = null;
    }

    switch (cmd) {
      case 'USER':
        _user = arg;
        _loggedIn = false;
        _reply(331, 'Wachtwoord vereist');
      case 'PASS':
        await _login(arg);
      case 'QUIT':
        _reply(221, 'Tot ziens');
        await socket.flush();
        close();
      case 'NOOP':
        _reply(200, 'OK');
      case 'SYST':
        _reply(215, 'UNIX Type: L8');
      case 'FEAT':
        _multi(211, [
          'Ondersteund:',
          'UTF8',
          'SIZE',
          'MDTM',
          'MLST type*;size*;modify*;',
          'EPSV',
          'PASV',
          'REST STREAM',
        ], 'Einde');
      case 'OPTS':
        _reply(200, 'OK');
      case 'AUTH':
        _reply(502, 'TLS wordt niet ondersteund');
      case 'HELP':
        _reply(214, 'Zie RFC 959');
      case 'TYPE':
      case 'MODE':
      case 'STRU':
        _reply(200, 'OK');
      case 'PWD':
      case 'XPWD':
        _reply(257, '"${_cwd.replaceAll('"', '""')}" is de huidige map');
      case 'CWD':
      case 'XCWD':
        await _cwdTo(arg);
      case 'CDUP':
      case 'XCUP':
        await _cwdTo('..');
      case 'PASV':
        await _openPassive(extended: false);
      case 'EPSV':
        await _openPassive(extended: true);
      case 'PORT':
        _port(arg);
      case 'LIST':
      case 'NLST':
      case 'MLSD':
        await _list(cmd, arg);
      case 'MLST':
        final e = await _resolveOrFail(arg.isEmpty ? _cwd : arg);
        _multi(250, ['Gegevens', mlsxFacts(e.name, e.isDir, e.size, e.modified)],
            'Einde');
      case 'SIZE':
        final e = await _resolveOrFail(arg);
        if (e.isDir) throw _FtpError(550, 'Is een map');
        _reply(213, '${e.size}');
      case 'MDTM':
        final e = await _resolveOrFail(arg);
        _reply(213, mdtm(e.modified));
      case 'REST':
        _restOffset = int.tryParse(arg) ?? 0;
        _reply(350, 'Hervatten vanaf $_restOffset');
      case 'RETR':
        await _retr(arg);
      case 'STOR':
        await _stor(arg, append: false);
      case 'APPE':
        await _stor(arg, append: true);
      case 'DELE':
        final e = await _resolveOrFail(arg);
        if (e.isDir) throw _FtpError(550, 'Is een map');
        await File(e.real).delete();
        server._log('Verwijderd: ${_abs(arg)}', peer);
        _reply(250, 'Verwijderd');
      case 'MKD':
      case 'XMKD':
        final vp = _abs(arg);
        await Directory(_real(vp)).create();
        _reply(257, '"$vp" aangemaakt');
      case 'RMD':
      case 'XRMD':
        final e = await _resolveOrFail(arg);
        if (!e.isDir) throw _FtpError(550, 'Geen map');
        if (_abs(arg) == '/') throw _FtpError(550, 'Niet toegestaan');
        await Directory(e.real).delete();
        _reply(250, 'Map verwijderd');
      case 'RNFR':
        await _resolveOrFail(arg);
        _renameFrom = _abs(arg);
        _reply(350, 'Geef de nieuwe naam');
      case 'RNTO':
        await _rename(arg);
      case 'ABOR':
        _reply(226, 'Afgebroken');
      default:
        _reply(502, 'Opdracht niet ondersteund');
    }
  }

  Future<void> _login(String pass) async {
    final user = _user ?? '';
    final anonymous = user == 'anonymous' || user == 'ftp';
    final ok = (anonymous && cfg.allowAnonymous) ||
        (!anonymous &&
            user == cfg.username &&
            cfg.password.isNotEmpty &&
            pass == cfg.password);
    if (ok) {
      _loggedIn = true;
      _failedLogins = 0;
      server._log('Ingelogd als $user', peer);
      _reply(230, 'Ingelogd');
      return;
    }
    _failedLogins++;
    server._log('Mislukte inlogpoging ($user)', peer);
    await Future<void>.delayed(const Duration(seconds: 1));
    _reply(530, 'Inloggen mislukt');
    if (_failedLogins >= 5) close();
  }

  // --- Paden ----------------------------------------------------------------

  /// Absoluut virtueel pad (altijd beginnend met '/', nooit buiten de root).
  String _abs(String arg) {
    final joined = arg.startsWith('/') ? arg : p.posix.join(_cwd, arg);
    var n = p.posix.normalize(joined);
    if (!n.startsWith('/')) n = '/$n';
    // normalize laat '/..' staan als '/..' op sommige versies.
    final parts = <String>[];
    for (final s in n.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(s);
      }
    }
    return '/${parts.join('/')}';
  }

  String _real(String virtualPath) {
    final segs = virtualPath.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.any((s) => s == VaultManager.markerName || s.contains('\\'))) {
      throw _FtpError(550, 'Niet toegestaan');
    }
    final real = p.normalize(p.joinAll([root, ...segs]));
    if (real != root && !p.isWithin(root, real)) {
      throw _FtpError(550, 'Niet toegestaan');
    }
    return real;
  }

  /// Sleutel als [realDir] in een ontgrendelde kluis ligt.
  SecretKey? _keyForDir(String realDir) {
    final vr = server.vaults.vaultRootFor(realDir);
    return vr == null ? null : server.vaults.keyFor(vr);
  }

  Future<_Entry?> _resolve(String arg) async {
    final vp = _abs(arg);
    final real = _real(vp);
    final name = vp == '/' ? '/' : p.posix.basename(vp);
    final type = await FileSystemEntity.type(real, followLinks: true);
    if (type == FileSystemEntityType.directory) {
      final st = await Directory(real).stat();
      return _Entry(
          name: name, real: real, isDir: true, size: 0, modified: st.modified);
    }
    if (type == FileSystemEntityType.file) {
      final st = await File(real).stat();
      return _Entry(
          name: name,
          real: real,
          isDir: false,
          size: st.size,
          modified: st.modified);
    }
    if (cfg.decryptVaults) {
      final key = _keyForDir(p.dirname(real));
      final enc = File(VaultCrypto.encryptedName(real));
      if (key != null && await enc.exists()) {
        final st = await enc.stat();
        return _Entry(
            name: name,
            real: enc.path,
            isDir: false,
            size: VaultCrypto.plainLength(st.size),
            modified: st.modified,
            key: key);
      }
    }
    return null;
  }

  Future<_Entry> _resolveOrFail(String arg) async {
    final e = await _resolve(arg);
    if (e == null) throw _FtpError(550, 'Bestand of map niet gevonden');
    return e;
  }

  Future<List<_Entry>> _listDir(String realDir) async {
    final key = cfg.decryptVaults ? _keyForDir(realDir) : null;
    final out = <_Entry>[];
    await for (final e in Directory(realDir).list(followLinks: false)) {
      final name = p.basename(e.path);
      if (name == VaultManager.markerName) continue;
      try {
        final st = await e.stat();
        final isDir = st.type == FileSystemEntityType.directory;
        if (!isDir && key != null && VaultCrypto.isEncryptedName(name)) {
          out.add(_Entry(
              name: VaultCrypto.plainName(name),
              real: e.path,
              isDir: false,
              size: VaultCrypto.plainLength(st.size),
              modified: st.modified,
              key: key));
        } else {
          out.add(_Entry(
              name: name,
              real: e.path,
              isDir: isDir,
              size: isDir ? 0 : st.size,
              modified: st.modified));
        }
      } on FileSystemException {
        // Onleesbaar item overslaan.
      }
    }
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  Future<void> _cwdTo(String arg) async {
    final e = await _resolve(arg);
    if (e == null || !e.isDir) throw _FtpError(550, 'Map niet gevonden');
    _cwd = _abs(arg);
    _reply(250, 'Map gewijzigd naar $_cwd');
  }

  // --- Gegevensverbinding ---------------------------------------------------

  Future<void> _openPassive({required bool extended}) async {
    await _passive?.close();
    _activeHost = null;
    final local = socket.address;
    final srv = await ServerSocket.bind(
        local.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0);
    _passive = srv;
    final completer = Completer<Socket>();
    late StreamSubscription<Socket> sub;
    sub = srv.listen((s) {
      // Alleen de client die de opdracht gaf mag verbinden.
      if (s.remoteAddress.address != socket.remoteAddress.address ||
          completer.isCompleted) {
        s.destroy();
        return;
      }
      completer.complete(s);
      sub.cancel();
      srv.close();
    });
    _pendingData = completer.future;
    if (extended) {
      _reply(229, 'Passieve modus (|||${srv.port}|)');
    } else {
      var ip = local.address;
      if (local.type == InternetAddressType.IPv6) {
        // IPv4-gemapt adres (::ffff:a.b.c.d)
        ip = ip.split(':').last;
      }
      final h = ip.replaceAll('.', ',');
      _reply(227, 'Passieve modus ($h,${srv.port >> 8},${srv.port & 0xFF})');
    }
  }

  void _port(String arg) {
    final parts = arg.split(',').map((s) => int.tryParse(s.trim())).toList();
    if (parts.length != 6 || parts.any((n) => n == null || n < 0 || n > 255)) {
      throw _FtpError(501, 'Ongeldig PORT-argument');
    }
    final host = InternetAddress(parts.take(4).join('.'));
    // Bescherming tegen "FTP bounce": alleen naar de client zelf.
    if (host.address != socket.remoteAddress.address.split(':').last) {
      throw _FtpError(504, 'Alleen verbinding naar eigen adres toegestaan');
    }
    _passive?.close();
    _passive = null;
    _pendingData = null;
    _activeHost = host;
    _activePort = parts[4]! * 256 + parts[5]!;
    _reply(200, 'PORT OK');
  }

  Future<Socket> _openData() async {
    final pending = _pendingData;
    _pendingData = null;
    if (pending != null) {
      return pending.timeout(const Duration(seconds: 30), onTimeout: () {
        _passive?.close();
        throw TimeoutException('passief');
      });
    }
    if (_activeHost != null) {
      return Socket.connect(_activeHost, _activePort!,
          timeout: const Duration(seconds: 15));
    }
    throw _FtpError(425, 'Gebruik eerst PASV of PORT');
  }

  // --- Overdrachten ---------------------------------------------------------

  Future<void> _list(String cmd, String arg) async {
    // Opties als "-la" negeren.
    final target = arg
        .split(' ')
        .where((s) => s.isNotEmpty && !s.startsWith('-'))
        .join(' ');
    final e = await _resolve(target.isEmpty ? _cwd : target);
    if (e == null) {
      _pendingData = null;
      throw _FtpError(550, 'Map niet gevonden');
    }
    final entries = e.isDir ? await _listDir(e.real) : [e];
    final now = DateTime.now();
    final text = StringBuffer();
    for (final x in entries) {
      switch (cmd) {
        case 'NLST':
          text.write('${x.name}\r\n');
        case 'MLSD':
          text.write('${mlsxFacts(x.name, x.isDir, x.size, x.modified)}\r\n');
        default:
          text.write('${unixListLine(x.name, x.isDir, x.size, x.modified, now)}\r\n');
      }
    }
    _reply(150, 'Lijst wordt verstuurd');
    final data = await _openData();
    data.add(utf8.encode(text.toString()));
    await data.flush();
    await data.close();
    data.destroy();
    _reply(226, 'Lijst verstuurd');
  }

  Future<void> _retr(String arg) async {
    final offset = _restOffset;
    _restOffset = 0;
    final e = await _resolve(arg);
    if (e == null || e.isDir) {
      _pendingData = null;
      throw _FtpError(550, 'Bestand niet gevonden');
    }
    final Stream<List<int>> source = e.decrypt
        ? VaultCrypto.decryptStream(File(e.real), e.key!, start: offset)
        : File(e.real).openRead(offset);
    _reply(150, 'Bestand wordt verstuurd (${e.size} bytes)');
    final data = await _openData();
    try {
      await data.addStream(source);
      await data.flush();
      await data.close();
    } finally {
      data.destroy();
    }
    server._log(
        '${e.decrypt ? 'Ontsleuteld gedownload' : 'Gedownload'}: ${_abs(arg)}',
        peer);
    _reply(226, 'Overdracht voltooid');
  }

  Future<void> _stor(String arg, {required bool append}) async {
    final offset = _restOffset;
    _restOffset = 0;
    final vp = _abs(arg);
    if (vp == '/') throw _FtpError(553, 'Ongeldige naam');
    final real = _real(vp);
    final dir = p.dirname(real);
    if (!await Directory(dir).exists()) {
      _pendingData = null;
      throw _FtpError(553, 'Doelmap bestaat niet');
    }
    final vaultRoot = server.vaults.vaultRootFor(dir);
    final name = p.basename(real);
    SecretKey? key;
    if (vaultRoot != null && !VaultCrypto.isEncryptedName(name)) {
      key = server.vaults.keyFor(vaultRoot);
      if (key == null) {
        _pendingData = null;
        throw _FtpError(550, 'Kluis is vergrendeld; ontgrendel hem eerst in de app');
      }
      if (append || offset > 0) {
        _pendingData = null;
        throw _FtpError(504, 'Hervatten/toevoegen kan niet in een kluis');
      }
    }

    final target = key != null ? VaultCrypto.encryptedName(real) : real;
    final part = File('$target.part');
    _reply(150, 'Klaar om te ontvangen');
    final data = await _openData();
    try {
      if (key != null) {
        final sink = part.openWrite();
        await sink.addStream(VaultCrypto.encryptStream(data, key));
        await sink.close();
        await part.rename(target);
      } else if (append || offset > 0) {
        final raf = await File(target).open(mode: FileMode.append);
        if (!append) await raf.truncate(offset);
        await for (final chunk in data) {
          await raf.writeFrom(chunk);
        }
        await raf.close();
      } else {
        final sink = part.openWrite();
        await sink.addStream(data);
        await sink.close();
        await part.rename(target);
      }
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      data.destroy();
    }
    server._log('${key != null ? 'Versleuteld geüpload' : 'Geüpload'}: $vp', peer);
    _reply(226, 'Ontvangen');
  }

  Future<void> _rename(String arg) async {
    final fromVp = _renameFrom;
    _renameFrom = null;
    if (fromVp == null) throw _FtpError(503, 'Gebruik eerst RNFR');
    final from = await _resolveOrFail(fromVp);
    final toVp = _abs(arg);
    final toReal = _real(toVp);
    final srcRoot = server.vaults.vaultRootFor(p.dirname(from.real));
    final dstRoot = server.vaults.vaultRootFor(p.dirname(toReal));
    if (srcRoot != dstRoot) {
      throw _FtpError(
          553, 'Verplaatsen in of uit een kluis kan niet via FTP; gebruik de app');
    }
    final dest = from.decrypt ? VaultCrypto.encryptedName(toReal) : toReal;
    if (await FileSystemEntity.type(dest) != FileSystemEntityType.notFound) {
      throw _FtpError(553, 'Doel bestaat al');
    }
    if (from.isDir) {
      await Directory(from.real).rename(dest);
    } else {
      await File(from.real).rename(dest);
    }
    _reply(250, 'Hernoemd');
  }
}
