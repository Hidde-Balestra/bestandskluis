import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Versleutelingsformaat voor bestanden in een kluis (versie 1).
///
/// ```text
/// header (24 bytes):  "BKV1" | chunkgrootte (u32, big-endian) | salt (16 bytes)
/// daarna N blokken:   AES-256-GCM(blok) || tag (16 bytes)
/// ```
///
/// * Elk bestand krijgt een eigen sleutel: HKDF-SHA256(kluissleutel, salt).
/// * De nonce van blok i is de 96-bits teller i, uniek per bestandssleutel.
/// * De AAD is de header plus één byte die aangeeft of het het laatste blok
///   is. Daardoor wordt afkappen of omwisselen van blokken gedetecteerd.
/// * Een leeg bestand bestaat uit één leeg (laatste) blok.
class VaultCrypto {
  VaultCrypto._();

  static const magic = [0x42, 0x4B, 0x56, 0x31]; // "BKV1"
  static const headerLength = 24;
  static const tagLength = 16;
  static const defaultChunkSize = 256 * 1024;

  /// Extensie van versleutelde bestanden met een leesbare naam.
  static const extension = '.bkv';

  /// Extensie van versleutelde bestanden met een versleutelde naam.
  static const nameExtension = '.bkx';

  /// Maximale lengte van een bestandsnaam op Android.
  static const maxNameBytes = 255;

  static final AesGcm _aes = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final List<int> _hkdfInfo = utf8.encode('bestandskluis-bestand-v1');
  static final _aesSync = DartAesGcm.with256bits();
  static final _hmacSync = DartHmac.sha256();
  static final List<int> _nameAad = utf8.encode('bestandskluis-naam-v1');

  static bool _endsWith(String name, String ext) =>
      name.length > ext.length && name.toLowerCase().endsWith(ext);

  static bool isEncryptedName(String name) =>
      _endsWith(name, extension) || _endsWith(name, nameExtension);

  /// Bestand waarvan ook de naam versleuteld is.
  static bool hasEncryptedName(String name) => _endsWith(name, nameExtension);

  /// Sleutel voor bestandsnamen, gekoppeld aan de kluissleutel van een kluis
  /// met versleutelde namen.
  static final _namesKeys = Expando<SecretKeyData>('namen');

  /// Kluissleutel maken; met [names] worden bestandsnamen versleuteld.
  static SecretKey vaultKey(List<int> master, {SecretKeyData? names}) {
    final key = SecretKeyData(master);
    if (names != null) _namesKeys[key] = names;
    return key;
  }

  static SecretKeyData? _namesKey(SecretKey? key) =>
      key == null ? null : _namesKeys[key];

  /// Oorspronkelijke naam van een versleuteld bestand. Bij een versleutelde
  /// naam is [key] nodig; zonder (juiste) sleutel komt de naam ongewijzigd
  /// terug.
  static String plainName(String encryptedName, [SecretKey? key]) {
    if (_endsWith(encryptedName, nameExtension)) {
      final names = _namesKey(key);
      if (names == null) return encryptedName;
      try {
        final raw = base64Url.decode(base64Url.normalize(encryptedName
            .substring(0, encryptedName.length - nameExtension.length)));
        if (raw.length < 12 + tagLength) return encryptedName;
        final clear = _aesSync.decryptSync(
          SecretBox(raw.sublist(12, raw.length - tagLength),
              nonce: raw.sublist(0, 12),
              mac: Mac(raw.sublist(raw.length - tagLength))),
          secretKeyData: names,
          aad: _nameAad,
        );
        return utf8.decode(clear);
      } catch (_) {
        return encryptedName;
      }
    }
    if (_endsWith(encryptedName, extension)) {
      return encryptedName.substring(0, encryptedName.length - extension.length);
    }
    return encryptedName;
  }

  /// Bestandsnaam op schijf voor [plainName]. Als [key] een sleutel voor
  /// namen heeft, wordt de naam deterministisch versleuteld (de nonce is een
  /// HMAC van de naam), zodat dezelfde naam altijd hetzelfde resultaat geeft
  /// en bestanden op naam terug te vinden zijn.
  static String encryptedName(String plainName, [SecretKey? key]) {
    final names = _namesKey(key);
    if (names == null) return '$plainName$extension';
    final clear = utf8.encode(plainName);
    final nonce = _hmacSync
        .calculateMacSync(clear, secretKeyData: names, nonce: const [])
        .bytes
        .sublist(0, 12);
    final box = _aesSync.encryptSync(clear,
        secretKeyData: names, nonce: nonce, aad: _nameAad);
    final encoded = base64Url
        .encode([...nonce, ...box.cipherText, ...box.mac.bytes])
        .replaceAll('=', '');
    final result = '$encoded$nameExtension';
    if (result.length > maxNameBytes) {
      throw StateError('Bestandsnaam is te lang voor een kluis met '
          'versleutelde namen (maximaal ongeveer 150 tekens)');
    }
    return result;
  }

