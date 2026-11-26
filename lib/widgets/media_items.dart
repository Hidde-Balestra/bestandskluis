import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../screens/media_viewer.dart';
import '../screens/photo_editor_screen.dart';
import '../services/media_server.dart';
import '../services/temp_files.dart';
import '../util/format.dart';

/// Viewer-item voor een bestand op het toestel (gewoon of in een kluis):
/// - versleutelde video's worden gestreamd (geen kopie op schijf);
/// - in een kluis: favoriet maken;
/// - foto's (JPEG/PNG) bewerken;
/// - verwijderen gaat naar de prullenbak.
MediaItem mediaItemForFile(File f, String name, {required bool encrypted}) {
  final kind = kindOf(name);
  final video = kind == FileKind.video;
  final inVault = services.vaults.vaultRootFor(f.parent.path) != null;
  final lower = name.toLowerCase();
  final editable = kind == FileKind.image &&
      (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png'));
  return MediaItem(
    name: name,
    isVideo: video,
    encrypted: encrypted,
    load: () => TempFiles.plainFor(f, services.ops.keyForFile(f)),
    stream: video && encrypted
        ? () async {
            final key = services.ops.keyForFile(f);
            if (key == null) throw StateError('Kluis is vergrendeld');
            return MediaServer.instance.register(f, key, name);
          }
        : null,
    share: () => TempFiles.share([f], services.vaults).then((_) {}),
    delete: () async {
      await services.ops.delete([f]);
      return true;
    },
    isFavorite: inVault ? () => services.meta.isFavorite(f) : null,
    toggleFavorite: inVault ? () => services.meta.toggleFavorite(f) : null,
    edit: editable
        ? (context) async =>
            await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                    builder: (_) => PhotoEditorScreen(file: f, name: name))) ==
            true
        : null,
  );
}
