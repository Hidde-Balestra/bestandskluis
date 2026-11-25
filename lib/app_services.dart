import 'dart:io';

import 'crypto/vault_manager.dart';
import 'services/file_ops.dart';
import 'services/ftp_controller.dart';

/// Gedeelde diensten van de app.
class AppServices {
  AppServices({VaultManager? vaults}) : vaults = vaults ?? VaultManager() {
    ops = FileOps(this.vaults);
    ftp = FtpController(this.vaults);
  }

  final VaultManager vaults;
  late final FileOps ops;
  late final FtpController ftp;

  /// Klembord voor kopiëren/knippen in de bestandsbrowser.
  List<FileSystemEntity> clipboard = [];
  bool clipboardMove = false;
}

late AppServices services;
