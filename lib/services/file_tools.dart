import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:path/path.dart' as p;

import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';

/// Een bestand met zijn leesbare naam en (inhouds)grootte.
class FileInfo {
  FileInfo(this.file, this.name, this.size, this.modified, {this.encrypted = false});
  final File file;
  final String name;
  final int size;
  final DateTime modified;
  final bool encrypted;
}

/// Grootte van een map (recursief).
class DirUsage {
  DirUsage(this.dir, this.bytes, this.files);
  final Directory dir;
  final int bytes;
  final int files;
}

/// Resultaat van een opslaganalyse.
class StorageReport {
  StorageReport(this.total, this.files, this.dirs, this.largest);
  final int total;
  final int files;

  /// Submappen, grootste eerst (de map zelf als "losse bestanden" niet).
  final List<DirUsage> dirs;

  /// Grootste bestanden in de hele boom.
  final List<FileInfo> largest;
}

/// Duplicaten zoeken en opslag analyseren, ook in kluizen.
class FileTools {
  FileTools(this.vaults);
  final VaultManager vaults;

  static bool _skip(String name) =>
      name == VaultManager.markerName ||
      name == VaultManager.trashDirName ||
      name.endsWith('.part') ||
      name.startsWith('.bestandskluis-meta');

  FileInfo? _info(File f, FileStat st) {
    final name = p.basename(f.path);
    final root = vaults.vaultRootFor(f.parent.path);
    if (root != null && VaultCrypto.isEncryptedName(name)) {
      return FileInfo(f, VaultCrypto.plainName(name, vaults.keyFor(root)),
          VaultCrypto.plainLength(st.size), st.modified,
          encrypted: true);
    }
    return FileInfo(f, name, st.size, st.modified);
  }

  Stream<(File, FileStat)> _walk(Directory dir) async* {
    final queue = [dir];
    while (queue.isNotEmpty) {
      final d = queue.removeLast();
      try {
        await for (final e in d.list(followLinks: false)) {
          if (_skip(p.basename(e.path))) continue;
          if (e is Directory) {
            queue.add(e);
          } else if (e is File) {
            yield (e, await e.stat());
          }
        }
      } on FileSystemException {
        continue;
      }
    }
  }

  /// SHA-256 van de (ontsleutelde) inhoud.
  Future<String?> _hash(FileInfo f) async {
    final sink = const DartSha256().newHashSink();
    try {
      if (f.encrypted) {
        final key = vaults.keyForDir(f.file.parent.path);
        if (key == null) return null; // vergrendeld
        await for (final c in VaultCrypto.decryptStream(f.file, key)) {
          sink.add(c);
        }
      } else {
        await for (final c in f.file.openRead()) {
          sink.add(c);
        }
      }
      sink.close();
      return sink.hashSync().bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    } catch (_) {
      return null;
    }
  }

  /// Groepen bestanden met dezelfde inhoud (grootste verspilling eerst).
  /// Eerst op grootte, daarna alleen bij gelijke grootte de inhoud hashen.
  Future<List<List<FileInfo>>> findDuplicates(Directory dir,
      {int minSize = 1, void Function(String status)? onProgress}) async {
    final bySize = <int, List<FileInfo>>{};
    var n = 0;
    await for (final (f, st) in _walk(dir)) {
      final info = _info(f, st);
      if (info == null || info.size < minSize) continue;
      bySize.putIfAbsent(info.size, () => []).add(info);
      if (++n % 200 == 0) onProgress?.call('$n bestanden bekeken');
    }
    final groups = <List<FileInfo>>[];
    final candidates = bySize.values.where((l) => l.length > 1).toList();
    var done = 0;
    for (final same in candidates) {
      final byHash = <String, List<FileInfo>>{};
      for (final f in same) {
        final h = await _hash(f);
        if (h != null) byHash.putIfAbsent(h, () => []).add(f);
      }
      for (final g in byHash.values) {
        if (g.length > 1) {
          // Oudste eerst: die wordt standaard bewaard.
          g.sort((a, b) => a.modified.compareTo(b.modified));
          groups.add(g);
        }
      }
      onProgress?.call('Inhoud vergelijken: ${++done} / ${candidates.length}');
    }
    groups.sort((a, b) =>
        (b.first.size * (b.length - 1)).compareTo(a.first.size * (a.length - 1)));
    return groups;
  }

  /// Hoeveel ruimte de submappen en bestanden van [dir] innemen (ruimte op
  /// schijf, dus inclusief de kleine extra ruimte van versleuteling).
  Future<StorageReport> analyze(Directory dir,
      {int top = 30, void Function(String status)? onProgress}) async {
    final usage = <String, (int, int)>{};
    final largest = <FileInfo>[];
    var total = 0;
    var count = 0;
    await for (final (f, st) in _walk(dir)) {
      total += st.size;
      count++;
      final rel = p.split(p.relative(f.path, from: dir.path));
      if (rel.length > 1) {
        final sub = p.join(dir.path, rel.first);
        final (b, c) = usage[sub] ?? (0, 0);
        usage[sub] = (b + st.size, c + 1);
      }
      final info = _info(f, st);
      if (info != null) {
        largest.add(FileInfo(f, info.name, st.size, st.modified,
            encrypted: info.encrypted));
        if (largest.length > top * 4) {
          largest.sort((a, b) => b.size.compareTo(a.size));
          largest.removeRange(top, largest.length);
        }
      }
      if (count % 500 == 0) onProgress?.call('$count bestanden geteld');
    }
    largest.sort((a, b) => b.size.compareTo(a.size));
    if (largest.length > top) largest.removeRange(top, largest.length);
    final dirs = [
      for (final MapEntry(key: path, value: (b, c)) in usage.entries)
        DirUsage(Directory(path), b, c),
    ]..sort((a, b) => b.bytes.compareTo(a.bytes));
    return StorageReport(total, count, dirs, largest);
  }
}
