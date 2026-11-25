import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../ftp/ftp_client.dart';
import '../ftp/ftp_server.dart';
import 'package:qr_flutter/qr_flutter.dart';
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

  Future<void> _chooseTls() async {
    final v = await showDialog<FtpTls>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Versleuteling (FTPS)'),
        children: [
          RadioGroup<FtpTls>(
            groupValue: ftp.config.tls,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: const Column(children: [
              RadioListTile(value: FtpTls.off, title: Text('Uit')),
              RadioListTile(
                  value: FtpTls.optional,
                  title: Text('Als de client erom vraagt')),
              RadioListTile(value: FtpTls.required, title: Text('Verplicht')),
            ]),
          ),
        ],
      ),
    );
    if (v != null) await ftp.save(ftp.config.copyWith(tls: v));
  }

  Future<void> _showQr(String address) async {
    var withPassword = true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final link = ftp.link(address, withPassword: withPassword);
          return AlertDialog(
            title: const Text('Verbinden via QR-code'),
            content: SizedBox(
              width: 280,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(data: link, size: 240),
                ),
                const SizedBox(height: 8),
                Text(
                    'Scan met de camera van een andere telefoon. Met Bestandskluis '
                    'daarop wordt meteen verbonden${ftp.identity != null && ftp.config.tls != FtpTls.off ? ' en het certificaat gecontroleerd' : ''}.',
                    style: const TextStyle(fontSize: 12)),
                if (!ftp.config.allowAnonymous)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Wachtwoord in de code'),
                    subtitle: const Text(
                        'Iedereen die de code ziet kan dan inloggen',
                        style: TextStyle(fontSize: 12)),
                    value: withPassword,
                    onChanged: (v) => setState(() => withPassword = v),
                  ),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Sluiten')),
            ],
          );
        },
      ),
    );
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
                      _CopyRow(text: ftp.link(a), onQr: () => _showQr(a)),
                    const SizedBox(height: 4),
                    Text(c.allowAnonymous
                        ? 'Anoniem inloggen toegestaan'
                        : 'Gebruiker: ${c.username}'),
                    if (ftp.identity != null && c.tls != FtpTls.off)
                      Text(
                          c.tls == FtpTls.required
                              ? 'Alleen versleuteld (FTPS)'
                              : 'Versleuteld (FTPS) als de client dat ondersteunt',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (c.decryptVaults)
                      const Text(
                          'Ontgrendelde kluizen worden tijdens de overdracht ontsleuteld.'),
                    if (ftp.background)
                      const Text(
                          'Blijft draaien op de achtergrond en met het scherm uit.'),
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
          ListTile(
            leading: const Icon(Icons.https_outlined),
            title: const Text('Versleuteling (FTPS)'),
            subtitle: Text(switch (c.tls) {
              FtpTls.off => 'Uit — alles gaat onversleuteld over het netwerk',
              FtpTls.optional =>
                'Als de client erom vraagt (aanbevolen; werkt met FileZilla, WinSCP, …)',
              FtpTls.required => 'Verplicht — clients zonder FTPS kunnen niet verbinden',
            }),
            onTap: _chooseTls,
          ),
          if (ftp.identity != null && c.tls != FtpTls.off)
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text('Certificaat (SHA-256)'),
              subtitle: SelectableText(ftp.identity!.fingerprint,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('Op de achtergrond doorlopen'),
            subtitle: const Text(
                'De server blijft actief met het scherm uit of in een andere app '
                '(met een melding). Veeg je de app weg, dan stopt hij.'),
            value: ftp.background,
            onChanged: (v) => ftp.save(c, inBackground: v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.light_mode_outlined),
            title: const Text('Scherm aan houden'),
            subtitle: const Text('Alleen nodig als de server op de achtergrond '
                'toch wordt onderbroken'),
            value: ftp.keepScreenOn,
            onChanged: (v) => ftp.save(c, wakelock: v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
                c.tls == FtpTls.required
                    ? 'Alle verbindingen zijn versleuteld.'
                    : 'Let op: zonder FTPS gaat alles (ook het wachtwoord) '
                        'onversleuteld over het netwerk. Gebruik dan alleen een '
                        'vertrouwd (thuis)netwerk.',
                style: const TextStyle(fontSize: 12)),
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
  const _CopyRow({required this.text, this.onQr});
  final String text;
  final VoidCallback? onQr;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
            child: SelectableText(text.split('?').first,
                style: Theme.of(context).textTheme.titleMedium)),
        if (onQr != null)
          IconButton(
            tooltip: 'QR-code',
            icon: const Icon(Icons.qr_code_2),
            onPressed: onQr,
          ),
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

/// Verbindt (met voortgang en foutafhandeling) en opent de externe browser.
Future<void> connectAndBrowse(BuildContext context, SavedConnection conn,
    String password, {bool remember = false}) async {
  FtpClient? client;
  try {
    client = await runWithProgress(
        context,
        conn.tls ? 'Versleuteld verbinden…' : 'Verbinden…',
        (_) => services.ftp.connect(conn, password, remember: remember));
  } catch (_) {
    client = null;
  }
  if (client == null) return;
  if (!context.mounted) {
    await client.quit();
    return;
  }
  await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => FtpRemoteScreen(
              client: client!,
              title: '${conn.tls ? 'FTPS · ' : ''}${conn.host}:${conn.port}')));
  await client.quit();
}

