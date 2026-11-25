import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../services/thumbnails.dart';

/// Miniatuur van een versleutelde foto, alleen in het geheugen ontsleuteld.
class EncryptedThumb extends StatefulWidget {
  const EncryptedThumb({super.key, required this.file, this.size});

  final File file;

  /// Vaste maat; zonder maat vult de miniatuur de beschikbare ruimte.
  final double? size;

  @override
  State<EncryptedThumb> createState() => _EncryptedThumbState();
}

class _EncryptedThumbState extends State<EncryptedThumb> {
  ui.Image? _image;
  bool _failed = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final key = services.ops.keyForFile(widget.file);
    if (key == null) {
      setState(() => _failed = true);
      return;
    }
    final logical = widget.size ?? 160;
    final px = (logical * MediaQuery.devicePixelRatioOf(context)).round();
    final img = await Thumbnails.get(widget.file, key, px.clamp(64, 512));
    if (!mounted) {
      img?.dispose();
      return;
    }
    setState(() {
      _image = img;
      _failed = img == null;
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final size = widget.size;
    if (img != null) {
      final raw = RawImage(
          image: img,
          width: size ?? double.infinity,
          height: size ?? double.infinity,
          fit: BoxFit.cover);
      return size == null
          ? raw
          : ClipRRect(borderRadius: BorderRadius.circular(4), child: raw);
    }
    return Center(
        child: Icon(_failed ? Icons.image_outlined : Icons.lock,
            size: (size ?? 60) * 0.6));
  }
}
