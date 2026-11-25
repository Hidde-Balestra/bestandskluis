import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../services/backup.dart';
import '../services/camera_mover.dart';
import '../services/ftp_controller.dart';
import '../services/intruders.dart';
import '../services/settings.dart';
import '../services/temp_files.dart';
import '../widgets/app_logo.dart';
import '../widgets/dialogs.dart';
import '../widgets/vault_unlock.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings get settings => services.settings;
  final _date = DateFormat('d MMM yyyy HH:mm', 'nl');

  // --- Vingerafdruk ---------------------------------------------------------

  Future<void> _toggleBiometric(bool on) async {
    final bio = services.biometric;
    if (!on) {
      await bio.removeAll();
      await settings.setBiometric(false);
      if (mounted) showMessage(context, 'Bewaarde vingerafdruksleutels zijn gewist');
      return;
    }
    if (!await bio.available()) {
      if (mounted) {
        showMessage(context,
            'Er is geen vingerafdruk ingesteld op dit toestel. Stel die eerst in bij de Android-instellingen.');
      }
      return;
    }
    await settings.setBiometric(true);
    // Kluizen die nu open zijn meteen aanmelden (vraagt om de vingerafdruk).
    for (final root in services.vaults.unlockedVaults.toList()) {
      await rememberForBiometric(root);
    }
    if (mounted) {
      showMessage(context,
          'Ingeschakeld. Een kluis werkt met je vingerafdruk nadat je hem één keer met het wachtwoord hebt ontgrendeld.');
    }
  }

  Future<void> _toggleVault(String root, bool on) async {
    if (!on) {
      await forgetBiometric(root);
      return;
    }
    if (services.vaults.isUnlocked(root)) {
      await rememberForBiometric(root);
    } else {
      // Ontgrendelen met wachtwoord bewaart de sleutel automatisch.
      await unlockVault(context, root);
    }
  }

  // --- Overig ---------------------------------------------------------------

  Future<void> _chooseAutoLock() async {
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Automatisch vergrendelen'),
        children: [
          RadioGroup<int>(
            groupValue: settings.autoLockMinutes,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(children: [
              for (final m in AppSettings.autoLockChoices)
                RadioListTile<int>(value: m, title: Text(_autoLockLabel(m))),
            ]),
          ),
        ],
      ),
    );
    if (v != null) await settings.setAutoLockMinutes(v);
  }

  static String _autoLockLabel(int m) => switch (m) {
        0 => 'Nooit',
        1 => 'Na 1 minuut op de achtergrond',
        _ => 'Na $m minuten op de achtergrond',
      };

  /// Kies een kluis (of null = uit). Geeft '' bij annuleren.
  Future<String?> _pickVault(String title, {String? current, bool allowOff = true}) {
    final vaults = services.known.paths;
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          if (vaults.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Je hebt nog geen kluizen.'),
            ),
          for (final v in vaults)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, v),
              child: Text(p.basename(v),
                  style: TextStyle(
                      fontWeight: v == current ? FontWeight.bold : null)),
            ),
          if (allowOff)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '\u0000'),
              child: const Text('Uit'),
            ),
        ],
      ),
    );
  }

  Future<void> _chooseCameraVault() async {
    final v = await _pickVault('Nieuwe camerafoto\'s naar…',
        current: settings.cameraVault);
    if (v == null) return;
    if (v == '\u0000') {
      await settings.setCameraVault(null);
      return;
    }
    await settings.setCameraVault(v);
    if (!mounted) return;
    showMessage(context,
        'Foto\'s en video\'s die je vanaf nu maakt gaan naar "${p.basename(v)}" '
        'zodra je de app opent en de kluis ontgrendeld is.');
    if (!services.vaults.isUnlocked(v)) await unlockVault(context, v);
    await CameraMover.run();
  }

  Future<void> _toggleIntruder(bool on) async {
    if (on && !await Intruders.requestCamera()) {
      if (mounted) showMessage(context, 'Camera-toestemming is nodig');
      return;
    }
    await settings.setIntruderPhoto(on);
  }

  Future<void> _openIntruders() async {
    // Alleen de eigenaar mag de foto's zien: ontgrendel met vingerafdruk of
    // de schermvergrendeling van de telefoon.
    if (!await services.biometric.authenticate(
        'Bevestig dat jij het bent om de mislukte pogingen te bekijken',
        biometricOnly: false)) {
      return;
    }
    if (!mounted) return;
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => const _IntrudersScreen()));
    await services.intruders.markSeen();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Instellingen')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          settings,
          services.biometric,
          services.known,
          services.vaults,
          services.intruders,
          services.backup,
        ]),
        builder: (context, _) {
          final vaults = services.known.paths;
          final camera = settings.cameraVault;
          return ListView(children: [
            const ListTile(dense: true, title: Text('Kluizen')),
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('Ontgrendelen met vingerafdruk'),
              subtitle: const Text(
                  'De kluissleutel wordt opgeslagen in een sleutel van de telefoon '
                  'die alleen na een vingerafdrukscan wordt vrijgegeven. Voeg je een '
                  'vingerafdruk toe, dan is één keer het wachtwoord nodig.'),
              value: settings.biometric,
              onChanged: _toggleBiometric,
            ),
            if (settings.biometric)
              for (final root in vaults)
                CheckboxListTile(
                  contentPadding: const EdgeInsets.only(left: 72, right: 16),
                  title: Text(p.basename(root)),
                  subtitle: Text(
                      biometricModeLabel(services.biometric.modeOf(root))),
                  value: services.biometric.isEnrolled(root),
                  onChanged: (v) => _toggleVault(root, v ?? false),
                ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Automatisch vergrendelen'),
              subtitle: Text(_autoLockLabel(settings.autoLockMinutes) +
                  (settings.autoLockMinutes == 0
                      ? ''
                      : ' (niet zolang de FTP-server draait)')),
              onTap: _chooseAutoLock,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.screenshot_monitor_outlined),
              title: const Text('Schermbeveiliging'),
              subtitle: const Text(
                  'Zolang een kluis open is: geen schermafbeeldingen en de inhoud '
                  'is verborgen in het overzicht van recente apps'),
              value: settings.secureScreen,
              onChanged: settings.setSecureScreen,
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Nieuwe camerafoto\'s naar kluis'),
              subtitle: Text(camera == null
                  ? 'Uit'
                  : '"${p.basename(camera)}" — als de app open is en de kluis ontgrendeld'),
              onTap: _chooseCameraVault,
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Alle kluizen nu vergrendelen'),
              enabled: services.vaults.unlockedVaults.isNotEmpty,
              onTap: () {
                services.vaults.lockAll();
                TempFiles.clearViewCache();
                showMessage(context, 'Alle kluizen zijn vergrendeld');
              },
            ),
            const Divider(),
            const ListTile(dense: true, title: Text('Indringers')),
            SwitchListTile(
              secondary: const Icon(Icons.no_photography_outlined),
              title: const Text('Indringersfoto'),
              subtitle: const Text(
                  'Na 3 verkeerde wachtwoorden wordt ongemerkt een foto met de '
                  'voorcamera gemaakt en versleuteld bewaard'),
              value: settings.intruderPhoto,
              onChanged: _toggleIntruder,
            ),
            ListTile(
              leading: const Icon(Icons.report_outlined),
              title: const Text('Mislukte pogingen'),
              subtitle: Text(services.intruders.events.isEmpty
                  ? 'Geen'
                  : '${services.intruders.events.length} — laatste '
                      '${_date.format(services.intruders.events.first.time)}'),
              enabled: services.intruders.events.isNotEmpty,
              onTap: _openIntruders,
            ),
            const Divider(),
            const _BackupSection(),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                const AppLogo(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Bestandskluis — bestanden worden versleuteld met AES-256-GCM.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

// --- Back-up ----------------------------------------------------------------

class _BackupSection extends StatefulWidget {
  const _BackupSection();
  @override
  State<_BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<_BackupSection> {
  BackupService get b => services.backup;
  final _date = DateFormat('d MMM HH:mm', 'nl');

  Future<void> _chooseServer() async {
    final saved = services.ftp.saved.where((s) => s.user.isNotEmpty).toList();
    final s = await showDialog<SavedConnection>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Back-upserver'),
        children: [
          if (saved.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Verbind eerst één keer met je server via FTP → '
                  'Verbinden, met "Wachtwoord onthouden" aan.'),
            ),
          for (final c in saved)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c),
              child: Text('${c.tls ? 'FTPS' : 'FTP'} · ${c.user}@${c.host}:${c.port}'),
            ),
        ],
      ),
    );
    if (s == null) return;
    if (await FtpController.savedPassword(s) == null && mounted) {
      final pw = await askPassword(context,
          title: 'Wachtwoord voor ${s.user}@${s.host}');
      if (pw == null) return;
      await FtpController.rememberPassword(s, pw);
    }
    await b.save(connection: s);
  }

  Future<void> _chooseVaults() async {
    final all = services.known.paths;
    final chosen = {...b.vaults};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Kluizen om te back-uppen'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (all.isEmpty) const Text('Je hebt nog geen kluizen.'),
            for (final v in all)
              CheckboxListTile(
                title: Text(p.basename(v)),
                value: chosen.contains(v),
                onChanged: (on) => setState(
                    () => on == true ? chosen.add(v) : chosen.remove(v)),
              ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annuleren')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Opslaan')),
          ],
        ),
      ),
    );
    if (ok == true) await b.save(vaults: chosen.toList());
  }

  Future<void> _runNow() async {
    final r = await runWithProgress(context, 'Back-up maken…', (update) async {
      final r = await BackupService.runConfigured(onFile: update);
      await b.load();
      return r;
    });
    if (r != null && mounted) showMessage(context, r.summary);
  }

  @override
  Widget build(BuildContext context) {
    final c = b.connection;
    final ready = c != null && b.vaults.isNotEmpty;
    return Column(children: [
      const ListTile(dense: true, title: Text('Back-up naar FTP-server')),
      ListTile(
        leading: const Icon(Icons.dns_outlined),
        title: const Text('Server'),
        subtitle: Text(c == null
            ? 'Niet ingesteld'
            : '${c.tls ? 'FTPS' : 'FTP (onversleutelde verbinding)'} · ${c.user}@${c.host}:${c.port}'),
        onTap: _chooseServer,
      ),
      ListTile(
        leading: const Icon(Icons.folder_outlined),
        title: const Text('Map op de server'),
        subtitle: Text(b.remoteDir),
        onTap: () async {
          final v = await askText(context,
              title: 'Map op de server', initial: b.remoteDir, label: 'Pad');
          if (v != null && v.isNotEmpty) await b.save(remoteDir: v);
        },
      ),
      ListTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: const Text('Kluizen'),
        subtitle: Text(b.vaults.isEmpty
            ? 'Geen gekozen'
            : b.vaults.map(p.basename).join(', ')),
        onTap: _chooseVaults,
      ),
      SwitchListTile(
        secondary: const Icon(Icons.schedule),
        title: const Text('Elke nacht automatisch'),
        subtitle: const Text('Op wifi en met voldoende batterij, ook als de app dicht is'),
        value: b.enabled,
        onChanged: ready ? (v) => b.save(enabled: v) : null,
      ),
      ListTile(
        leading: const Icon(Icons.backup_outlined),
        title: const Text('Nu back-uppen'),
        subtitle: Text(b.lastRun == null
            ? 'Alleen versleutelde bestanden worden verstuurd; de kluis hoeft niet open te zijn'
            : 'Laatste: ${_date.format(b.lastRun!)} — ${b.lastResult ?? ''}'),
        enabled: ready,
        onTap: _runNow,
      ),
    ]);
  }
}

