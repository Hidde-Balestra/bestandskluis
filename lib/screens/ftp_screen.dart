import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../ftp/ftp_client.dart';
import '../services/ftp_controller.dart';
import '../services/storage.dart';
import '../widgets/dialogs.dart';
import 'ftp_remote_screen.dart';

class FtpScreen extends StatelessWidget {
  const FtpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('FTP'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.dns), text: 'Eigen server'),
            Tab(icon: Icon(Icons.cloud_outlined), text: 'Verbinden'),
          ]),
        ),
        body: const TabBarView(children: [_ServerTab(), _ClientTab()]),
      ),
    );
  }
}

// --- Server -----------------------------------------------------------------

class _ServerTab extends StatefulWidget {
  const _ServerTab();
  @override
  State<_ServerTab> createState() => _ServerTabState();
}

class _ServerTabState extends State<_ServerTab> {
  FtpController get ftp => services.ftp;
  List<String> _addresses = [];
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _refreshAddresses();
  }

  Future<void> _refreshAddresses() async {
    final a = await FtpController.localAddresses();
    if (mounted) setState(() => _addresses = a);
  }

  Future<void> _toggle() async {
    if (ftp.isRunning) {
      await ftp.stop();
    } else {
      if (!await Storage.ensurePermission()) {
        if (mounted) showMessage(context, 'Geen toegang tot de opslag');
        return;
      }
      await _refreshAddresses();
      await ftp.start();
    }
  }

  Future<void> _editText(String title, String value, String label,
      void Function(String) apply) async {
    final v = await askText(context, title: title, initial: value, label: label);
    if (v != null && v.isNotEmpty) apply(v);
  }

  Future<void> _pickRoot() async {
    final roots = await Storage.roots();
    if (!mounted) return;
    final current = ftp.config.rootPath;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Gedeelde map'),
        children: [
          for (final root in roots)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, root.path),
                child: Text('${root.name}\n${root.path}')),
          for (final sub in ['DCIM', 'Download', 'Pictures', 'Documents'])
            SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(ctx, p.join(roots.first.path, sub)),
                child: Text(sub)),
          SimpleDialogOption(
            onPressed: () async {
              final v = await askText(ctx,
                  title: 'Pad', initial: current, label: 'Volledig pad');
              if (ctx.mounted) Navigator.pop(ctx, v);
            },
            child: const Text('Ander pad…'),
          ),
        ],
      ),
    );
    if (r != null && r.isNotEmpty) {
      await ftp.save(ftp.config.copyWith(rootPath: r));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ftp,
      builder: (context, _) {
        final c = ftp.config;
        final running = ftp.isRunning;
        final scheme = Theme.of(context).colorScheme;
        final time = DateFormat('HH:mm:ss');
        return ListView(children: [
          Card(
            margin: const EdgeInsets.all(12),
            color: running ? scheme.primaryContainer : null,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(running ? Icons.wifi_tethering : Icons.portable_wifi_off,
                        size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                          running
                              ? 'Server actief · ${ftp.clientCount} verbonden'
                              : 'Server gestopt',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    FilledButton.icon(
                      onPressed: _toggle,
                      icon: Icon(running ? Icons.stop : Icons.play_arrow),
                      label: Text(running ? 'Stoppen' : 'Starten'),
                    ),
                  ]),
                  if (ftp.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child:
                          Text(ftp.error!, style: TextStyle(color: scheme.error)),
                    ),
                  if (running) ...[
                    const SizedBox(height: 12),
                    if (_addresses.isEmpty)
                      const Text('Geen netwerkadres gevonden. Verbind met wifi.'),
                    for (final a in _addresses)
                      _CopyRow(text: 'ftp://$a:${c.port}'),
                    const SizedBox(height: 4),
                    Text(c.allowAnonymous
                        ? 'Anoniem inloggen toegestaan'
                        : 'Gebruiker: ${c.username}'),
                    if (c.decryptVaults)
                      const Text(
                          'Ontgrendelde kluizen worden tijdens de overdracht ontsleuteld.'),
                  ],
                ],
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_shared),
            title: const Text('Gedeelde map'),
            subtitle: Text(c.rootPath),
            onTap: _pickRoot,
          ),
          ListTile(
            leading: const Icon(Icons.numbers),
            title: const Text('Poort'),
            subtitle: Text('${c.port}'),
            onTap: () => _editText('Poort', '${c.port}', 'Poort (1024–65535)',
                (v) {
              final port = int.tryParse(v);
              if (port == null || port < 1024 || port > 65535) {
                showMessage(context, 'Kies een poort tussen 1024 en 65535');
                return;
              }
              ftp.save(c.copyWith(port: port));
            }),
          ),
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Gebruikersnaam'),
            subtitle: Text(c.username),
            onTap: () => _editText('Gebruikersnaam', c.username, 'Gebruikersnaam',
                (v) => ftp.save(c.copyWith(username: v))),
          ),
          ListTile(
            leading: const Icon(Icons.key),
            title: const Text('Wachtwoord'),
            subtitle: Text(_showPassword ? c.password : '••••••••••'),
            onTap: () => _editText('Wachtwoord', c.password, 'Wachtwoord',
                (v) => ftp.save(c.copyWith(password: v))),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Tonen',
                icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
              IconButton(
                tooltip: 'Nieuw wachtwoord',
                icon: const Icon(Icons.casino_outlined),
                onPressed: () => ftp.save(
                    c.copyWith(password: FtpController.randomPassword())),
              ),
            ]),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.enhanced_encryption),
            title: const Text('Kluizen ontsleuteld delen'),
            subtitle: const Text(
                'Bestanden in ontgrendelde kluizen worden tijdens het downloaden '
                'ontsleuteld en uploads worden versleuteld. Vergrendelde kluizen '
                'blijven versleuteld.'),
            value: c.decryptVaults,
            onChanged: (v) => ftp.save(c.copyWith(decryptVaults: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_outlined),
            title: const Text('Alleen-lezen'),
            value: c.readOnly,
            onChanged: (v) => ftp.save(c.copyWith(readOnly: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.public),
            title: const Text('Anoniem inloggen'),
            subtitle: const Text('Iedereen op het netwerk kan zonder wachtwoord verbinden'),
            value: c.allowAnonymous,
            onChanged: (v) => ftp.save(c.copyWith(allowAnonymous: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.light_mode_outlined),
            title: const Text('Scherm aan houden'),
            subtitle: const Text('Voorkomt dat Android de server onderbreekt'),
            value: ftp.keepScreenOn,
            onChanged: (v) => ftp.save(c, wakelock: v),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
                'Let op: FTP is niet versleuteld op het netwerk. Gebruik de '
                'server alleen op een vertrouwd (thuis)netwerk.',
                style: TextStyle(fontSize: 12)),
          ),
          if (ftp.log.isNotEmpty) ...[
            const Divider(height: 32),
            const ListTile(dense: true, title: Text('Activiteit')),
            for (final e in ftp.log.take(50))
              ListTile(
                dense: true,
                title: Text(e.message),
                subtitle: e.client == null ? null : Text(e.client!),
                trailing: Text(time.format(e.time)),
              ),
          ],
          const SizedBox(height: 24),
        ]);
      },
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
            child: SelectableText(text,
                style: Theme.of(context).textTheme.titleLarge)),
        IconButton(
          tooltip: 'Kopiëren',
          icon: const Icon(Icons.copy),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            showMessage(context, 'Gekopieerd');
          },
        ),
      ]);
}

