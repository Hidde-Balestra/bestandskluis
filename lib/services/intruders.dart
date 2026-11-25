import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/vault_crypto.dart';

/// Eén mislukte ontgrendelpoging.
class IntruderEvent {
  IntruderEvent({required this.time, required this.vault, this.photo});

  final DateTime time;
  final String vault;

  /// Bestandsnaam van de versleutelde foto, of null.
  final String? photo;

  Map<String, dynamic> toJson() =>
      {'tijd': time.toIso8601String(), 'kluis': vault, 'foto': photo};

  static IntruderEvent fromJson(Map<String, dynamic> j) => IntruderEvent(
      time: DateTime.parse(j['tijd'] as String),
      vault: j['kluis'] as String,
      photo: j['foto'] as String?);
}

/// Registreert mislukte pogingen en maakt (optioneel) ongemerkt een foto met
/// de voorcamera. Foto's worden versleuteld opgeslagen in de privé-map van
/// de app; de sleutel staat in de Keystore-beschermde opslag.
class Intruders extends ChangeNotifier {
  static const _logKey = 'indringers.log';
  static const _seenKey = 'indringers.gezien';
  static const _secretKey = 'indringers.sleutel';
  static const _store = FlutterSecureStorage();

  List<IntruderEvent> _events = [];
  DateTime? _seen;

  List<IntruderEvent> get events => List.unmodifiable(_events.reversed);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_logKey);
    _events = raw == null
        ? []
        : (jsonDecode(raw) as List)
            .map((e) => IntruderEvent.fromJson(e as Map<String, dynamic>))
            .toList();
    final seen = prefs.getString(_seenKey);
    _seen = seen == null ? null : DateTime.parse(seen);
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _logKey, jsonEncode(_events.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  /// Aantal pogingen dat nog niet is bekeken.
  Future<int> unseenCount() async =>
      _events.where((e) => _seen == null || e.time.isAfter(_seen!)).length;

  Future<void> markSeen() async {
    _seen = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_seenKey, _seen!.toIso8601String());
    notifyListeners();
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'indringers')).create(recursive: true);
  }

  static Future<SecretKey> _key() async {
    var v = await _store.read(key: _secretKey);
    if (v == null) {
      v = base64.encode(VaultCrypto.randomBytes(32));
      await _store.write(key: _secretKey, value: v);
    }
    return SecretKey(base64.decode(v));
  }

  /// Camera-toestemming vragen (bij het inschakelen van de optie).
  static Future<bool> requestCamera() async =>
      (await Permission.camera.request()).isGranted;

  Future<void> record(String vault, {bool takePhoto = false}) async {
    String? photo;
    if (takePhoto) {
      try {
        photo = await _capture();
      } catch (_) {
        photo = null; // geen camera of geen toestemming
      }
    }
    _events.add(IntruderEvent(time: DateTime.now(), vault: vault, photo: photo));
    if (_events.length > 200) _events.removeRange(0, _events.length - 200);
    await _save();
  }

  /// Maakt een foto met de voorcamera zonder voorbeeld op het scherm.
  static Future<String?> _capture() async {
    if (!await Permission.camera.isGranted) return null;
    final cams = await availableCameras();
    final front = cams.where((c) => c.lensDirection == CameraLensDirection.front);
    if (front.isEmpty) return null;
    final c = CameraController(front.first, ResolutionPreset.medium,
        enableAudio: false);
    try {
      await c.initialize();
      final shot = await c.takePicture();
      final tmp = File(shot.path);
      final name = '${DateTime.now().millisecondsSinceEpoch}.bki';
      final out = File(p.join((await _dir()).path, name));
      await VaultCrypto.encryptFile(tmp, out, await _key());
      await tmp.delete().catchError((_) => tmp);
      return name;
    } finally {
      await c.dispose();
    }
  }

  /// Ontsleutelde foto in het geheugen.
  Future<Uint8List?> photoBytes(IntruderEvent e) async {
    final name = e.photo;
    if (name == null) return null;
    final f = File(p.join((await _dir()).path, name));
    if (!await f.exists()) return null;
    final chunks = await VaultCrypto.decryptStream(f, await _key()).toList();
    return Uint8List.fromList(chunks.expand((c) => c).toList());
  }

  Future<void> clear() async {
    final d = await _dir();
    if (await d.exists()) await d.delete(recursive: true);
    _events = [];
    await _save();
  }
}
