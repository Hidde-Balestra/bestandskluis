import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';
import '../ftp/ftp_client.dart';
import '../ftp/ftp_format.dart';
import '../services/storage.dart';
import '../services/temp_files.dart';
import '../util/format.dart';
import '../widgets/dialogs.dart';
import 'browser_screen.dart';

/// Bladeren op een externe FTP-server.
class FtpRemoteScreen extends StatefulWidget {
  const FtpRemoteScreen({super.key, required this.client, required this.title});

  final FtpClient client;
  final String title;

  @override
  State<FtpRemoteScreen> createState() => _FtpRemoteScreenState();
}

class _FtpRemoteScreenState extends State<FtpRemoteScreen> {
  String _path = '/';
  List<RemoteEntry> _entries = [];
  bool _loading = true;
  String? _error;
  String? _transfer;
  double? _progress;

  FtpClient get c => widget.client;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      _path = await c.pwd();
    } catch (_) {}
    await _load();
  }

  String _join(String name) => p.posix.join(_path, name);

  Future<void> _load([String? path]) async {
    final target = path ?? _path;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await c.list(target);
      if (!mounted) return;
      setState(() {
        _path = target;
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _up() {
    if (_path == '/') return;
    _load(p.posix.dirname(_path));
  }

  Future<void> _download(RemoteEntry e) async {
    final dir = Directory(p.join(await Storage.downloadDir(), 'Bestandskluis'));
    await dir.create(recursive: true);
    final target = VaultManager.uniqueFile(dir.path, e.name);
    setState(() {
      _transfer = 'Downloaden: ${e.name}';
      _progress = e.size > 0 ? 0 : null;
    });
    try {
      await c.download(_join(e.name), target, onProgress: (n) {
        if (e.size > 0 && mounted) setState(() => _progress = n / e.size);
      });
      if (mounted) showMessage(context, 'Opgeslagen in ${target.path}');
    } catch (err) {
      if (mounted) showError(context, err);
    } finally {
      if (mounted) setState(() => _transfer = null);
    }
  }

  Future<void> _upload() async {
    final path = await Navigator.push<String>(
        context,
        MaterialPageRoute(
            builder: (_) => const BrowserScreen(pickFileMode: true)));
    if (path == null || !mounted) return;
    var file = File(path);
    // Bestand uit een kluis: tijdelijk ontsleutelen en dan uploaden.
    final encrypted = VaultCrypto.isEncryptedName(p.basename(path)) &&
        services.vaults.vaultRootFor(file.parent.path) != null;
    final name = encrypted
        ? VaultCrypto.plainName(p.basename(path))
        : p.basename(path);
    setState(() {
      _transfer = encrypted ? 'Ontsleutelen: $name' : 'Uploaden: $name';
      _progress = null;
    });
    try {
      if (encrypted) {
        file = await TempFiles.plainFor(file, services.ops.keyForFile(file));
      }
      final size = await file.length();
      if (mounted) setState(() => _transfer = 'Uploaden: $name');
      await c.upload(file, _join(name), onProgress: (n) {
        if (size > 0 && mounted) setState(() => _progress = n / size);
      });
      if (encrypted) await TempFiles.clearViewCache();
      await _load();
    } catch (err) {
      if (mounted) showError(context, err);
    } finally {
      if (mounted) setState(() => _transfer = null);
    }
  }

  Future<void> _mkdir() async {
    final name = await askText(context, title: 'Nieuwe map', initial: 'Nieuwe map');
    if (name == null || name.isEmpty) return;
    try {
      await c.mkdir(_join(name));
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _action(RemoteEntry e, String a) async {
    try {
      switch (a) {
        case 'download':
          await _download(e);
        case 'rename':
          final n = await askText(context, title: 'Hernoemen', initial: e.name);
          if (n == null || n.isEmpty || n == e.name) return;
          await c.rename(_join(e.name), _join(n));
          await _load();
        case 'delete':
          final ok = await confirmDialog(context,
              title: 'Verwijderen',
              message: '"${e.name}" op de server verwijderen?',
              confirm: 'Verwijderen',
              destructive: true);
          if (!ok) return;
          e.isDir ? await c.rmdir(_join(e.name)) : await c.delete(_join(e.name));
          await _load();
      }
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _path == '/',
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title),
            Text(_path, style: Theme.of(context).textTheme.bodySmall),
          ]),
          actions: [
            if (_path != '/')
              IconButton(
                  icon: const Icon(Icons.arrow_upward), onPressed: _up),
            IconButton(
                tooltip: 'Nieuwe map',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: _mkdir),
            IconButton(
                tooltip: 'Vernieuwen',
                icon: const Icon(Icons.refresh),
                onPressed: _load),
          ],
          bottom: _transfer == null
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(28),
                  child: Column(children: [
                    Text(_transfer!, style: Theme.of(context).textTheme.bodySmall),
                    LinearProgressIndicator(value: _progress),
                  ]),
                ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _transfer == null ? _upload : null,
          icon: const Icon(Icons.upload),
          label: const Text('Uploaden'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!, textAlign: TextAlign.center)))
                : _entries.isEmpty
                    ? const Center(child: Text('Lege map'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          itemCount: _entries.length,
                          itemBuilder: (context, i) {
                            final e = _entries[i];
                            return ListTile(
                              leading: Icon(e.isDir
                                  ? Icons.folder
                                  : iconFor(kindOf(e.name))),
                              title: Text(e.name),
                              subtitle: Text([
                                if (!e.isDir) formatSize(e.size),
                                if (e.modified != null) formatDate(e.modified!),
                              ].join(' · ')),
                              onTap: () => e.isDir
                                  ? _load(_join(e.name))
                                  : _download(e),
                              trailing: PopupMenuButton<String>(
                                onSelected: (a) => _action(e, a),
                                itemBuilder: (_) => [
                                  if (!e.isDir)
                                    const PopupMenuItem(
                                        value: 'download',
                                        child: Text('Downloaden')),
                                  const PopupMenuItem(
                                      value: 'rename', child: Text('Hernoemen')),
                                  const PopupMenuItem(
                                      value: 'delete', child: Text('Verwijderen')),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
      ),
    );
  }
}
