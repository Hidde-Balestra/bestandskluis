import 'package:flutter/material.dart';

import '../app_services.dart';
import '../services/temp_files.dart';
import 'browser_screen.dart';
import 'ftp_screen.dart';
import 'gallery_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  final Set<int> _visited = {0};
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final at = _pausedAt;
      _pausedAt = null;
      if (at != null &&
          services.settings.autoLockMinutes > 0 &&
          DateTime.now().difference(at) >
              Duration(minutes: services.settings.autoLockMinutes) &&
          !services.ftp.isRunning &&
          services.vaults.unlockedVaults.isNotEmpty) {
        services.vaults.lockAll();
        TempFiles.clearViewCache();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Kluizen zijn automatisch vergrendeld')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          const BrowserScreen(),
          // Pas laden bij eerste bezoek (anders vragen alle schermen
          // tegelijk om rechten).
          _visited.contains(1) ? const GalleryScreen() : const SizedBox(),
          _visited.contains(2) ? const FtpScreen() : const SizedBox(),
          _visited.contains(3) ? const SettingsScreen() : const SizedBox(),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: services.ftp,
        builder: (context, _) => NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() {
            _tab = i;
            _visited.add(i);
          }),
          destinations: [
            const NavigationDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: 'Bestanden'),
            const NavigationDestination(
                icon: Icon(Icons.photo_library_outlined),
                selectedIcon: Icon(Icons.photo_library),
                label: 'Galerij'),
            NavigationDestination(
                icon: Badge(
                    isLabelVisible: services.ftp.isRunning,
                    child: const Icon(Icons.dns_outlined)),
                selectedIcon: Badge(
                    isLabelVisible: services.ftp.isRunning,
                    child: const Icon(Icons.dns)),
                label: 'FTP'),
            const NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Instellingen'),
          ],
        ),
      ),
    );
  }
}
