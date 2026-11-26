import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../crypto/vault_manager.dart';
import 'memory_files.dart';

/// Favorieten en albums van één kluis.
class VaultMeta {
  VaultMeta({Set<String>? favorites, Map<String, List<String>>? albums})
      : favorites = favorites ?? {},
        albums = albums ?? {};

  /// Paden relatief aan de kluis (met '/').
  final Set<String> favorites;
  final Map<String, List<String>> albums;

  Map<String, dynamic> toJson() => {
        'versie': 1,
        'favorieten': favorites.toList()..sort(),
        'albums': albums,
      };

  static VaultMeta fromJson(Map<String, dynamic> j) => VaultMeta(
        favorites: {...((j['favorieten'] as List?) ?? const []).cast<String>()},
        albums: {
          for (final MapEntry(:key, :value)
              in ((j['albums'] as Map?) ?? const {}).entries)
            key as String: [...(value as List).cast<String>()],
        },
      );
}

/// Albums en favorieten, versleuteld opgeslagen in de kluis zelf
/// (`.bestandskluis-meta.bkv`), zodat ze meegaan met back-ups.
class VaultMetaStore extends ChangeNotifier {
  VaultMetaStore(this.vaults) {
    vaults.addListener(_onVaults);
  }

  final VaultManager vaults;
  static const fileName = '.bestandskluis-meta.bkv';
  final _cache = <String, VaultMeta>{};

  void _onVaults() {
    // Vergrendelde kluizen uit het geheugen halen.
    final open = vaults.unlockedVaults.toSet();
    final before = _cache.length;
    _cache.removeWhere((root, _) => !open.contains(root));
    if (_cache.length != before) notifyListeners();
  }

  static String rel(String root, String path) =>
      p.split(p.relative(path, from: root)).join('/');

  File _file(String root) => File(p.join(root, fileName));

  /// Laadt (en onthoudt) de gegevens van een ontgrendelde kluis.
  Future<VaultMeta> load(String root) async {
    root = p.normalize(root);
    final cached = _cache[root];
    if (cached != null) return cached;
    final key = vaults.keyFor(root);
    if (key == null) throw StateError('Kluis is vergrendeld');
    final f = _file(root);
    VaultMeta meta;
    if (await f.exists()) {
      try {
        meta = VaultMeta.fromJson(
            jsonDecode(await MemoryFiles.readText(f, key)) as Map<String, dynamic>);
      } catch (_) {
        meta = VaultMeta();
      }
    } else {
      meta = VaultMeta();
    }
    _cache[root] = meta;
    return meta;
  }

  /// Uit het geheugen, zonder te laden (null als nog niet geladen).
  VaultMeta? cached(String root) => _cache[p.normalize(root)];

  Future<void> _save(String root, VaultMeta meta) async {
    final key = vaults.keyFor(root);
    if (key == null) throw StateError('Kluis is vergrendeld');
    await MemoryFiles.writeText(_file(root), jsonEncode(meta.toJson()), key);
    notifyListeners();
  }

  String? _rootOf(File f) => vaults.vaultRootFor(f.parent.path);

  bool isFavorite(File f) {
    final root = _rootOf(f);
    if (root == null) return false;
    return cached(root)?.favorites.contains(rel(root, f.path)) ?? false;
  }

  Future<bool> toggleFavorite(File f) async {
    final root = _rootOf(f);
    if (root == null) throw StateError('Alleen voor bestanden in een kluis');
    final meta = await load(root);
    final r = rel(root, f.path);
    final now = !meta.favorites.remove(r);
    if (now) meta.favorites.add(r);
    await _save(root, meta);
    return now;
  }

  Future<void> addToAlbum(String album, List<File> files) async {
    final byRoot = <String, List<File>>{};
    for (final f in files) {
      final root = _rootOf(f);
      if (root != null) byRoot.putIfAbsent(root, () => []).add(f);
    }
    for (final MapEntry(key: root, value: fs) in byRoot.entries) {
      final meta = await load(root);
      final list = meta.albums.putIfAbsent(album, () => []);
      for (final f in fs) {
        final r = rel(root, f.path);
        if (!list.contains(r)) list.add(r);
      }
      await _save(root, meta);
    }
  }

  Future<void> removeFromAlbum(String album, List<File> files) async {
    for (final f in files) {
      final root = _rootOf(f);
      if (root == null) continue;
      final meta = await load(root);
      meta.albums[album]?.remove(rel(root, f.path));
      await _save(root, meta);
    }
  }

  Future<void> deleteAlbum(String album) async {
    for (final root in vaults.unlockedVaults) {
      final meta = await load(root);
      if (meta.albums.remove(album) != null) await _save(root, meta);
    }
  }

  /// Albumnamen in alle ontgrendelde kluizen.
  Future<List<String>> albumNames() async {
    final names = <String>{};
    for (final root in vaults.unlockedVaults) {
      names.addAll((await load(root)).albums.keys);
    }
    return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Of [f] in [album] (of bij de favorieten, als [album] null is) zit.
  Future<bool> contains(File f, String? album) async {
    final root = _rootOf(f);
    if (root == null) return false;
    final meta = await load(root);
    final r = rel(root, f.path);
    return album == null
        ? meta.favorites.contains(r)
        : (meta.albums[album]?.contains(r) ?? false);
  }
}
