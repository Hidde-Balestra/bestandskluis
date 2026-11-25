// Genereert de Android-appiconen en docs/logo.png uit LogoPainter.
//
//   flutter test tool/generate_icons_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bestandskluis/widgets/app_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _res = 'android/app/src/main/res';
const _densities = {
  'mdpi': 1.0,
  'hdpi': 1.5,
  'xhdpi': 2.0,
  'xxhdpi': 3.0,
  'xxxhdpi': 4.0,
};

Future<void> _render(String path, int px, LogoPainter painter) async {
  final rec = ui.PictureRecorder();
  painter.paint(Canvas(rec), Size(px.toDouble(), px.toDouble()));
  final image = await rec.endRecording().toImage(px, px);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final f = File(path)..parent.createSync(recursive: true);
  f.writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  testWidgets('iconen genereren', (tester) async {
    await tester.runAsync(() async {
      for (final MapEntry(key: d, value: scale) in _densities.entries) {
        final dir = '$_res/mipmap-$d';
        // Klassiek icoon (Android 7): 48 dp, afgerond, met achtergrond.
        await _render('$dir/ic_launcher.png', (48 * scale).round(),
            const LogoPainter());
        // Adaptief icoon (Android 8+): voorgrond op 108 dp.
        const all = Rect.fromLTWH(0, 0, 108, 108);
        await _render('$dir/ic_launcher_foreground.png', (108 * scale).round(),
            const LogoPainter(background: false, viewport: all));
        await _render('$dir/ic_launcher_monochrome.png', (108 * scale).round(),
            const LogoPainter(
                background: false, monochrome: true, viewport: all));
      }
      await _render('docs/logo.png', 512, const LogoPainter());
    });
  });
}
