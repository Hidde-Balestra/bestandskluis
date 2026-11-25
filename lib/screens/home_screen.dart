import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../services/camera_mover.dart';
import '../services/system_bridge.dart';
import '../services/temp_files.dart';
import '../services/thumbnails.dart';
import 'browser_screen.dart';
import 'ftp_screen.dart';
import 'gallery_screen.dart';
import 'settings_screen.dart';
import 'share_target_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  final Set<int> _visited = {0};
  DateTime? _pausedAt;
  StreamSubscription<Incoming>? _incoming;
  bool? _secure;
  Set<String> _unlocked = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    services.vaults.addListener(_onVaults);
    services.settings.addListener(_updateSecureScreen);
    _incoming = SystemBridge.incoming.listen(_handle);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _updateSecureScreen();
      final first = await SystemBridge.initial();
      if (first != null) _handle(first);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    services.vaults.removeListener(_onVaults);
    services.settings.removeListener(_updateSecureScreen);
    _incoming?.cancel();
    super.dispose();
  }

  void _onVaults() {
    _updateSecureScreen();
    // Net ontgrendeld: kijken of er camerafoto's naar die kluis moeten.
    final now = services.vaults.unlockedVaults.toSet();
    if (now.difference(_unlocked).isNotEmpty) _moveCameraPhotos();
    // Vergrendeld: miniaturen uit het geheugen halen.
    if (_unlocked.difference(now).isNotEmpty) Thumbnails.clear();
    _unlocked = now;
  }

  /// Schermafbeeldingen blokkeren zolang er een kluis open is.
  void _updateSecureScreen() {
    final on = services.settings.secureScreen &&
        services.vaults.unlockedVaults.isNotEmpty;
    if (on != _secure) {
      _secure = on;
      SystemBridge.secureScreen(on);
    }
  }

  Future<void> _moveCameraPhotos() async {
    final n = await CameraMover.run();
    if (n > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$n nieuwe camerafoto(\'s) naar de kluis verplaatst')));
    }
  }

  Future<void> _handle(Incoming i) async {
    if (!mounted) return;
    switch (i) {
      case SharedFiles(:final paths):
        if (paths.isEmpty) return;
        final msg = await Navigator.of(context).push<String>(MaterialPageRoute(
            builder: (_) => ShareTargetScreen(paths: paths)));
        if (msg != null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      case FtpLink(:final url):
        setState(() {
          _tab = 2;
          _visited.add(2);
        });
        await openFtpLink(context, url);
      case StopFtp():
        await services.ftp.stop();
    }
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
      } else {
        _moveCameraPhotos();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.ftp,
      builder: (context, _) => PopScope(
        // Met een draaiende server de app niet afsluiten (dan stopt de
        // server), maar naar de achtergrond sturen.
        canPop: !services.ftp.isRunning,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && services.ftp.isRunning) SystemBridge.moveToBack();
        },
        child: Scaffold(
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
          bottomNavigationBar: NavigationBar(
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
      ),
    );
  }
}
