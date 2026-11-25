import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:cryptography/dart.dart';
import 'package:path/path.dart' as p;

/// Zelfondertekend certificaat voor FTPS (FTP over TLS).
///
/// Wordt één keer gemaakt en bewaard; de vingerafdruk (SHA-256) wordt in de
/// app en de QR-code getoond, zodat een client kan controleren dat hij met
/// de juiste server praat.
class FtpTlsIdentity {
  FtpTlsIdentity(this.certPem, this.keyPem)
      : fingerprint = fingerprintOfPem(certPem);

  final String certPem;
  final String keyPem;

  /// SHA-256 van het certificaat, als "AB:CD:…".
  final String fingerprint;

  SecurityContext context() => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// Laadt het certificaat uit [dir], of maakt een nieuw.
  static Future<FtpTlsIdentity> loadOrCreate(Directory dir) async {
    final cert = File(p.join(dir.path, 'ftps-cert.pem'));
    final key = File(p.join(dir.path, 'ftps-key.pem'));
    if (await cert.exists() && await key.exists()) {
      return FtpTlsIdentity(await cert.readAsString(), await key.readAsString());
    }
    final id = await generate();
    await dir.create(recursive: true);
    await key.writeAsString(id.keyPem, flush: true);
    await cert.writeAsString(id.certPem, flush: true);
    return id;
  }

  /// Nieuw EC-sleutelpaar (P-256) met een certificaat van 10 jaar.
  static Future<FtpTlsIdentity> generate() async {
    final pems = await Isolate.run(() {
      final pair = CryptoUtils.generateEcKeyPair();
      final priv = pair.privateKey as ECPrivateKey;
      final pub = pair.publicKey as ECPublicKey;
      final csr = X509Utils.generateEccCsrPem(
          {'CN': 'Bestandskluis FTP-server', 'O': 'Bestandskluis'}, priv, pub);
      final cert = X509Utils.generateSelfSignedCertificate(priv, csr, 3650,
          serialNumber: '${DateTime.now().millisecondsSinceEpoch}');
      return [cert, CryptoUtils.encodeEcPrivateKeyToPem(priv)];
    });
    return FtpTlsIdentity(pems[0], pems[1]);
  }

  static String fingerprintOfPem(String pem) {
    final body = const LineSplitter()
        .convert(pem)
        .where((l) => !l.startsWith('-----'))
        .join()
        .trim();
    return fingerprintOfDer(base64.decode(body));
  }

  /// SHA-256 van een certificaat (DER), als "AB:CD:…".
  static String fingerprintOfDer(List<int> der) => const DartSha256()
      .hashSync(der)
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}