// --- Indringers -------------------------------------------------------------

class _IntrudersScreen extends StatelessWidget {
  const _IntrudersScreen();

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('EEEE d MMMM yyyy, HH:mm:ss', 'nl');
    return Scaffold(
      appBar: AppBar(title: const Text('Mislukte pogingen'), actions: [
        IconButton(
          tooltip: 'Alles wissen',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final ok = await confirmDialog(context,
                title: 'Alles wissen',
                message: 'Alle mislukte pogingen en foto\'s verwijderen?',
                confirm: 'Wissen',
                destructive: true);
            if (ok) await services.intruders.clear();
            if (ok && context.mounted) Navigator.pop(context);
          },
        ),
      ]),
      body: ListenableBuilder(
        listenable: services.intruders,
        builder: (context, _) => ListView(children: [
          for (final e in services.intruders.events)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ListTile(
                  leading: const Icon(Icons.warning_amber),
                  title: Text('Kluis "${e.vault}"'),
                  subtitle: Text(date.format(e.time)),
                ),
                if (e.photo != null)
                  FutureBuilder(
                    future: services.intruders.photoBytes(e),
                    builder: (context, snap) => snap.data == null
                        ? const SizedBox(
                            height: 80,
                            child: Center(child: CircularProgressIndicator()))
                        : Image.memory(snap.data!, fit: BoxFit.cover),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }
}
