import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../services/thumbnails.dart';

/// Miniatuur van een versleutelde foto of video, alleen in het geheugen
/// ontsleuteld. Video's krijgen een afspeelicoon en hun duur.
class EncryptedThumb extends StatefulWidget {
  const EncryptedThumb(
      {super.key, required this.file, this.size, this.video = false});

  final File file;
  final bool video;

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
    final img = await Thumbnails.get(widget.file, key, px.clamp(64, 512),
        video: widget.video);
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

  static String _fmt(Duration d) {
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      return '${d.inHours}:$m:$s';
    }
    return '${d.inMinutes}:$s';
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final size = widget.size;
    if (img == null) {
      return Center(
          child: Icon(
              _failed
                  ? (widget.video ? Icons.movie_outlined : Icons.image_outlined)
                  : Icons.lock,
              size: (size ?? 60) * 0.6));
    }
    Widget child = RawImage(
        image: img,
        width: size ?? double.infinity,
        height: size ?? double.infinity,
        fit: BoxFit.cover);
    if (widget.video) {
      final duration = Thumbnails.durationOf(widget.file);
      final small = size != null && size < 80;
      child = Stack(fit: StackFit.passthrough, children: [
        child,
        Positioned.fill(
          child: Center(
            child: Icon(Icons.play_circle_fill,
                color: Colors.white70,
                size: small ? size * 0.45 : 36,
                shadows: const [Shadow(blurRadius: 4)]),
          ),
        ),
        if (duration != null && duration > Duration.zero && !small)
          Positioned(
            right: 4,
            bottom: 4,
            child: Text(_fmt(duration),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    shadows: [Shadow(blurRadius: 3)])),
          ),
      ]);
    }
    return size == null
        ? child
        : ClipRRect(borderRadius: BorderRadius.circular(4), child: child);
  }
}
