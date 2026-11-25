import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import 'dialogs.dart';

/// Ontgrendelt de kluis [root]: eerst met de vingerafdruk (als dat is
/// ingeschakeld en er een sleutel bewaard is), anders met het wachtwoord.
Future<bool> unlockVault(BuildContext context, String root) async {
  final bio = services.biometric;
  final name = p.basename(root);

  if (services.settings.biometric && bio.isEnrolled(root)) {
    if (await bio.authenticate('Ontgrendel kluis "$name"')) {
      final key = await bio.readKey(root);
      if (key != null && await services.vaults.unlockWithKey(root, key)) {
        await services.known.add(root);
        return true;
      }
      // Kluis is opnieuw aangemaakt of de sleutel is weg: wachtwoord nodig.
      await bio.removeKey(root);
      if (context.mounted) {
        showMessage(context,
            'Vingerafdruk werkt niet meer voor deze kluis; voer het wachtwoord in');
      }
    }
    if (!context.mounted) return false;
  }

  final pw = await askPassword(context,
      title: 'Kluis ontgrendelen', message: name);
  if (pw == null || !context.mounted) return false;
  final ok = await runWithProgress(
      context, 'Ontgrendelen…', (_) => services.vaults.unlock(root, pw));
  if (ok != true) {
    if (ok == false && context.mounted) {
      showMessage(context, 'Onjuist wachtwoord');
    }
    return false;
  }
  await services.known.add(root);
  await rememberForBiometric(root);
  return true;
}

/// Bewaart de sleutel van een ontgrendelde kluis voor de vingerafdruk, als
/// die optie aan staat.
Future<void> rememberForBiometric(String root) async {
  if (!services.settings.biometric) return;
  final key = services.vaults.keyFor(root);
  if (key == null || services.biometric.isEnrolled(root)) return;
  try {
    await services.biometric.saveKey(root, key);
  } catch (_) {
    // Opslag niet beschikbaar: dan blijft alleen het wachtwoord werken.
  }
}

/// Bewaarde vingerafdruksleutel van [root] vergeten (kluis opgeheven,
/// hernoemd of verwijderd).
Future<void> forgetBiometric(String root) => services.biometric.removeKey(root);