  /// Sleutel voor bestandsnamen, afgeleid van de kluissleutel.
  static Future<SecretKeyData> deriveNamesKey(SecretKey master) async {
    final k = await _hkdf.deriveKey(
        secretKey: master,
        nonce: utf8.encode('namen'),
        info: utf8.encode('bestandskluis-namen-v1'));
    return SecretKeyData(await k.extractBytes());
  }

  // ---------------------------------------------------------------------------
  // Sleutel inpakken (kluis versie 2: wachtwoord wijzigen, herstelcode)

  static final List<int> _wrapAad = utf8.encode('bestandskluis-sleutel-v2');

  /// Versleutelt de kluissleutel [master] met [kek].
  static Future<String> wrapKey(SecretKey kek, List<int> master) async {
    final box = await _aes.encrypt(master,
        secretKey: kek, nonce: randomBytes(12), aad: _wrapAad);
    return base64.encode(box.concatenation());
  }

  /// Pakt de kluissleutel uit; null als [kek] niet klopt.
  static Future<List<int>?> unwrapKey(SecretKey kek, String wrapped) async {
    try {
      final box = SecretBox.fromConcatenation(base64.decode(wrapped),
          nonceLength: 12, macLength: tagLength);
      return await _aes.decrypt(box, secretKey: kek, aad: _wrapAad);
    } catch (_) {
      return null;
    }
  }

  /// Lengte van de oorspronkelijke inhoud, berekend uit de versleutelde lengte.
  static int plainLength(int cipherLength,
      {int chunkSize = defaultChunkSize}) {
    final body = cipherLength - headerLength;
    if (body < tagLength) return 0;
    final chunks = (body + chunkSize + tagLength - 1) ~/ (chunkSize + tagLength);
    return max(0, body - chunks * tagLength);
  }

  /// Lengte van het versleutelde bestand voor [plainLength] bytes.
  static int cipherLength(int plainLength,
      {int chunkSize = defaultChunkSize}) {
    final chunks = plainLength == 0 ? 1 : (plainLength + chunkSize - 1) ~/ chunkSize;
    return headerLength + plainLength + chunks * tagLength;
  }