/// Opent een ftp://- of ftps://-link (bijv. gescand van een QR-code).
Future<void> openFtpLink(BuildContext context, String url) async {
  final parsed = SavedConnection.fromUrl(url);
  if (parsed == null) {
    showMessage(context, 'Ongeldige FTP-link');
    return;
  }
  var (conn, password) = parsed;
  if (password == null && conn.user.isNotEmpty) {
    password = await askPassword(context,
        title: 'Wachtwoord voor ${conn.user}', message: '${conn.host}:${conn.port}');
    if (password == null || !context.mounted) return;
  }
  await connectAndBrowse(context, conn, password ?? '');
}

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
  bool _tls = false;
  bool _remember = false;
  SavedConnection? _selected;

  Future<void> _fill(SavedConnection s) async {
    _host.text = s.host;
    _port.text = '${s.port}';
    _user.text = s.user;
    _pass.text = await FtpController.savedPassword(s) ?? '';
    setState(() {
      _selected = s;
      _anonymous = s.user.isEmpty || s.user == 'anonymous';
      _tls = s.tls;
      _remember = _pass.text.isNotEmpty;
    });
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 21;
    if (host.isEmpty) {
      showMessage(context, 'Vul een server in');
      return;
    }
    final user = _anonymous ? '' : _user.text.trim();
    final prev = _selected;
    // Vastgepind certificaat behouden als het dezelfde server is.
    final conn = SavedConnection(
        host: host,
        port: port,
        user: user,
        tls: _tls,
        fingerprint: prev != null &&
                prev.host == host &&
                prev.port == port &&
                prev.tls == _tls
            ? prev.fingerprint
            : null);
    if (!_remember) await FtpController.forgetPassword(conn);
    if (!mounted) return;
    // Fouten (ook een gewijzigd certificaat) toont runWithProgress.
    await connectAndBrowse(context, conn, _pass.text, remember: _remember);
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
            title: const Text('Versleuteld (FTPS)'),
            subtitle: const Text(
                'Expliciete TLS. Het certificaat wordt bij de eerste verbinding '
                'onthouden en daarna gecontroleerd.'),
            value: _tls,
            onChanged: (v) => setState(() => _tls = v),
          ),
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
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Wachtwoord onthouden'),
              subtitle: const Text('Versleuteld bewaard; nodig voor automatische back-ups'),
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? false),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _connect,
            icon: Icon(_tls ? Icons.lock : Icons.login),
            label: const Text('Verbinden'),
          ),
          if (services.ftp.saved.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Recent', style: Theme.of(context).textTheme.titleSmall),
            for (final s in services.ftp.saved)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(s.tls ? Icons.lock : Icons.history),
                title: Text('${s.host}:${s.port}'),
                subtitle: Text([
                  s.user.isEmpty ? 'anoniem' : s.user,
                  if (s.tls && s.fingerprint != null) 'certificaat onthouden',
                ].join(' · ')),
                onTap: () => _fill(s),
                trailing: PopupMenuButton<String>(
                  onSelected: (a) async {
                    if (a == 'remove') await services.ftp.removeConnection(s);
                    if (a == 'cert') {
                      await services.ftp.resetFingerprint(s);
                      if (context.mounted) {
                        showMessage(context,
                            'Bij de volgende verbinding wordt het nieuwe certificaat onthouden');
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    if (s.tls && s.fingerprint != null)
                      const PopupMenuItem(
                          value: 'cert', child: Text('Certificaat vergeten')),
                    const PopupMenuItem(value: 'remove', child: Text('Verwijderen')),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
