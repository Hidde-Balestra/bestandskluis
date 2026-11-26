import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/vault_crypto.dart';

/// Bestanden in het geheugen lezen en schrijven, ook versleutelde.
///
/// Voor notities en fotobewerking: de inhoud komt nooit onversleuteld op
/// de schijf. Schrijven gaat via een `.part`-bestand en een hernoeming, zodat
/// een onderbreking het origineel niet beschadigt.
class MemoryFiles {
  MemoryFiles._();

  /// Grootste bestand dat in het geheugen wordt geladen.
  static const maxBytes = 64 * 1024 * 1024;

  static bool _encrypted(File f) =>
      VaultCrypto.isEncryptedName(f.uri.pathSegments.last);

  static Future<Uint8List> readBytes(File f, SecretKey? key) async {
    if (await f.length() > maxBytes + 64 * 1024) {
      throw StateError('Bestand is te groot om hier te openen');
    }
    if (!_encrypted(f)) return f.readAsBytes();
    if (key == null) throw StateError('Kluis is vergrendeld');
    final b = BytesBuilder(copy: false);
    await for (final c in VaultCrypto.decryptStream(f, key)) {
      b.add(c);
    }
    return b.takeBytes();
  }

  static Future<void> writeBytes(File f, List<int> bytes, SecretKey? key) async {
    final part = File('${f.path}.part');
    final sink = part.openWrite();
    try {
      if (_encrypted(f)) {
        if (key == null) throw StateError('Kluis is vergrendeld');
        await sink.addStream(
            VaultCrypto.encryptStream(Stream.value(bytes), key));
      } else {
        sink.add(bytes);
      }
      await sink.flush();
      await sink.close();
      await part.rename(f.path);
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  static Future<String> readText(File f, SecretKey? key) async =>
      utf8.decode(await readBytes(f, key), allowMalformed: true);

  static Future<void> writeText(File f, String text, SecretKey? key) =>
      writeBytes(f, utf8.encode(text), key);
}