  static Uint8List randomBytes(int length) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => r.nextInt(256)));
  }

  static Uint8List _nonce(int counter) {
    final n = Uint8List(12);
    final bd = ByteData.sublistView(n);
    bd.setUint32(4, counter >> 32);
    bd.setUint32(8, counter & 0xFFFFFFFF);
    return n;
  }

  static List<int> _aad(Uint8List header, bool last) =>
      [...header, last ? 1 : 0];

  static Future<SecretKey> _fileKey(SecretKey master, List<int> salt) =>
      _hkdf.deriveKey(secretKey: master, nonce: salt, info: _hkdfInfo);

  /// Kop en bestandssleutel van een versleuteld bestand, voor code die de
  /// blokken zelf ontsleutelt (video-miniaturen in Android).
  static Future<({Uint8List header, List<int> fileKey})> openForBlocks(
      File file, SecretKey master) async {
    final raf = await file.open();
    try {
      final header = await raf.read(headerLength);
      if (header.length != headerLength ||
          !List.generate(4, (i) => header[i] == magic[i]).every((b) => b)) {
        throw const VaultFormatException('Geen kluisbestand');
      }
      final key = await _fileKey(master, header.sublist(8, 24));
      return (header: header, fileKey: await key.extractBytes());
    } finally {
      await raf.close();
    }
  }

  static Uint8List _header(int chunkSize, Uint8List salt) {
    final h = Uint8List(headerLength);
    h.setRange(0, 4, magic);
    ByteData.sublistView(h).setUint32(4, chunkSize);
    h.setRange(8, 24, salt);
    return h;
  }

  /// Versleutelt een stroom bytes. Werkt met constant geheugengebruik, dus
  /// ook voor grote video's en FTP-uploads.
  static Stream<List<int>> encryptStream(
    Stream<List<int>> input,
    SecretKey master, {
    int chunkSize = defaultChunkSize,
  }) async* {
    final salt = randomBytes(16);
    final header = _header(chunkSize, salt);
    final key = await _fileKey(master, salt);
    yield header;

    final buf = Uint8List(chunkSize);
    var fill = 0;
    var counter = 0;

    Future<List<int>> seal(List<int> clear, bool last) async {
      final box = await _aes.encrypt(clear,
          secretKey: key, nonce: _nonce(counter++), aad: _aad(header, last));
      return [...box.cipherText, ...box.mac.bytes];
    }

    await for (final data in input) {
      var offset = 0;
      while (offset < data.length) {
        if (fill == chunkSize) {
          // Er komt nog meer data, dus dit blok is niet het laatste.
          yield await seal(buf, false);
          fill = 0;
        }
        final n = min(chunkSize - fill, data.length - offset);
        buf.setRange(fill, fill + n, data, offset);
        fill += n;
        offset += n;
      }
    }
    yield await seal(Uint8List.sublistView(buf, 0, fill), true);
  }

  /// Ontsleutelt [file] als stroom, eventueel vanaf positie [start] in de
  /// oorspronkelijke inhoud (voor FTP REST / hervatten).
  static Stream<List<int>> decryptStream(
    File file,
    SecretKey master, {
    int start = 0,
  }) async* {
    final raf = await file.open();
    try {
      final total = await raf.length();
      if (total < headerLength + tagLength) {
        throw const VaultFormatException('Bestand is te kort');
      }
      final header = await raf.read(headerLength);
      for (var i = 0; i < 4; i++) {
        if (header[i] != magic[i]) {
          throw const VaultFormatException('Geen kluisbestand');
        }
      }
      final chunkSize = ByteData.sublistView(header).getUint32(4);
      if (chunkSize == 0 || chunkSize > 64 * 1024 * 1024) {
        throw const VaultFormatException('Ongeldige blokgrootte');
      }
      final key = await _fileKey(master, header.sublist(8, 24));
      final body = total - headerLength;
      final chunks =
          (body + chunkSize + tagLength - 1) ~/ (chunkSize + tagLength);

      var index = start ~/ chunkSize;
      var skip = start % chunkSize;
      for (; index < chunks; index++) {
        final pos = headerLength + index * (chunkSize + tagLength);
        final last = index == chunks - 1;
        final len = last ? total - pos : chunkSize + tagLength;
        if (len < tagLength) {
          throw const VaultFormatException('Beschadigd blok');
        }
        await raf.setPosition(pos);
        final data = await raf.read(len);
        if (data.length != len) {
          throw const VaultFormatException('Onverwacht einde van bestand');
        }
        final List<int> clear;
        try {
          clear = await _aes.decrypt(
            SecretBox(
              Uint8List.sublistView(data, 0, len - tagLength),
              nonce: _nonce(index),
              mac: Mac(Uint8List.sublistView(data, len - tagLength)),
            ),
            secretKey: key,
            aad: _aad(header, last),
          );
        } on SecretBoxAuthenticationError {
          throw const VaultAuthException();
        }
        if (skip > 0) {
          if (skip < clear.length) yield clear.sublist(skip);
          skip = 0;
        } else if (clear.isNotEmpty) {
          yield clear;
        }
      }
    } finally {
      await raf.close();
    }
  }

  /// Versleutelt [source] naar [target] (eerst als .part, daarna hernoemd).
  static Future<void> encryptFile(File source, File target, SecretKey master,
      {void Function(int bytes)? onProgress}) async {
    final part = File('${target.path}.part');
    final sink = part.openWrite();
    try {
      var done = 0;
      final input = source.openRead().map((d) {
        done += d.length;
        onProgress?.call(done);
        return d;
      });
      await sink.addStream(encryptStream(input, master));
      await sink.close();
      await part.rename(target.path);
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  /// Ontsleutelt [source] naar [target] (eerst als .part, daarna hernoemd).
  static Future<void> decryptFile(File source, File target, SecretKey master,
      {void Function(int bytes)? onProgress}) async {
    final part = File('${target.path}.part');
    final sink = part.openWrite();
    try {
      var done = 0;
      await sink.addStream(decryptStream(source, master).map((d) {
        done += d.length;
        onProgress?.call(done);
        return d;
      }));
      await sink.close();
      await part.rename(target.path);
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Wachtwoord → kluissleutel

  /// Leidt de kluissleutel af met PBKDF2-HMAC-SHA256 in een achtergrond-isolate
  /// zodat de interface niet blokkeert.
  static Future<SecretKey> deriveKey(
      String password, List<int> salt, int iterations) async {
    final bytes = await Isolate.run(() async {
      final kdf = DartPbkdf2(
          macAlgorithm: DartHmac.sha256(),
          iterations: iterations,
          bits: 256);
      final key = await kdf.deriveKeyFromPassword(
          password: password, nonce: salt);
      return key.extractBytes();
    });
    return SecretKey(bytes);
  }

  static final List<int> _checkPlain = utf8.encode('bestandskluis-ok');
  static final List<int> _checkAad = utf8.encode('bestandskluis-check');

  /// Maakt een controlewaarde waarmee een wachtwoord geverifieerd kan worden.
  static Future<String> makeCheck(SecretKey key) async {
    final nonce = randomBytes(12);
    final box = await _aes.encrypt(_checkPlain,
        secretKey: key, nonce: nonce, aad: _checkAad);
    return base64.encode(box.concatenation());
  }

  static Future<bool> verifyCheck(SecretKey key, String check) async {
    try {
      final box = SecretBox.fromConcatenation(base64.decode(check),
          nonceLength: 12, macLength: tagLength);
      final clear = await _aes.decrypt(box, secretKey: key, aad: _checkAad);
      return utf8.decode(clear) == utf8.decode(_checkPlain);
    } catch (_) {
      return false;
    }
  }
}

class VaultFormatException implements Exception {
  const VaultFormatException(this.message);
  final String message;
  @override
  String toString() => 'Ongeldig kluisbestand: $message';
}

class VaultAuthException implements Exception {
  const VaultAuthException();
  @override
  String toString() =>
      'Ontsleutelen mislukt: verkeerde sleutel of het bestand is gewijzigd';
}
