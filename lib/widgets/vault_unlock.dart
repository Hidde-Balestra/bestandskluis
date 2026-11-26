import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../services/biometric_unlock.dart';
import 'dialogs.dart';
import 'vault_dialogs.dart';

/// Mislukte pogingen per kluis sinds de laatste geslaagde ontgrendeling.
final Map<String, int> _failures = {};

/// Ontgrendelt de kluis [root]: eerst met de vingerafdruk (als dat is
/// ingeschakeld en er een sleutel bewaard is), anders met het wachtwoord.
Future<bool> unlockVault(BuildContext context, String root) async {
  final bio = services.biometric;
  final name = p.basename(root);
  var resaveBiometric = false;

  if (services.settings.biometric && bio.isEnrolled(root)) {
    final r = await bio.unlockKey(root, 'Ontgrendel kluis "$name"');
    final key = r.key;
    if (key != null) {
      if (await services.vaults.unlockWithKey(root, key)) {
        if (context.mounted) await _succeeded(context, root);
        return true;
      }
      resaveBiometric = true; // kluis is opnieuw aangemaakt
    } else if (r.invalid) {
      resaveBiometric = true;
      if (context.mounted) {
        showMessage(context,
            'Je vingerafdrukken zijn gewijzigd. Voer één keer het wachtwoord in.');
      }
    }
    if (!context.mounted) return false;
  }

  final pw = await askPassword(context,
      title: 'Kluis ontgrendelen', message: name);
  if (pw == null || !context.mounted) return false;
  final ok = await runWithProgress(
      context, 'Ontgrendelen…', (_) => services.vaults.unlock(root, pw));
  if (!context.mounted) return ok == true;
  if (ok != true) {
    if (ok == false) {
      await registerFailedAttempt(context, root);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Onjuist wachtwoord'),
          action: SnackBarAction(
              label: 'Herstelcode',
              onPressed: () => recoverVault(context, root)),
        ));
      }
    }
    return false;
  }
  if (resaveBiometric) await bio.removeKey(root);
  if (!context.mounted) return true;
  await _succeeded(context, root);
  await rememberForBiometric(root);
  return true;
}

Future<void> _succeeded(BuildContext context, String root) async {
  await services.known.add(root);
  await services.settings.setLastVault(root);
  final n = _failures.remove(p.normalize(root)) ?? 0;
  final total = await services.intruders.unseenCount();
  if (!context.mounted) return;
  if (n > 0 || total > 0) {
    final count = total > 0 ? total : n;
    showMessage(context,
        '$count mislukte ontgrendelpoging(en). Bekijk ze bij Instellingen → Mislukte pogingen.');
  }
}

/// Telt een mislukte poging; bij de 3e (6e, …) wordt, als dat is
/// ingeschakeld, ongemerkt een foto met de voorcamera gemaakt.
Future<void> registerFailedAttempt(BuildContext context, String root) async {
  final key = p.normalize(root);
  final n = (_failures[key] ?? 0) + 1;
  _failures[key] = n;
  final photo = services.settings.intruderPhoto && n % 3 == 0;
  await services.intruders.record(p.basename(root), takePhoto: photo);
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

/// Beschrijving van hoe een kluis met de vingerafdruk werkt.
String biometricModeLabel(BiometricMode? mode) => switch (mode) {
      BiometricMode.hardware => 'Sleutel gebonden aan je vingerafdruk',
      BiometricMode.app => 'Vingerafdruk gecontroleerd door de app (oudere Android)',
      null => 'Nog niet ingesteld',
    };
