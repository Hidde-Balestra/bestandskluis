import 'dart:typed_data';

import 'package:bestandskluis/services/metadata_strip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  Uint8List jpegWithExif({int orientation = 1}) {
    final image = img.Image(width: 40, height: 20);
    img.fill(image, color: img.ColorRgb8(200, 30, 30));
    image.exif.imageIfd['Make'] = img.IfdValueAscii('Telefoonmerk');
    image.exif.imageIfd.orientation = orientation;
    image.exif.gpsIfd['GPSLatitudeRef'] = img.IfdValueAscii('N');
    return img.encodeJpg(image);
  }

  test('EXIF (met GPS) verdwijnt uit een JPEG zonder herschrijven', () async {
    final bytes = jpegWithExif();
    expect(img.decodeJpgExif(bytes)?.isEmpty ?? true, isFalse);
    final out = await MetadataStrip.strip(bytes);
    expect(img.decodeJpgExif(out)?.isEmpty ?? true, isTrue);
    // Zelfde beeld, kleiner bestand.
    expect(out.length, lessThan(bytes.length));
    final a = img.decodeJpg(bytes)!;
    final b = img.decodeJpg(out)!;
    expect([b.width, b.height], [a.width, a.height]);
  });

  test('gedraaide foto wordt rechtop gezet', () async {
    final bytes = jpegWithExif(orientation: 6); // 90° gedraaid
    expect(MetadataStrip.jpegOrientation(bytes), 6);
    final out = await MetadataStrip.strip(bytes);
    expect(img.decodeJpgExif(out)?.isEmpty ?? true, isTrue);
    final b = img.decodeJpg(out)!;
    expect([b.width, b.height], [20, 40]);
  });

  test('PNG-tekst wordt verwijderd, beeld blijft', () async {
    final image = img.Image(width: 8, height: 8)
      ..textData = {'Comment': 'geheime locatie'};
    final bytes = img.encodePng(image);
    expect(String.fromCharCodes(bytes).contains('geheime locatie'), isTrue);
    final out = await MetadataStrip.strip(bytes);
    expect(String.fromCharCodes(out).contains('geheime locatie'), isFalse);
    expect(img.decodePng(out)!.width, 8);
  });
}
