import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../app_services.dart';
import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';
import '../services/temp_files.dart';
import '../util/format.dart';
import '../widgets/dialogs.dart';
import 'media_viewer.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  static const _pageSize = 120;

  bool? _access;
  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _album;

  /// null = apparaatalbum, true = media uit ontgrendelde kluizen.
  bool _vaultMode = false;
  final List<AssetEntity> _assets = [];
  List<File> _vaultFiles = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    services.vaults.addListener(_onVaults);
    _init();
  }

  @override
  void dispose() {
    services.vaults.removeListener(_onVaults);
    super.dispose();
  }

  void _onVaults() {
    if (_vaultMode) _loadVaultMedia();
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    final state = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    setState(() => _access = state.hasAccess);
    if (!state.hasAccess) return;
    final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common, hasAll: true);
    if (!mounted) return;
    setState(() {
      _albums = albums;
      _album = albums.isEmpty ? null : albums.first;
    });
    await _reset();
  }

  Future<void> _reset() async {
    _assets.clear();
    _selected.clear();
    _page = 0;
    _hasMore = true;
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (_loading || !_hasMore || album == null) return;
    _loading = true;
    final page = await album.getAssetListPaged(page: _page, size: _pageSize);
    _loading = false;
    if (!mounted) return;
    setState(() {
      _assets.addAll(page);
      _page++;
      _hasMore = page.length == _pageSize;
    });
  }

  /// Alle media van het album selecteren (laadt eerst de overige pagina's).
  Future<void> _selectAll() async {
    while (_hasMore && mounted) {
      if (_loading) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
      await _loadMore();
    }
    if (mounted) setState(() => _selected.addAll(_assets.map((a) => a.id)));
  }

  Future<void> _loadVaultMedia() async {
    final files = <File>[];
    for (final root in services.vaults.unlockedVaults) {
      try {
        await for (final e
            in Directory(root).list(recursive: true, followLinks: false)) {
          final name = p.basename(e.path);
          if (e is File &&
              VaultCrypto.isEncryptedName(name) &&
              isMedia(VaultCrypto.plainName(name))) {
            files.add(e);
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (mounted) setState(() => _vaultFiles = files);
  }

  // --- Openen ---------------------------------------------------------------

  void _openAsset(int index) {
    final items = _assets
        .map((a) => MediaItem(
              name: a.title ?? 'Media',
              isVideo: a.type == AssetType.video,
              load: () async {
                final f = await a.file;
                if (f == null) throw StateError('Bestand niet beschikbaar');
                return f;
              },
              share: () async {
                final f = await a.file;
                if (f != null) {
                  await SharePlus.instance
                      .share(ShareParams(files: [XFile(f.path)]));
                }
              },
            ))
        .toList();
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => MediaViewer(items: items, initialIndex: index)));
  }

  void _openVaultFile(int index) {
    final items = _vaultFiles.map((f) {
      final name = VaultCrypto.plainName(p.basename(f.path));
      return MediaItem(
        name: name,
        isVideo: kindOf(name) == FileKind.video,
        encrypted: true,
        load: () => TempFiles.plainFor(f, services.ops.keyForFile(f)),
        share: () => TempFiles.share([f], services.vaults).then((_) {}),
      );
    }).toList();
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => MediaViewer(items: items, initialIndex: index)));
  }

  // --- Naar kluis verplaatsen -----------------------------------------------

  Future<void> _moveToVault() async {
    final vaults = services.vaults.unlockedVaults.toList();
    if (vaults.isEmpty) {
      showMessage(context,
          'Ontgrendel eerst een kluis (of versleutel een map) in Bestanden');
      return;
    }
    final target = vaults.length == 1
        ? vaults.first
        : await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('Naar welke kluis?'),
              children: [
                for (final v in vaults)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, v),
                      child: Text(p.basename(v))),
              ],
            ),
          );
    if (target == null || !mounted) return;
    final selected = _assets.where((a) => _selected.contains(a.id)).toList();
    final ok = await confirmDialog(context,
        title: 'Naar kluis verplaatsen',
        message: '${selected.length} item(s) versleutelen in '
            '"${p.basename(target)}" en uit de galerij verwijderen?',
        confirm: 'Verplaatsen');
    if (!ok || !mounted) return;
    final key = services.vaults.keyFor(target)!;
    final done = <String>[];
    await runWithProgress(context, 'Versleutelen…', (update) async {
      for (var i = 0; i < selected.length; i++) {
        update('${i + 1} / ${selected.length}');
        final f = await selected[i].originFile;
        if (f == null) continue;
        await VaultManager.encryptInto(f, target, key);
        done.add(selected[i].id);
      }
    });
    if (done.isNotEmpty) {
      // Android vraagt hier zelf om bevestiging.
      await PhotoManager.editor.deleteWithIds(done);
    }
    await _reset();
  }

  // --- Opbouw ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    return Scaffold(
      appBar: selecting
          ? AppBar(
              leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(_selected.clear)),
              title: Text('${_selected.length} geselecteerd'),
              actions: [
                if (_hasMore || _selected.length < _assets.length)
                  IconButton(
                      tooltip: 'Alles selecteren',
                      icon: const Icon(Icons.select_all),
                      onPressed: _selectAll)
                else
                  IconButton(
                      tooltip: 'Niets selecteren',
                      icon: const Icon(Icons.deselect),
                      onPressed: () => setState(_selected.clear)),
                IconButton(
                  tooltip: 'Delen',
                  icon: const Icon(Icons.share),
                  onPressed: () async {
                    final files = <XFile>[];
                    for (final a in _assets.where((a) => _selected.contains(a.id))) {
                      final f = await a.file;
                      if (f != null) files.add(XFile(f.path));
                    }
                    if (files.isNotEmpty) {
                      await SharePlus.instance.share(ShareParams(files: files));
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Naar kluis verplaatsen',
                  icon: const Icon(Icons.enhanced_encryption),
                  onPressed: _moveToVault,
                ),
              ],
            )
          : AppBar(title: const Text('Galerij'), actions: [
              if (!_vaultMode && _assets.isNotEmpty)
                IconButton(
                    tooltip: 'Alles selecteren',
                    icon: const Icon(Icons.select_all),
                    onPressed: _selectAll),
            ]),
      body: Column(children: [
        if (!selecting) _albumBar(),
        Expanded(child: _vaultMode ? _vaultGrid() : _deviceGrid()),
      ]),
    );
  }

  Widget _albumBar() {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              avatar: const Icon(Icons.lock, size: 16),
              label: const Text('Kluizen'),
              selected: _vaultMode,
              onSelected: (_) {
                setState(() => _vaultMode = true);
                _loadVaultMedia();
              },
            ),
          ),
          for (final a in _albums)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(a.isAll ? 'Alles' : a.name),
                selected: !_vaultMode && _album?.id == a.id,
                onSelected: (_) {
                  setState(() {
                    _vaultMode = false;
                    _album = a;
                  });
                  _reset();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _deviceGrid() {
    if (_access == null) return const Center(child: CircularProgressIndicator());
    if (_access == false) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Geen toegang tot foto\'s en video\'s'),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: () async {
                await PhotoManager.openSetting();
              },
              child: const Text('Instellingen openen')),
          TextButton(onPressed: _init, child: const Text('Opnieuw proberen')),
        ]),
      );
    }
    if (_assets.isEmpty) {
      return Center(
          child: _loading || _hasMore && _album != null
              ? const CircularProgressIndicator()
              : const Text('Geen media gevonden'));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) _loadMore();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: _reset,
        child: GridView.builder(
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 120, mainAxisSpacing: 2, crossAxisSpacing: 2),
          itemCount: _assets.length,
          itemBuilder: (context, i) {
            final a = _assets[i];
            final selected = _selected.contains(a.id);
            return GestureDetector(
              onTap: () {
                if (_selected.isNotEmpty) {
                  setState(() {
                    if (!_selected.remove(a.id)) _selected.add(a.id);
                  });
                } else {
                  _openAsset(i);
                }
              },
              onLongPress: () => setState(() {
                if (!_selected.remove(a.id)) _selected.add(a.id);
              }),
              child: Stack(fit: StackFit.expand, children: [
                _AssetThumb(asset: a),
                if (a.type == AssetType.video)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Text(_duration(a.videoDuration),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [Shadow(blurRadius: 3)])),
                  ),
                if (selected) ...[
                  Container(color: Colors.black38),
                  const Center(
                      child: Icon(Icons.check_circle, color: Colors.white)),
                ],
              ]),
            );
          },
        ),
      ),
    );
  }

  String _duration(Duration d) =>
      '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  Widget _vaultGrid() {
    if (services.vaults.unlockedVaults.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
              'Geen ontgrendelde kluizen. Open een kluis in Bestanden om de '
              'foto\'s en video\'s erin hier te zien.',
              textAlign: TextAlign.center),
        ),
      );
    }
    if (_vaultFiles.isEmpty) {
      return const Center(child: Text('Geen foto\'s of video\'s in de kluizen'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 120, mainAxisSpacing: 2, crossAxisSpacing: 2),
      itemCount: _vaultFiles.length,
      itemBuilder: (context, i) {
        final f = _vaultFiles[i];
        final video = kindOf(p.basename(f.path)) == FileKind.video;
        return GestureDetector(
          onTap: () => _openVaultFile(i),
          child: Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: video
                ? const Icon(Icons.movie, size: 40)
                : _VaultThumb(file: f),
          ),
        );
      },
    );
  }
}

class _AssetThumb extends StatelessWidget {
  const _AssetThumb({required this.asset});
  final AssetEntity asset;

  static final Map<String, Uint8List> _cache = {};

  @override
  Widget build(BuildContext context) {
    final cached = _cache[asset.id];
    if (cached != null) return Image.memory(cached, fit: BoxFit.cover);
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(const ThumbnailSize.square(240)),
      builder: (_, s) {
        final data = s.data;
        if (data == null) {
          return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest);
        }
        if (_cache.length > 600) _cache.remove(_cache.keys.first);
        _cache[asset.id] = data;
        return Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}

class _VaultThumb extends StatefulWidget {
  const _VaultThumb({required this.file});
  final File file;
  @override
  State<_VaultThumb> createState() => _VaultThumbState();
}

class _VaultThumbState extends State<_VaultThumb> {
  late final Future<File> _plain =
      TempFiles.plainFor(widget.file, services.ops.keyForFile(widget.file));

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
        future: _plain,
        builder: (_, s) => s.hasData
            ? Image.file(s.data!,
                fit: BoxFit.cover,
                cacheWidth: 240,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image))
            : const Center(child: Icon(Icons.lock)),
      );
}
