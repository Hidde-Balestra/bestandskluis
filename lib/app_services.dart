import 'dart:io';

import 'crypto/vault_manager.dart';
import 'services/file_ops.dart';
import 'services/ftp_controller.dart';
import 'services/biometric_unlock.dart';
import 'services/known_vaults.dart';
import 'services/settings.dart';

/// Gedeelde diensten van de app.
class AppServices {
  AppServices({VaultManager? vaults}) : vaults = vaults ?? VaultManager() {
    ops = FileOps(this.vaults);
    ftp = FtpController(this.vaults);
    known = KnownVaults(this.vaults);
  }

  final VaultManager vaults;
  late final FileOps ops;
  late final FtpController ftp;
  late final KnownVaults known;
  final settings = AppSettings();
  final biometric = BiometricUnlock();

  /// Klembord voor kopiëren/knippen in de bestandsbrowser.
  List<FileSystemEntity> clipboard = [];
  bool clipboardMove = false;
}

late AppServices services;