// --- Client -----------------------------------------------------------------

class _ClientTab extends StatefulWidget {
  const _ClientTab();
  @override
  State<_ClientTab> createState() => _ClientTabState();
}

class _ClientTabState extends State<_ClientTab> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '21');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _anonymous = false;
  bool _busy = false;

  void _fill(SavedConnection s) {
    _host.text = s.host;
    _port.text = '${s.port}';
    _user.text = s.user;
    _pass.clear();
    setState(() => _anonymous = s.user.isEmpty || s.user == 'anonymous');
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 21;
    if (host.isEmpty) {
      showMessage(context, 'Vul een server in');
      return;
    }
    setState(() => _busy = true);
    try {
      final user = _anonymous ? 'anonymous' : _user.text.trim();
      final client = await FtpClient.connect(host,
          port: port, user: user, password: _anonymous ? 'gast@' : _pass.text);
      await services.ftp.saveConnection(SavedConnection(
          host: host, port: port, user: _anonymous ? '' : user));
      if (!mounted) {
        await client.quit();
        return;
      }
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  FtpRemoteScreen(client: client, title: '$host:$port')));
      await client.quit();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.ftp,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    labelText: 'Server', hintText: '192.168.1.10'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Poort'),
              ),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Anoniem'),
            value: _anonymous,
            onChanged: (v) => setState(() => _anonymous = v),
          ),
          if (!_anonymous) ...[
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Gebruikersnaam'),
            ),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Wachtwoord'),
              onSubmitted: (_) => _connect(),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _connect,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login),
            label: const Text('Verbinden'),
          ),
          if (services.ftp.saved.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Recent', style: Theme.of(context).textTheme.titleSmall),
            for (final s in services.ftp.saved)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history),
                title: Text('${s.host}:${s.port}'),
                subtitle: Text(s.user.isEmpty ? 'anoniem' : s.user),
                onTap: () => _fill(s),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => services.ftp.removeConnection(s),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
