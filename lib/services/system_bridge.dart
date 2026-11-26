import 'dart:async';

import 'package:flutter/services.dart';

/// Wat de app van buitenaf binnenkrijgt.
sealed class Incoming {
  const Incoming();

  static Incoming? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return switch (raw['soort']) {
      'bestanden' => SharedFiles(
          ((raw['paden'] as List?) ?? const []).cast<String>().toList()),
      'ftp' => FtpLink(raw['url'] as String),
      'stopFtp' => const StopFtp(),
      'openKluis' => const OpenVault(),
      _ => null,
    };
  }
}

/// Bestanden gedeeld vanuit een andere app (kopieën in de cache).
class SharedFiles extends Incoming {
  const SharedFiles(this.paths);
  final List<String> paths;
}

/// Een ftp://-link (bijv. uit een QR-code).
class FtpLink extends Incoming {
  const FtpLink(this.url);
  final String url;
}

/// "Stoppen" in de melding van de FTP-server.
class StopFtp extends Incoming {
  const StopFtp();
}

/// "Kluis openen" in de widget.
class OpenVault extends Incoming {
  const OpenVault();
}

/// Verbinding met de Android-kant (MainActivity / FtpService).
class SystemBridge {
  SystemBridge._();

  static const _ch = MethodChannel('bestandskluis/systeem');
  static final _incoming = StreamController<Incoming>.broadcast();

  static Stream<Incoming> get incoming => _incoming.stream;

  static final _lock = StreamController<String>.broadcast();

  /// Verzoeken om alles te vergrendelen (widget, scherm uit, omgedraaid).
  static Stream<String> get lockRequests => _lock.stream;

  static void init() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'binnenkomend') {
        final i = Incoming.fromMap(call.arguments);
        if (i != null) _incoming.add(i);
      } else if (call.method == 'vergrendelAlles') {
        _lock.add('${call.arguments ?? ''}');
      }
    });
  }

  /// Het intent waarmee de app is gestart, als dat iets bracht.
  static Future<Incoming?> initial() async {
    try {
      return Incoming.fromMap(await _ch.invokeMethod('binnenkomend'));
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> _call(String method, [Object? args]) async {
    try {
      await _ch.invokeMethod(method, args);
    } on MissingPluginException {
      // Geen Android (tests).
    } on PlatformException {
      // Negeren: functie niet beschikbaar.
    }
  }

  /// Schermafbeeldingen blokkeren en inhoud verbergen bij "recente apps".
  static Future<void> secureScreen(bool on) => _call('beveiligScherm', on);

  static Future<void> startServerService(String text) =>
      _call('startServerDienst', text);

  static Future<void> stopServerService() => _call('stopServerDienst');

  /// Miniatuur (JPEG) en duur (ms) van een video. Met [fileKey] en
  /// [header] wordt een versleuteld kluisbestand in het geheugen gelezen.
  static Future<({Uint8List jpg, int durationMs})?> videoThumbnail(
      String path, int width,
      {List<int>? fileKey, List<int>? header}) async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('videoMiniatuur', {
        'pad': path,
        'breedte': width,
        if (fileKey != null) 'sleutel': Uint8List.fromList(fileKey),
        if (header != null) 'kop': Uint8List.fromList(header),
      });
      final jpg = r?['jpg'];
      if (jpg is! Uint8List) return null;
      return (jpg: jpg, durationMs: (r?['duur'] as num?)?.toInt() ?? 0);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Automatisch vergrendelen als het scherm uitgaat en/of de telefoon
  /// met het scherm naar beneden wordt gelegd.
  static Future<void> setLockTriggers({required bool screenOff, required bool faceDown}) =>
      _call('vergrendelInstellingen', {'schermUit': screenOff, 'omdraaien': faceDown});

  /// App naar de achtergrond in plaats van afsluiten.
  static Future<void> moveToBack() => _call('naarAchtergrond');
}
