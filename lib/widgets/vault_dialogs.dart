import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import 'dialogs.dart';
import 'vault_unlock.dart';

/// Vraagt of ook de bestandsnamen versleuteld moeten worden. Null =
/// geannuleerd.
Future<bool?> askEncryptNames(BuildContext context) {
  var names = true;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Kluisinstellingen'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ook bestandsnamen versleutelen'),
            subtitle: const Text(
                'Zonder wachtwoord is dan ook niet te zien hoe bestanden heten. '
                'Mapnamen blijven leesbaar. Namen mogen maximaal ongeveer 150 tekens zijn.'),
            value: names,
            onChanged: (v) => setState(() => names = v),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuleren')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, names),
              child: const Text('Volgende')),
        ],
      ),
    ),
  );
}

/// Maakt een nieuwe herstelcode en toont die.
Future<void> createAndShowRecoveryCode(
    BuildContext context, String root) async {
  final code = await runWithProgress(context, 'Herstelcode maken…',
      (_) => services.vaults.createRecoveryCode(root));
  if (code == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.key),
      title: const Text('Herstelcode'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Schrijf deze code op en bewaar hem op een veilige plek, '
            'niet op deze telefoon. Ben je je wachtwoord kwijt, dan kun je de '
            'kluis hiermee openen en een nieuw wachtwoord instellen. '
            'Een eerdere herstelcode werkt nu niet meer.'),
        const SizedBox(height: 16),
        SelectableText(code,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 1)),
      ]),
      actions: [
        TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              showMessage(ctx, 'Gekopieerd — wis hem daarna uit je klembord');
            },
            child: const Text('Kopiëren')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Ik heb hem bewaard')),
      ],
    ),
  );
}

/// Wachtwoord van een (ontgrendelde) kluis wijzigen.
Future<bool> changeVaultPassword(BuildContext context, String root,
    {String title = 'Nieuw wachtwoord'}) async {
  final pw = await askPassword(context, title: title, repeat: true);
  if (pw == null || !context.mounted) return false;
  final ok = await runWithProgress(context, 'Wachtwoord wijzigen…', (_) async {
    await services.vaults.changePassword(root, pw);
    return true;
  });
  if (ok == true && context.mounted) {
    showMessage(context, 'Wachtwoord is gewijzigd');
  }
  return ok == true;
}

/// Kluis openen met de herstelcode en daarna een nieuw wachtwoord instellen.
Future<bool> recoverVault(BuildContext context, String root) async {
  final code = await askText(context,
      title: 'Herstelcode invoeren', label: 'XXXX-XXXX-…', confirm: 'Openen');
  if (code == null || code.isEmpty || !context.mounted) return false;
  final ok = await runWithProgress(context, 'Controleren…',
      (_) => services.vaults.unlockWithRecoveryCode(root, code));
  if (!context.mounted) return false;
  if (ok != true) {
    if (ok == false) await registerFailedAttempt(context, root);
    if (context.mounted) showMessage(context, 'Onjuiste herstelcode');
    return false;
  }
  await services.known.add(root);
  if (!context.mounted) return true;
  await changeVaultPassword(context, root, title: 'Stel een nieuw wachtwoord in');
  return true;
}
