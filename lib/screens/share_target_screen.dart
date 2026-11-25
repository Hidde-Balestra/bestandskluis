import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../crypto/vault_manager.dart';
import '../services/storage.dart';
import '../util/format.dart';
import '../widgets/app_logo.dart';
import '../widgets/dialogs.dart';
import '../widgets/vault_unlock.dart';

/// Bestanden die vanuit een andere app naar Bestandskluis zijn gedeeld:
/// kies een kluis om ze versleuteld in op te slaan.
class ShareTargetScreen extends StatefulWidget {
  const ShareTargetScreen({super.key, required this.paths});

  /// Tijdelijke kopieën in de cache.
  final List<String> paths;

  @override
  State<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends State<ShareTargetScreen> {
  bool _done = false;

  List<File> get _files =>
      widget.paths.map(File.new).where((f) => f.existsSync()).toList();

  @override
  void dispose() {
    // Tijdelijke kopieën altijd opruimen.
    for (final f in widget.paths) {
      File(f).delete().catchError((_) => File(f));
    }
    super.dispose();
  }

  Future<void> _saveToVault(String root) async {
    if (!services.vaults.isUnlocked(root) && !await unlockVault(context, root)) {
      return;
    }
    final key = services.vaults.keyFor(root);
    if (key == null || !mounted) return;
    final files = _files;
    final ok = await runWithProgress(context, 'Versleutelen…', (update) async {
      for (var i = 0; i < files.length; i++) {
        update('${i + 1} / ${files.length}\n${p.basename(files[i].path)}');
        await VaultManager.encryptInto(files[i], root, key, deleteSource: true);
      }
      return true;
    });
    if (ok == true && mounted) {
      _done = true;
      Navigator.pop(context,
          '${files.length} bestand(en) versleuteld opgeslagen in "${p.basename(root)}"');
    }
  }

  Future<void> _saveToDownloads() async {
    final dir = Directory(p.join(await Storage.downloadDir(), 'Bestandskluis'));
    await dir.create(recursive: true);
    for (final f in _files) {
      final target = VaultManager.uniqueFile(dir.path, p.basename(f.path));
      await f.copy(target.path);
    }
    if (mounted) {
      _done = true;
      Navigator.pop(context, 'Opgeslagen in ${dir.path} (niet versleuteld)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    final vaults = [
      ...services.known.paths,
      ...services.vaults.unlockedVaults
          .where((v) => !services.known.paths.any((k) => p.equals(k, v))),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Opslaan in kluis')),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const AppLogo(size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                  files.length == 1
                      ? p.basename(files.first.path)
                      : '${files.length} bestanden',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ]),
        ),
        for (final f in files.take(5))
          ListTile(
            dense: true,
            leading: Icon(iconFor(kindOf(f.path))),
            title: Text(p.basename(f.path), overflow: TextOverflow.ellipsis),
            trailing: Text(formatSize(f.lengthSync())),
          ),
        if (files.length > 5)
          ListTile(dense: true, title: Text('en nog ${files.length - 5}…')),
        const Divider(),
        const ListTile(dense: true, title: Text('Kies een kluis')),
        if (vaults.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Je hebt nog geen kluizen. Maak er eerst een in de app.'),
          ),
        for (final v in vaults)
          ListTile(
            leading: Icon(
                services.vaults.isUnlocked(v) ? Icons.lock_open : Icons.lock,
                color: Theme.of(context).colorScheme.tertiary),
            title: Text(p.basename(v)),
            subtitle: Text(v, overflow: TextOverflow.ellipsis),
            onTap: _done ? null : () => _saveToVault(v),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.download),
          title: const Text('Onversleuteld in Downloads opslaan'),
          onTap: _done ? null : _saveToDownloads,
        ),
      ]),
    );
  }
}
