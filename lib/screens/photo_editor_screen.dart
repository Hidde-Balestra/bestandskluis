import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../app_services.dart';
import '../services/memory_files.dart';
import '../services/metadata_strip.dart';
import '../widgets/dialogs.dart';

/// Bewerking: kwartslagen draaien en daarna bijsnijden (fracties 0–1 van
/// het gedraaide beeld).
class PhotoEdit {
  PhotoEdit._();

  static Future<Uint8List> apply(Uint8List bytes, int quarterTurns, Rect crop,
      {required bool png}) {
    final l = crop.left, t = crop.top, w = crop.width, h = crop.height;
    return Isolate.run(() {
      var image = img.decodeImage(bytes);
      if (image == null) throw StateError('Deze foto kan niet worden bewerkt');
      image = img.bakeOrientation(image);
      final turns = quarterTurns % 4;
      if (turns != 0) image = img.copyRotate(image, angle: 90 * turns);
      final x = (l * image.width).round().clamp(0, image.width - 1);
      final y = (t * image.height).round().clamp(0, image.height - 1);
      final cw = (w * image.width).round().clamp(1, image.width - x);
      final ch = (h * image.height).round().clamp(1, image.height - y);
      if (x != 0 || y != 0 || cw != image.width || ch != image.height) {
        image = img.copyCrop(image, x: x, y: y, width: cw, height: ch);
      }
      image.exif.clear();
      return png ? img.encodePng(image) : img.encodeJpg(image, quality: 92);
    });
  }
}

/// Draaien en bijsnijden, ook voor foto's in een kluis (alles in het
/// geheugen; het resultaat wordt weer versleuteld opgeslagen).
class PhotoEditorScreen extends StatefulWidget {
  const PhotoEditorScreen({super.key, required this.file, required this.name});

  final File file;
  final String name;

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  Uint8List? _bytes;
  String? _error;
  int _turns = 0;
  Rect _crop = const Rect.fromLTWH(0, 0, 1, 1);
  Size? _imageSize;

  bool get _png => widget.name.toLowerCase().endsWith('.png');
  bool get _changed => _turns % 4 != 0 || _crop != const Rect.fromLTWH(0, 0, 1, 1);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var b = await MemoryFiles.readBytes(
          widget.file, services.ops.keyForFile(widget.file));
      // EXIF-draaiing eerst verwerken, zodat voorbeeld en resultaat kloppen.
      if (MetadataStrip.jpegOrientation(b) != 1) {
        final src = b;
        b = await Isolate.run(() => img.encodeJpg(
            img.bakeOrientation(img.decodeJpg(src)!)..exif.clear(),
            quality: 95));
      }
      final codec = await instantiateImageCodecSize(b);
      if (!mounted) return;
      setState(() {
        _bytes = b;
        _imageSize = codec;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  static Future<Size> instantiateImageCodecSize(Uint8List b) async {
    final buffer = await ImmutableBuffer.fromUint8List(b);
    final desc = await ImageDescriptor.encoded(buffer);
    final s = Size(desc.width.toDouble(), desc.height.toDouble());
    desc.dispose();
    buffer.dispose();
    return s;
  }

  void _rotate(int d) => setState(() {
        _turns = (_turns + d) % 4;
        _crop = const Rect.fromLTWH(0, 0, 1, 1);
      });

  Future<void> _save() async {
    final bytes = _bytes;
    if (bytes == null) return;
    final ok = await runWithProgress(context, 'Opslaan…', (_) async {
      final out = await PhotoEdit.apply(bytes, _turns, _crop, png: _png);
      await MemoryFiles.writeBytes(
          widget.file, out, services.ops.keyForFile(widget.file));
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Bewerken'),
        actions: [
          TextButton(
            onPressed: _changed ? _save : null,
            child: const Text('Opslaan'),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Text(_error!, style: const TextStyle(color: Colors.white70)))
          : bytes == null || _imageSize == null
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(child: _cropArea(bytes)),
                    ),
                  ),
                  SafeArea(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _tool(Icons.rotate_left, 'Linksom', () => _rotate(3)),
                        _tool(Icons.rotate_right, 'Rechtsom', () => _rotate(1)),
                        _tool(Icons.crop_free, 'Herstel', () => setState(() {
                              _turns = 0;
                              _crop = const Rect.fromLTWH(0, 0, 1, 1);
                            })),
                      ],
                    ),
                  ),
                ]),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback onTap) => TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: Colors.white),
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label),
      );

  Widget _cropArea(Uint8List bytes) {
    final s = _imageSize!;
    final rotated = _turns.isOdd ? Size(s.height, s.width) : s;
    return AspectRatio(
      aspectRatio: rotated.width / rotated.height,
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final r = Rect.fromLTWH(_crop.left * w, _crop.top * h,
            _crop.width * w, _crop.height * h);
        void drag(Offset d, {bool left = false, bool top = false,
            bool right = false, bool bottom = false, bool move = false}) {
          const min = 0.08;
          var c = _crop;
          final dx = d.dx / w, dy = d.dy / h;
          if (move) {
            c = c.shift(Offset(dx, dy));
            c = c.shift(Offset(
                c.left < 0 ? -c.left : (c.right > 1 ? 1 - c.right : 0),
                c.top < 0 ? -c.top : (c.bottom > 1 ? 1 - c.bottom : 0)));
          } else {
            var l = c.left, t = c.top, rr = c.right, b = c.bottom;
            if (left) l = (l + dx).clamp(0, rr - min);
            if (right) rr = (rr + dx).clamp(l + min, 1);
            if (top) t = (t + dy).clamp(0, b - min);
            if (bottom) b = (b + dy).clamp(t + min, 1);
            c = Rect.fromLTRB(l, t, rr, b);
          }
          setState(() => _crop = c);
        }

        Widget handle(Alignment a, void Function(Offset) onDrag) => Positioned(
              left: (a.x < 0 ? r.left : r.right) - 18,
              top: (a.y < 0 ? r.top : r.bottom) - 18,
              child: GestureDetector(
                onPanUpdate: (u) => onDrag(u.delta),
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle)),
                ),
              ),
            );

        return Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
            child: RotatedBox(
              quarterTurns: _turns,
              child: Image.memory(bytes, fit: BoxFit.fill, gaplessPlayback: true),
            ),
          ),
          // Donker buiten het kader.
          Positioned.fill(
            child: CustomPaint(painter: _ShadePainter(r)),
          ),
          Positioned.fromRect(
            rect: r,
            child: GestureDetector(
              onPanUpdate: (u) => drag(u.delta, move: true),
              child: Container(
                decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 2)),
              ),
            ),
          ),
          handle(Alignment.topLeft, (d) => drag(d, left: true, top: true)),
          handle(Alignment.topRight, (d) => drag(d, right: true, top: true)),
          handle(Alignment.bottomLeft, (d) => drag(d, left: true, bottom: true)),
          handle(Alignment.bottomRight, (d) => drag(d, right: true, bottom: true)),
        ]);
      }),
    );
  }
}

class _ShadePainter extends CustomPainter {
  _ShadePainter(this.keep);
  final Rect keep;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..addRect(Offset.zero & size)
      ..addRect(keep)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(p, Paint()..color = Colors.black54);
  }

  @override
  bool shouldRepaint(_ShadePainter old) => old.keep != keep;
}
