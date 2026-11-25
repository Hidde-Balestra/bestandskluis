import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
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
    if (!await bio.authenticate('Bevestig om ontgrendelen met vingerafdruk in te schakelen')) {
      return;
    }
    await settings.setBiometric(true);
    // Kluizen die nu open zijn meteen aanmelden.
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Instellingen')),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [settings, services.biometric, services.known, services.vaults]),
        builder: (context, _) {
          final vaults = services.known.paths;
          return ListView(children: [
            const ListTile(dense: true, title: Text('Kluizen')),
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('Ontgrendelen met vingerafdruk'),
              subtitle: const Text(
                  'Na één keer ontgrendelen met het wachtwoord kun je de kluis voortaan met je vingerafdruk openen'),
              value: settings.biometric,
              onChanged: _toggleBiometric,
            ),
            if (settings.biometric)
              for (final root in vaults)
                CheckboxListTile(
                  contentPadding: const EdgeInsets.only(left: 72, right: 16),
                  title: Text(p.basename(root)),
                  subtitle: Text(root, overflow: TextOverflow.ellipsis),
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
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                const AppLogo(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Bestandskluis — bestanden worden versleuteld met AES-256-GCM. '
                    'Vingerafdruksleutels staan in de door de Android Keystore '
                    'beschermde opslag van de app.',
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
