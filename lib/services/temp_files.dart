import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';

/// Tijdelijk ontsleutelde kopieën voor bekijken en delen.
///
/// Ontsleutelde bestanden staan alleen in de cachemap van de app en worden
/// opgeruimd: na het delen (met wat speling zodat de ontvangende app het kan
/// inlezen), bij het vergrendelen van kluizen en bij het starten van de app.
class TempFiles {
  TempFiles._();

  static const shareDelay = Duration(minutes: 10);
  static final Map<String, File> _viewCache = {};
  static final Set<Timer> _timers = {};

  /// Overschrijfbaar in tests.
  static Future<Directory> Function() baseDir = getTemporaryDirectory;

  static Future<Directory> _dir(String sub) async {
    final d = Directory(p.join((await baseDir()).path, 'bestandskluis', sub));
    return d.create(recursive: true);
  }

  /// Leesbaar bestand voor [file]: het bestand zelf, of een ontsleutelde
  /// tijdelijke kopie als het in een kluis zit.
  static Future<File> plainFor(File file, SecretKey? key) async {
    if (!VaultCrypto.isEncryptedName(p.basename(file.path))) return file;
    if (key == null) throw StateError('Kluis is vergrendeld');
    final st = await file.stat();
    final cacheKey = '${file.path}|${st.modified.millisecondsSinceEpoch}';
    final cached = _viewCache[cacheKey];
    if (cached != null && await cached.exists()) return cached;
    final dir = await _dir('bekijken');
    final sub = Directory(p.join(dir.path, '${cacheKey.hashCode.toUnsigned(32)}'));
    await sub.create(recursive: true);
    final out = File(p.join(sub.path, VaultCrypto.plainName(p.basename(file.path))));
    await VaultCrypto.decryptFile(file, out, key);
    _viewCache[cacheKey] = out;
    return out;
  }

  /// Deelt bestanden; bestanden uit een kluis worden tijdelijk ontsleuteld.
  static Future<ShareResult> share(List<File> files, VaultManager vaults,
      {void Function(int done, int total)? onProgress}) async {
    Directory? shareDir;
    final out = <XFile>[];
    for (var i = 0; i < files.length; i++) {
      onProgress?.call(i, files.length);
      final f = files[i];
      final name = p.basename(f.path);
      if (VaultCrypto.isEncryptedName(name) &&
          vaults.vaultRootFor(f.parent.path) != null) {
        final key = vaults.keyForDir(f.parent.path);
        if (key == null) throw StateError('Kluis is vergrendeld');
        shareDir ??= await Directory(p.join((await _dir('gedeeld')).path,
                '${DateTime.now().millisecondsSinceEpoch}'))
            .create(recursive: true);
        final target =
            VaultManager.uniqueFile(shareDir.path, VaultCrypto.plainName(name));
        await VaultCrypto.decryptFile(f, target, key);
        out.add(XFile(target.path));
      } else {
        out.add(XFile(f.path));
      }
    }
    onProgress?.call(files.length, files.length);
    final result = await SharePlus.instance.share(ShareParams(files: out));
    final dir = shareDir;
    if (dir != null) {
      late Timer t;
      t = Timer(shareDelay, () {
        _timers.remove(t);
        dir.delete(recursive: true).catchError((_) => dir);
      });
      _timers.add(t);
    }
    return result;
  }

  /// Verwijdert de ontsleutelde kopieën die alleen voor bekijken dienden
  /// (gedeelde kopieën lopen via hun eigen timer af).
  static Future<void> clearViewCache() async {
    _viewCache.clear();
    try {
      final d = Directory(
          p.join((await baseDir()).path, 'bestandskluis', 'bekijken'));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // Wordt bij de volgende start opnieuw geprobeerd.
    }
  }

  /// Verwijdert alle tijdelijk ontsleutelde bestanden (bij het starten).
  static Future<void> clearAll() async {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _viewCache.clear();
    try {
      final d = Directory(p.join((await baseDir()).path, 'bestandskluis'));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // Wordt bij de volgende start opnieuw geprobeerd.
    }
  }
}
