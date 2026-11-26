import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import '../crypto/vault_crypto.dart';

/// Speelt versleutelde video's af zonder onversleutelde kopie op schijf.
///
/// Een kleine HTTP-server op 127.0.0.1 ontsleutelt alleen het gevraagde
/// stuk (HTTP Range) in het geheugen. Elk bestand krijgt een willekeurige,
/// lange token in de URL, zodat andere apps op de telefoon niets kunnen
/// opvragen. Tokens verlopen bij [revoke] / [revokeAll] (bijv. vergrendelen).
class MediaServer {
  MediaServer._();
  static final instance = MediaServer._();

  HttpServer? _server;
  final _files = <String, ({File file, SecretKey key, String mime})>{};

  int? get port => _server?.port;

  Future<void> _ensure() async {
    if (_server != null) return;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_handle, onError: (_) {});
    _server = s;
  }

  static String _token() => VaultCrypto.randomBytes(24)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  static String mimeFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.mp4') || n.endsWith('.m4v')) return 'video/mp4';
    if (n.endsWith('.webm')) return 'video/webm';
    if (n.endsWith('.mkv')) return 'video/x-matroska';
    if (n.endsWith('.3gp')) return 'video/3gpp';
    if (n.endsWith('.mov')) return 'video/quicktime';
    if (n.endsWith('.mp3')) return 'audio/mpeg';
    return 'application/octet-stream';
  }

  /// URL waarmee [file] (versleuteld met [key]) kan worden afgespeeld.
  Future<Uri> register(File file, SecretKey key, String plainName) async {
    await _ensure();
    final t = _token();
    _files[t] = (file: file, key: key, mime: mimeFor(plainName));
    // De extensie helpt de speler het formaat te herkennen.
    final ext = plainName.contains('.') ? plainName.split('.').last : 'bin';
    return Uri.parse('http://127.0.0.1:${_server!.port}/$t.$ext');
  }

  void revoke(Uri url) {
    final t = url.pathSegments.isEmpty ? '' : url.pathSegments.last.split('.').first;
    _files.remove(t);
  }

  /// Alle tokens intrekken (bij vergrendelen).
  void revokeAll() => _files.clear();

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
      final t = seg.isEmpty ? '' : seg.last.split('.').first;
      final entry = _files[t];
      if (entry == null || (req.method != 'GET' && req.method != 'HEAD')) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final total = VaultCrypto.plainLength(await entry.file.length());
      var start = 0;
      var end = total - 1;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      final m = range == null
          ? null
          : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
      if (m != null) {
        final a = m.group(1)!;
        final b = m.group(2)!;
        if (a.isEmpty && b.isNotEmpty) {
          start = total - int.parse(b); // laatste n bytes
        } else {
          start = int.parse(a.isEmpty ? '0' : a);
          if (b.isNotEmpty) end = int.parse(b);
        }
        if (start < 0) start = 0;
        if (end >= total) end = total - 1;
        if (start > end || start >= total) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await res.close();
          return;
        }
        res.statusCode = HttpStatus.partialContent;
        res.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      }
      res.headers
        ..contentType = ContentType.parse(entry.mime)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..contentLength = end - start + 1;
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      var remaining = end - start + 1;
      await for (final chunk
          in VaultCrypto.decryptStream(entry.file, entry.key, start: start)) {
        if (remaining <= 0) break;
        final part =
            chunk.length > remaining ? chunk.sublist(0, remaining) : chunk;
        res.add(part);
        remaining -= part.length;
        await res.flush();
      }
      await res.close();
    } catch (_) {
      // De speler brak de verbinding af (doorspoelen) of het bestand is weg.
      try {
        await res.close();
      } catch (_) {}
    }
  }
}
