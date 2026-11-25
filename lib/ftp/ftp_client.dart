import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ftp_format.dart';
import 'ftp_tls.dart';

class FtpReply {
  FtpReply(this.code, this.lines);
  final int code;
  final List<String> lines;
  String get message => lines.isEmpty ? '' : lines.last.substring(
      lines.last.length >= 4 ? 4 : lines.last.length);
  bool get ok => code >= 200 && code < 400;
  @override
  String toString() => '$code $message';
}

class FtpException implements Exception {
  FtpException(this.message, [this.reply]);
  final String message;
  final FtpReply? reply;
  @override
  String toString() =>
      reply == null ? message : '$message (${reply!.code} ${reply!.message})';
}

/// Het certificaat van de server is anders dan het onthouden certificaat.
class FtpCertificateException extends FtpException {
  FtpCertificateException(this.expected, this.actual)
      : super('Het certificaat van de server is gewijzigd. Dit kan betekenen '
            'dat iemand meeluistert. Verwacht $expected, ontvangen $actual.');
  final String expected;
  final String actual;
}

/// Passieve FTP-client voor het bladeren, downloaden en uploaden, met
/// optioneel expliciete FTPS (AUTH TLS).
class FtpClient {
  FtpClient._(this.host, this._socket, this._lines);

  final String host;
  Socket _socket;
  StreamIterator<String> _lines;
  Future<void> _queue = Future.value();
  bool _mlsd = true;

  /// Versleutelde verbinding (FTPS).
  bool get secure => _socket is SecureSocket;

  /// SHA-256-vingerafdruk van het servercertificaat (alleen bij FTPS).
  String? fingerprint;

