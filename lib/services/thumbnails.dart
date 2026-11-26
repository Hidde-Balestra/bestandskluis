import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';

import '../crypto/vault_crypto.dart';
import 'system_bridge.dart';

/// Miniaturen van versleutelde foto's en video's, alleen in het werkgeheugen.
///
/// De foto wordt in het geheugen ontsleuteld, verkleind en als klein
/// [ui.Image] bewaard; er komt niets onversleuteld op de schijf. Voor video's
/// haalt Android een frame uit de video, die daarbij blok voor blok in het
/// geheugen wordt ontsleuteld. De cache wordt geleegd als een kluis wordt
/// vergrendeld.
class Thumbnails {
  Thumbnails._();

  static const _max = 150;
  static const _maxFileBytes = 40 * 1024 * 1024;
  static final _cache = <String, ui.Image>{}; // invoegvolgorde = LRU
  static final _pending = <String, Future<ui.Image?>>{};
  static final _durations = <String, Duration>{};
  static int _running = 0;
  static final _waiting = Queue<Completer<void>>();
  static int _generation = 0;

  static Future<void> _acquire() async {
    if (_running < 3) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
  }

  static void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }

  /// Een kloon van de miniatuur (de aanroeper moet die zelf `dispose`n).
  static Future<ui.Image?> get(File file, SecretKey key, int width,
      {bool video = false}) async {
    final st = await file.stat();
    final id = '${file.path}|${st.modified.millisecondsSinceEpoch}|$width';
    final hit = _cache.remove(id);
    if (hit != null) {
      _cache[id] = hit; // naar achteren (recent gebruikt)
      return hit.clone();
    }
    final img = await (_pending[id] ??= video
        ? _loadVideo(file, key, width, id)
        : _load(file, key, width, st.size, id));
    return img?.clone();
  }

  /// Duur van een video waarvan al een miniatuur is gemaakt.
  static Duration? durationOf(File file) => _durations[file.path];

  static Future<ui.Image?> _load(
      File file, SecretKey key, int width, int size, String id) async {
    final gen = _generation;
    await _acquire();
    try {
      if (size > _maxFileBytes) return null;
      final b = BytesBuilder(copy: false);
      await for (final chunk in VaultCrypto.decryptStream(file, key)) {
        b.add(chunk);
      }
      return await _decode(b.takeBytes(), width, gen, id);
    } catch (_) {
      return null;
    } finally {
      _pending.remove(id);
      _release();
    }
  }

  static Future<ui.Image?> _loadVideo(
      File file, SecretKey key, int width, String id) async {
    final gen = _generation;
    await _acquire();
    try {
      final blocks = await VaultCrypto.openForBlocks(file, key);
      final r = await SystemBridge.videoThumbnail(file.path, width,
          fileKey: blocks.fileKey, header: blocks.header);
      if (r == null) return null;
      final img = await _decode(r.jpg, width, gen, id);
      if (img != null) {
        _durations[file.path] = Duration(milliseconds: r.durationMs);
      }
      return img;
    } catch (_) {
      return null;
    } finally {
      _pending.remove(id);
      _release();
    }
  }

  static Future<ui.Image?> _decode(
      Uint8List bytes, int width, int gen, String id) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: width);
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (gen != _generation) {
      // Intussen vergrendeld.
      frame.image.dispose();
      return null;
    }
    _cache[id] = frame.image;
    while (_cache.length > _max) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest)?.dispose();
    }
    return frame.image;
  }

  /// Alle miniaturen uit het geheugen verwijderen.
  static void clear() {
    _generation++;
    _durations.clear();
    for (final img in _cache.values) {
      img.dispose();
    }
    _cache.clear();
  }
}
