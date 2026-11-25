import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../crypto/vault_crypto.dart';

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

final _date = DateFormat('d MMM yyyy HH:mm', 'nl');

String formatDate(DateTime t) => _date.format(t);

enum FileKind { image, video, audio, text, pdf, archive, apk, other }

const _images = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif'};
const _videos = {'.mp4', '.mkv', '.webm', '.mov', '.3gp', '.avi', '.m4v'};
const _audio = {'.mp3', '.m4a', '.aac', '.wav', '.ogg', '.flac', '.opus'};
const _text = {'.txt', '.md', '.json', '.xml', '.csv', '.log', '.html', '.dart', '.yaml', '.yml'};
const _archives = {'.zip', '.rar', '.7z', '.tar', '.gz'};

/// Soort bestand op basis van de (ontsleutelde) naam.
FileKind kindOf(String name) {
  final ext = p.extension(VaultCrypto.plainName(name)).toLowerCase();
  if (_images.contains(ext)) return FileKind.image;
  if (_videos.contains(ext)) return FileKind.video;
  if (_audio.contains(ext)) return FileKind.audio;
  if (_text.contains(ext)) return FileKind.text;
  if (ext == '.pdf') return FileKind.pdf;
  if (_archives.contains(ext)) return FileKind.archive;
  if (ext == '.apk') return FileKind.apk;
  return FileKind.other;
}

bool isMedia(String name) {
  final k = kindOf(name);
  return k == FileKind.image || k == FileKind.video;
}

IconData iconFor(FileKind k) => switch (k) {
      FileKind.image => Icons.image_outlined,
      FileKind.video => Icons.movie_outlined,
      FileKind.audio => Icons.music_note_outlined,
      FileKind.text => Icons.description_outlined,
      FileKind.pdf => Icons.picture_as_pdf_outlined,
      FileKind.archive => Icons.folder_zip_outlined,
      FileKind.apk => Icons.android,
      FileKind.other => Icons.insert_drive_file_outlined,
    };
