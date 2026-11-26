import 'dart:io';

import 'crypto/vault_manager.dart';
import 'services/file_ops.dart';
import 'services/ftp_controller.dart';
import 'services/backup.dart';
import 'services/biometric_unlock.dart';
import 'services/intruders.dart';
import 'services/known_vaults.dart';
import 'services/settings.dart';
import 'services/file_tools.dart';
import 'services/storage.dart';
import 'services/trash.dart';
import 'services/vault_meta.dart';
import 'services/zip_ops.dart';

/// Gedeelde diensten van de app.
class AppServices {
  AppServices({VaultManager? vaults}) : vaults = vaults ?? VaultManager() {
    ops = FileOps(this.vaults);
    ftp = FtpController(this.vaults);
    known = KnownVaults(this.vaults);
    zips = ZipOps(ops);
    trash = Trash(this.vaults,
        () async => [for (final r in await Storage.roots()) r.path]);
    ops.trash = trash;
    meta = VaultMetaStore(this.vaults);
    tools = FileTools(this.vaults);
  }

  final VaultManager vaults;
  late final FileOps ops;
  late final FtpController ftp;
  late final KnownVaults known;
  late final ZipOps zips;
  late final Trash trash;
  late final VaultMetaStore meta;
  late final FileTools tools;
  final settings = AppSettings();
  final biometric = BiometricUnlock();
  final intruders = Intruders();
  final backup = BackupService();

  /// Klembord voor kopiëren/knippen in de bestandsbrowser.
  List<FileSystemEntity> clipboard = [];
  bool clipboardMove = false;
}

late AppServices services;