  static StreamIterator<String> _reader(Socket s) => StreamIterator(s
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter()));

  /// Verbindt en logt in. Met [tls] wordt eerst AUTH TLS gedaan; als
  /// [pinnedFingerprint] is gegeven moet het certificaat daarmee
  /// overeenkomen (anders [FtpCertificateException]). Zonder vingerafdruk
  /// wordt het certificaat geaccepteerd en staat de vingerafdruk daarna in
  /// [fingerprint] (eerste keer vertrouwen).
  static Future<FtpClient> connect(
    String host, {
    int port = 21,
    String user = 'anonymous',
    String password = '',
    bool tls = false,
    String? pinnedFingerprint,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    final c = FtpClient._(host, socket, _reader(socket));
    try {
      final greet = await c._read().timeout(timeout);
      if (greet.code != 220) throw FtpException('Onverwachte begroeting', greet);
      if (tls) {
        final a = await c._send('AUTH TLS');
        if (a.code != 234) {
          throw FtpException('Deze server ondersteunt geen FTPS', a);
        }
        final s = await SecureSocket.secure(c._socket,
                host: host, onBadCertificate: (_) => true)
            .timeout(timeout);
        final fp = FtpTlsIdentity.fingerprintOfDer(s.peerCertificate!.der);
        if (pinnedFingerprint != null && fp != pinnedFingerprint) {
          s.destroy();
          throw FtpCertificateException(pinnedFingerprint, fp);
        }
        c
          .._socket = s
          .._lines = _reader(s)
          ..fingerprint = fp;
      }
      var r = await c._send('USER $user');
      if (r.code == 331) r = await c._send('PASS $password');
      if (r.code != 230) throw FtpException('Inloggen mislukt', r);
      if (tls) {
        await c._send('PBSZ 0');
        final p = await c._send('PROT P');
        if (p.code != 200) {
          throw FtpException('Versleutelde gegevensverbinding geweigerd', p);
        }
      }
      await c._send('OPTS UTF8 ON');
      await c._send('TYPE I');
    } catch (_) {
      c._socket.destroy();
      rethrow;
    }
    return c;
  }

  /// Na het 150-antwoord: TLS op de gegevensverbinding starten.
  Future<Socket> _protect(Socket raw) async {
    if (!secure) return raw;
    try {
      final s = await SecureSocket.secure(raw,
              host: host, onBadCertificate: (_) => true)
          .timeout(const Duration(seconds: 15));
      final fp = FtpTlsIdentity.fingerprintOfDer(s.peerCertificate!.der);
      if (fp != fingerprint) {
        s.destroy();
        throw FtpCertificateException(fingerprint ?? '?', fp);
      }
      return s;
    } catch (_) {
      raw.destroy();
      rethrow;
    }
  }

  Future<FtpReply> _read() async {
    final lines = <String>[];
    if (!await _lines.moveNext()) throw FtpException('Verbinding gesloten');
    var line = _lines.current;
    lines.add(line);
    final code = int.tryParse(line.length >= 3 ? line.substring(0, 3) : '');
    if (code == null) throw FtpException('Ongeldig antwoord: $line');
    if (line.length > 3 && line[3] == '-') {
      while (true) {
        if (!await _lines.moveNext()) throw FtpException('Verbinding gesloten');
        line = _lines.current;
        lines.add(line);
        if (line.startsWith('$code ')) break;
      }
    }
    return FtpReply(code, lines);
  }

  Future<FtpReply> _send(String cmd) async {
    _socket.write('$cmd\r\n');
    return _read();
  }

  /// Voert opdrachten één voor één uit.
  Future<T> _locked<T>(Future<T> Function() body) {
    final result = _queue.then((_) => body());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<FtpReply> _expect(String cmd, String what) async {
    final r = await _send(cmd);
    if (!r.ok) throw FtpException(what, r);
    return r;
  }

  Future<Socket> _dataSocket() async {
    var r = await _send('EPSV');
    int? port;
    if (r.code == 229) {
      final m = RegExp(r'\(\|\|\|(\d+)\|\)').firstMatch(r.message);
      port = m == null ? null : int.parse(m.group(1)!);
    }
    if (port == null) {
      r = await _send('PASV');
      final m = RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch(r.message);
      if (r.code != 227 || m == null) {
        throw FtpException('Passieve modus mislukt', r);
      }
      port = int.parse(m.group(5)!) * 256 + int.parse(m.group(6)!);
    }
    // Altijd naar de host van de besturingsverbinding (werkt ook achter NAT).
    return Socket.connect(_socket.remoteAddress, port,
        timeout: const Duration(seconds: 15));
  }

  Future<String> pwd() => _locked(() async {
        final r = await _expect('PWD', 'PWD mislukt');
        final m = RegExp(r'"((?:[^"]|"")*)"').firstMatch(r.message);
        return m == null ? '/' : m.group(1)!.replaceAll('""', '"');
      });

  Future<void> cd(String path) =>
      _locked(() => _expect('CWD $path', 'Map openen mislukt'));

  Future<void> mkdir(String path) =>
      _locked(() => _expect('MKD $path', 'Map maken mislukt'));

  Future<void> rmdir(String path) =>
      _locked(() => _expect('RMD $path', 'Map verwijderen mislukt'));

  Future<void> delete(String path) =>
      _locked(() => _expect('DELE $path', 'Verwijderen mislukt'));

  Future<void> rename(String from, String to) => _locked(() async {
        final r = await _send('RNFR $from');
        if (r.code != 350) throw FtpException('Hernoemen mislukt', r);
        await _expect('RNTO $to', 'Hernoemen mislukt');
      });

  Future<int?> size(String path) => _locked(() async {
        final r = await _send('SIZE $path');
        return r.code == 213 ? int.tryParse(r.message.trim()) : null;
      });

  /// Inhoud van [path] (of de huidige map).
  Future<List<RemoteEntry>> list([String path = '']) => _locked(() async {
        Future<String?> fetch(String cmd) async {
          final raw = await _dataSocket();
          final r = await _send(path.isEmpty ? cmd : '$cmd $path');
          if (r.code != 150 && r.code != 125) {
            raw.destroy();
            if (r.code == 500 || r.code == 502) return null;
            throw FtpException('Map lezen mislukt', r);
          }
          final data = await _protect(raw);
          final bytes = await data.fold<List<int>>([], (a, b) => a..addAll(b));
          data.destroy();
          final done = await _read();
          if (!done.ok) throw FtpException('Map lezen mislukt', done);
          return utf8.decode(bytes, allowMalformed: true);
        }

        String? text;
        if (_mlsd) {
          text = await fetch('MLSD');
          if (text == null) _mlsd = false;
        }
        final useMlsd = text != null;
        text ??= await fetch('LIST');
        final entries = <RemoteEntry>[];
        for (final line in const LineSplitter().convert(text ?? '')) {
          if (line.trim().isEmpty) continue;
          final e = useMlsd ? parseMlsdLine(line) : parseUnixListLine(line);
          if (e != null) entries.add(e);
        }
        entries.sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
        return entries;
      });

  Future<void> download(String remote, File local,
          {void Function(int bytes)? onProgress}) =>
      _locked(() async {
        final raw = await _dataSocket();
        final r = await _send('RETR $remote');
        if (r.code != 150 && r.code != 125) {
          raw.destroy();
          throw FtpException('Downloaden mislukt', r);
        }
        final data = await _protect(raw);
        final part = File('${local.path}.part');
        final sink = part.openWrite();
        var done = 0;
        try {
          await sink.addStream(data.map((d) {
            done += d.length;
            onProgress?.call(done);
            return d;
          }));
          await sink.close();
        } catch (_) {
          await sink.close().catchError((_) {});
          if (await part.exists()) await part.delete();
          rethrow;
        } finally {
          data.destroy();
        }
        final end = await _read();
        if (!end.ok) {
          await part.delete();
          throw FtpException('Downloaden mislukt', end);
        }
        if (await local.exists()) await local.delete();
        await part.rename(local.path);
      });

  Future<void> upload(File local, String remote,
          {void Function(int bytes)? onProgress}) =>
      _locked(() async {
        final raw = await _dataSocket();
        final r = await _send('STOR $remote');
        if (r.code != 150 && r.code != 125) {
          raw.destroy();
          throw FtpException('Uploaden mislukt', r);
        }
        final data = await _protect(raw);
        var done = 0;
        try {
          await data.addStream(local.openRead().map((d) {
            done += d.length;
            onProgress?.call(done);
            return d;
          }));
          await data.flush();
          await data.close();
        } finally {
          data.destroy();
        }
        final end = await _read();
        if (!end.ok) throw FtpException('Uploaden mislukt', end);
      });

  Future<void> quit() async {
    try {
      await _locked(() => _send('QUIT')).timeout(const Duration(seconds: 3));
    } catch (_) {
      // negeren
    } finally {
      _socket.destroy();
    }
  }
}
