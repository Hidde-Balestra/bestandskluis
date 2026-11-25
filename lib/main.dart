import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app_services.dart';
import 'screens/home_screen.dart';
import 'services/storage.dart';
import 'services/temp_files.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('nl');
  services = AppServices();
  // Overgebleven ontsleutelde kopieën van een vorige sessie opruimen.
  await TempFiles.clearAll();
  final roots = await Storage.roots();
  await services.ftp.load(roots.first.path);
  await services.known.load();
  await services.settings.load();
  await services.biometric.load();
  // Sleutels van kluizen die niet meer bestaan opruimen.
  for (final root in services.biometric.enrolled) {
    if (!services.vaults.isVaultRoot(root)) await services.biometric.removeKey(root);
  }
  runApp(const BestandskluisApp());
}

class BestandskluisApp extends StatelessWidget {
  const BestandskluisApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E6B5E);
    return MaterialApp(
      title: 'Bestandskluis',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorSchemeSeed: seed, useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(
          colorSchemeSeed: seed, useMaterial3: true, brightness: Brightness.dark),
      home: const HomeScreen(),
    );
  }
}

