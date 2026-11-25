import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';

import '../crypto/vault_crypto.dart';

/// Miniaturen van versleutelde foto's, alleen in het werkgeheugen.
///
/// De foto wordt in het geheugen ontsleuteld, verkleind en als klein
/// [ui.Image] bewaard; er komt niets onversleuteld op de schijf. De cache
/// wordt geleegd als een kluis wordt vergrendeld.
class Thumbnails {
  Thumbnails._();

  static const _max = 150;
  static const _maxFileBytes = 40 * 1024 * 1024;
  static final _cache = <String, ui.Image>{}; // invoegvolgorde = LRU
  static final _pending = <String, Future<ui.Image?>>{};
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
  static Future<ui.Image?> get(File file, SecretKey key, int width) async {
    final st = await file.stat();
    final id = '${file.path}|${st.modified.millisecondsSinceEpoch}|$width';
    final hit = _cache.remove(id);
    if (hit != null) {
      _cache[id] = hit; // naar achteren (recent gebruikt)
      return hit.clone();
    }
    final img = await (_pending[id] ??= _load(file, key, width, st.size, id));
    return img?.clone();
  }

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
      final codec =
          await ui.instantiateImageCodec(b.takeBytes(), targetWidth: width);
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
    } catch (_) {
      return null;
    } finally {
      _pending.remove(id);
      _release();
    }
  }

  /// Alle miniaturen uit het geheugen verwijderen.
  static void clear() {
    _generation++;
    for (final img in _cache.values) {
      img.dispose();
    }
    _cache.clear();
  }
}
