import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../widgets/dialogs.dart';

/// Eén foto of video in de viewer. [load] levert een leesbaar bestand
/// (eventueel een tijdelijk ontsleutelde kopie).
class MediaItem {
  MediaItem(
      {required this.name,
      required this.isVideo,
      required this.load,
      this.share,
      this.delete,
      this.encrypted = false});

  final String name;
  final bool isVideo;
  final bool encrypted;
  final Future<File> Function() load;
  final Future<void> Function()? share;

  /// Verwijdert het item (na bevestiging in de viewer); false = niet
  /// verwijderd (bijv. geannuleerd in de Android-dialoog).
  final Future<bool> Function()? delete;
}

class MediaViewer extends StatefulWidget {
  const MediaViewer({super.key, required this.items, this.initialIndex = 0});

  final List<MediaItem> items;
  final int initialIndex;

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  late final List<MediaItem> _items = List.of(widget.items);
  bool _chrome = true;
  bool _deleted = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _delete(MediaItem item) async {
    final ok = await confirmDialog(context,
        title: 'Verwijderen',
        message: '"${item.name}" permanent verwijderen?',
        confirm: 'Verwijderen',
        destructive: true);
    if (!ok || !mounted) return;
    try {
      if (!await item.delete!()) return;
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    _deleted = true;
    if (_items.length == 1) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _items.removeAt(_index);
      if (_index >= _items.length) _index = _items.length - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = _items[_index];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // Teruggeven of er iets is verwijderd, zodat de lijst ververst.
        if (!didPop) Navigator.pop(context, _deleted);
      },
      child: _scaffold(item),
    );
  }

  Widget _scaffold(MediaItem item) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _chrome
          ? AppBar(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              title: Row(children: [
                if (item.encrypted)
                  const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.lock, size: 18)),
                Expanded(
                    child: Text(item.name, overflow: TextOverflow.ellipsis)),
              ]),
              actions: [
                if (item.share != null)
                  IconButton(
                    tooltip: 'Delen',
                    icon: const Icon(Icons.share),
                    onPressed: () async {
                      try {
                        await item.share!();
                      } catch (e) {
                        if (mounted) showError(context, e);
                      }
                    },
                  ),
                if (item.delete != null)
                  IconButton(
                    tooltip: 'Verwijderen',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(item),
                  ),
              ],
            )
          : null,
      body: PageView.builder(
        controller: _pages,
        itemCount: _items.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => GestureDetector(
          onTap: () => setState(() => _chrome = !_chrome),
          child: _MediaPage(
              key: ValueKey(_items[i]),
              item: _items[i],
              active: i == _index),
        ),
      ),
    );
  }
}

class _MediaPage extends StatefulWidget {
  const _MediaPage({super.key, required this.item, required this.active});
  final MediaItem item;
  final bool active;

  @override
  State<_MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<_MediaPage> {
  late final Future<File> _file = widget.item.load();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: _file,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
              child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Kan niet openen: ${snap.error}',
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center),
          ));
        }
        if (!snap.hasData) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              if (widget.item.encrypted)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('Ontsleutelen…',
                      style: TextStyle(color: Colors.white70)),
                ),
            ]),
          );
        }
        if (widget.item.isVideo) {
          return _VideoView(file: snap.data!, active: widget.active);
        }
        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: Image.file(snap.data!,
                errorBuilder: (_, e, _) => const Icon(Icons.broken_image,
                    color: Colors.white54, size: 64)),
          ),
        );
      },
    );
  }
}

class _VideoView extends StatefulWidget {
  const _VideoView({required this.file, required this.active});
  final File file;
  final bool active;

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  late final VideoPlayerController _c = VideoPlayerController.file(widget.file);
  String? _error;

  @override
  void initState() {
    super.initState();
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      if (widget.active) _c.play();
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
    _c.addListener(_tick);
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _VideoView old) {
    super.didUpdateWidget(old);
    if (!widget.active && _c.value.isPlaying) _c.pause();
  }

  @override
  void dispose() {
    _c.removeListener(_tick);
    _c.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
          child: Text('Video kan niet worden afgespeeld\n$_error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)));
    }
    final v = _c.value;
    if (!v.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    final pos = v.position;
    final dur = v.duration;
    return Stack(children: [
      Center(
          child: AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(_c))),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SafeArea(
          child: Container(
            color: Colors.black45,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              IconButton(
                color: Colors.white,
                icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () => v.isPlaying ? _c.pause() : _c.play(),
              ),
              Text(_fmt(pos), style: const TextStyle(color: Colors.white)),
              Expanded(
                child: Slider(
                  value: pos.inMilliseconds
                      .clamp(0, dur.inMilliseconds)
                      .toDouble(),
                  max: dur.inMilliseconds.toDouble().clamp(1, double.infinity),
                  onChanged: (x) =>
                      _c.seekTo(Duration(milliseconds: x.round())),
                ),
              ),
              Text(_fmt(dur), style: const TextStyle(color: Colors.white)),
            ]),
          ),
        ),
      ),
    ]);
  }
}
