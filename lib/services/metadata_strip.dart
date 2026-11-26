import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Haalt locatie (GPS) en andere EXIF-/XMP-gegevens uit foto's.
///
/// JPEG: de metadatasegmenten (APP1 = EXIF/XMP, APP13 = IPTC, commentaar)
/// worden weggelaten zonder de foto opnieuw te comprimeren. Alleen als de
/// foto via EXIF gedraaid is, wordt hij opnieuw opgeslagen met de draaiing
/// erin verwerkt (anders zou hij na het strippen scheef staan).
/// PNG: tekst-, tijd- en EXIF-chunks worden weggelaten.
class MetadataStrip {
  MetadataStrip._();

  static bool supports(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png');
  }

  static bool _isJpeg(Uint8List b) =>
      b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;

  static bool _isPng(Uint8List b) =>
      b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

  /// EXIF-oriëntatie (1 = normaal), of 1 als die er niet is.
  static int jpegOrientation(Uint8List b) {
    if (!_isJpeg(b)) return 1;
    var i = 2;
    while (i + 4 <= b.length && b[i] == 0xFF) {
      final marker = b[i + 1];
      if (marker == 0xDA || marker == 0xD9) break;
      final len = (b[i + 2] << 8) | b[i + 3];
      if (marker == 0xE1 &&
          i + 10 <= b.length &&
          String.fromCharCodes(b.sublist(i + 4, i + 8)) == 'Exif') {
        final o = _orientationFromTiff(b, i + 10, i + 2 + len);
        if (o != null) return o;
      }
      i += 2 + len;
    }
    return 1;
  }

  static int? _orientationFromTiff(Uint8List b, int start, int end) {
    if (start + 8 > end || end > b.length) return null;
    final le = b[start] == 0x49; // "II"
    int u16(int o) => le ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1];
    int u32(int o) => le
        ? b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)
        : (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    final ifd = start + u32(start + 4);
    if (ifd + 2 > end) return null;
    final count = u16(ifd);
    for (var n = 0; n < count; n++) {
      final e = ifd + 2 + n * 12;
      if (e + 12 > end) return null;
      if (u16(e) == 0x0112) return u16(e + 8);
    }
    return null;
  }

  /// JPEG zonder metadatasegmenten (ICC-kleurprofiel blijft).
  static Uint8List stripJpeg(Uint8List b) {
    if (!_isJpeg(b)) return b;
    final out = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
    var i = 2;
    while (i + 4 <= b.length && b[i] == 0xFF) {
      final marker = b[i + 1];
      if (marker == 0xDA) break; // begin beelddata: rest ongewijzigd
      final len = (b[i + 2] << 8) | b[i + 3];
      final next = i + 2 + len;
      if (next > b.length) break;
      final drop = marker == 0xE1 || // EXIF / XMP
          marker == 0xED || // IPTC / Photoshop
          marker == 0xFE; // commentaar
      if (!drop) out.add(Uint8List.sublistView(b, i, next));
      i = next;
    }
    out.add(Uint8List.sublistView(b, i));
    return out.takeBytes();
  }

  static const _pngDrop = {'eXIf', 'tEXt', 'zTXt', 'iTXt', 'tIME'};

  static Uint8List stripPng(Uint8List b) {
    if (!_isPng(b)) return b;
    final out = BytesBuilder(copy: false)..add(Uint8List.sublistView(b, 0, 8));
    var i = 8;
    while (i + 12 <= b.length) {
      final len =
          (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
      final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
      final next = i + 12 + len;
      if (next > b.length) break;
      if (!_pngDrop.contains(type)) {
        out.add(Uint8List.sublistView(b, i, next));
      }
      i = next;
      if (type == 'IEND') break;
    }
    return out.takeBytes();
  }

  /// Bytes zonder metadata (JPEG met draaiing wordt opnieuw opgeslagen).
  static Future<Uint8List> strip(Uint8List bytes) async {
    if (_isPng(bytes)) return stripPng(bytes);
    if (!_isJpeg(bytes)) return bytes;
    if (jpegOrientation(bytes) == 1) return stripJpeg(bytes);
    return Isolate.run(() {
      final image = img.decodeJpg(bytes);
      if (image == null) return stripJpeg(bytes);
      final upright = img.bakeOrientation(image)..exif.clear();
      return stripJpeg(img.encodeJpg(upright, quality: 92));
    });
  }

  /// Schrijft een kopie van [src] zonder metadata naar [dst].
  static Future<void> stripFile(File src, File dst) async {
    final bytes = await src.readAsBytes();
    await dst.writeAsBytes(await strip(bytes), flush: true);
  }
}
