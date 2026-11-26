import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../crypto/vault_crypto.dart';
import '../crypto/vault_manager.dart';
import '../services/storage.dart';
import '../services/memory_files.dart';
import '../services/temp_files.dart';
import '../util/format.dart';
import '../widgets/app_logo.dart';
import '../widgets/dialogs.dart';
import '../widgets/encrypted_thumb.dart';
import '../widgets/media_items.dart';
import '../widgets/vault_dialogs.dart';
import '../widgets/vault_unlock.dart';
import 'media_viewer.dart';
import 'text_editor_screen.dart';
import 'tools_screens.dart';

class FsItem {
  FsItem(this.entity,
      {required this.isDir,
      required this.size,
      required this.modified,
      required this.encrypted,
      required this.isVault,
      this.key});

  final FileSystemEntity entity;
  final bool isDir;
  final int size;
  final DateTime modified;

  /// Versleuteld bestand in een kluis.
  final bool encrypted;

  /// Map die zelf een kluis is.
  final bool isVault;

  /// Kluissleutel (nodig voor versleutelde bestandsnamen).
  final SecretKey? key;

  String get realName => p.basename(entity.path);
  late final String name =
      encrypted ? VaultCrypto.plainName(realName, key) : realName;
  String get path => entity.path;
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, this.pickFileMode = false});

  /// Als bestandskiezer: tikken op een bestand geeft het pad terug.
  final bool pickFileMode;

  /// Verzoek van buitenaf (widget) om een map te openen.
  static final openRequest = ValueNotifier<String?>(null);

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  VaultManager get vaults => services.vaults;

  List<StorageRoot> _roots = [];
  String? _dir; // null = overzicht van opslaglocaties
  List<FsItem> _items = [];
  bool _loading = false;
  bool _permission = true;
  bool _showHidden = false;
  bool _grid = false;
  String? _error;
  int _plainInVault = 0;
  final Set<String> _selected = {};

  String? get _vaultRoot => _dir == null ? null : vaults.vaultRootFor(_dir!);
  bool get _inVault => _vaultRoot != null;
  bool get _vaultLocked => _inVault && !vaults.isUnlocked(_vaultRoot!);
  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    vaults.addListener(_reload);
    services.known.addListener(_reload);
    if (!widget.pickFileMode) BrowserScreen.openRequest.addListener(_onOpenRequest);
    _init();
  }

  @override
  void dispose() {
    vaults.removeListener(_reload);
    services.known.removeListener(_reload);
    BrowserScreen.openRequest.removeListener(_onOpenRequest);
    super.dispose();
  }

  Future<void> _init() async {
    _permission = await Storage.ensurePermission();
    _roots = await Storage.roots();
    if (mounted) setState(() {});
  }

  void _onOpenRequest() {
    final path = BrowserScreen.openRequest.value;
    if (path == null) return;
    BrowserScreen.openRequest.value = null;
    _open(path);
  }

  void _reload() {
    if (mounted) _open(_dir, keepSelection: true);
  }

  Future<void> _open(String? dir, {bool keepSelection = false}) async {
    if (!keepSelection) _selected.clear();
    if (dir != _dir && _query != null) {
      _searchGen++;
      _searchCtl.clear();
      _query = null;
      _results = [];
    }
    setState(() {
      _dir = dir;
      _loading = dir != null;
      _error = null;
    });
    if (dir == null) return;
    try {
      final key = vaults.keyForDir(dir);
      final inVault = vaults.vaultRootFor(dir) != null;
      final items = <FsItem>[];
      var plain = 0;
      await for (final e in Directory(dir).list(followLinks: false)) {
        final name = p.basename(e.path);
        if (name == VaultManager.markerName || name.endsWith('.part')) continue;
        if (!_showHidden && name.startsWith('.')) continue;
        try {
          final st = await e.stat();
          final isDir = st.type == FileSystemEntityType.directory;
          final enc = !isDir && inVault && VaultCrypto.isEncryptedName(name);
          if (!isDir && inVault && !enc) plain++;
          items.add(FsItem(e,
              isDir: isDir,
              size: enc ? VaultCrypto.plainLength(st.size) : st.size,
              modified: st.modified,
              encrypted: enc,
              isVault: isDir && vaults.isVaultRoot(e.path),
              key: key));
        } on FileSystemException {
          continue;
        }
      }
      items.sort(_compare);
      if (!mounted || _dir != dir) return;
      setState(() {
        _items = items;
        _plainInVault = key != null ? plain : 0;
        _selected.removeWhere((s) => !items.any((i) => i.path == s));
        _loading = false;
      });
    } on FileSystemException catch (e) {
      if (!mounted) return;
      setState(() {
        _items = [];
        _loading = false;
        _error = e.osError?.message ?? e.message;
      });
    }
  }

  /// Mappen eerst, daarna volgens de gekozen sortering.
  int _compare(FsItem a, FsItem b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    final sort = services.settings.sort;
    final desc = sort.startsWith('-');
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    final r = switch (sort.replaceFirst('-', '')) {
      'datum' => a.modified.compareTo(b.modified),
      'grootte' => a.isDir ? 0 : a.size.compareTo(b.size),
      _ => byName,
    };
    final v = desc ? -r : r;
    return v != 0 ? v : byName;
  }

  void _up() {
    final dir = _dir;
    if (dir == null) return;
    if (_roots.any((r) => p.equals(r.path, dir))) {
      _open(null);
    } else {
      _open(p.dirname(dir));
    }
  }

  // --- Kluizen --------------------------------------------------------------

  Future<bool> _unlock(String root) => unlockVault(context, root);

  /// Bestaande map (met inhoud) omzetten naar een kluis.
  Future<void> _createVault(String path) async {
    final ok = await confirmDialog(context,
        title: 'Map versleutelen',
        message:
            'Alle bestanden in "${p.basename(path)}" (ook in submappen) worden met AES-256 '
            'versleuteld. Zonder het wachtwoord (of een herstelcode) zijn ze '
            'niet meer te openen.',
        confirm: 'Doorgaan');
    if (!ok || !mounted) return;
    final names = await askEncryptNames(context);
    if (names == null || !mounted) return;
    final pw = await askPassword(context,
        title: 'Wachtwoord voor de kluis', repeat: true);
    if (pw == null || !mounted) return;
    final done = await runWithProgress(context, 'Versleutelen…', (update) async {
      update('Sleutel afleiden…');
      await vaults.create(path, pw,
          encryptNames: names, onProgress: (d, t, n) => update('$d / $t\n$n'));
      await services.known.add(path);
      await rememberForBiometric(path);
      return true;
    });
    _reload();
    if (done == true && mounted) await _offerRecoveryCode(path);
  }

  Future<void> _offerRecoveryCode(String root) async {
    final ok = await confirmDialog(context,
        title: 'Herstelcode maken?',
        message: 'Met een herstelcode kun je de kluis openen als je het '
            'wachtwoord vergeet. Schrijf hem op en bewaar hem niet op deze '
            'telefoon. Je kunt dit ook later doen via het menu van de kluis.',
        confirm: 'Code maken');
    if (ok && mounted) await createAndShowRecoveryCode(context, root);
  }

  /// Standaardlocatie voor nieuwe kluizen vanaf het startscherm.
  String? get _defaultVaultParent =>
      _roots.isEmpty ? null : p.join(_roots.first.path, 'Kluizen');

  /// Nieuwe, lege kluis maken in [parent] (standaard de huidige map, of
  /// "Kluizen" in de interne opslag) en die openen.
  Future<void> _newVault([String? parent]) async {
    parent ??= _dir ?? _defaultVaultParent;
    if (parent == null) return;
    if (vaults.vaultRootFor(parent) != null) {
      showMessage(context, 'Een kluis kan niet in een andere kluis liggen');
      return;
    }
    final name = (await askText(context,
            title: 'Nieuwe kluis', initial: 'Mijn kluis', confirm: 'Volgende'))
        ?.trim();
    if (name == null || name.isEmpty || !mounted) return;
    if (name.contains('/') || name.startsWith('.')) {
      showMessage(context, 'Ongeldige naam');
      return;
    }
    final dir = Directory(p.join(parent, name));
    if (dir.existsSync()) {
      showMessage(context, 'Er bestaat al een map "$name"');
      return;
    }
    final names = await askEncryptNames(context);
    if (names == null || !mounted) return;
    final pw = await askPassword(context,
        title: 'Wachtwoord voor "$name"',
        repeat: true,
        message: 'Zonder dit wachtwoord (of een herstelcode) zijn de '
            'bestanden niet meer te openen.');
    if (pw == null || !mounted) return;
    final ok = await runWithProgress(context, 'Kluis maken…', (update) async {
      update('Sleutel afleiden…');
      await dir.create(recursive: true);
      try {
        await vaults.create(dir.path, pw, encryptNames: names);
      } catch (_) {
        await dir.delete(recursive: true);
        rethrow;
      }
      await services.known.add(dir.path);
      await rememberForBiometric(dir.path);
      return true;
    });
    if (ok == true && mounted) {
      await _open(dir.path);
      if (!mounted) return;
      await _offerRecoveryCode(dir.path);
      if (mounted) {
        showMessage(context,
            'Kluis "$name" gemaakt. Bestanden die je hier plakt worden versleuteld.');
      }
    }
  }

  void _newMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Nieuwe map'),
            onTap: () {
              Navigator.pop(ctx);
              _newFolder();
            },
          ),
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('Nieuwe notitie'),
            subtitle: _inVault ? const Text('Versleuteld in deze kluis') : null,
            onTap: () {
              Navigator.pop(ctx);
              _newNote();
            },
          ),
          if (!_inVault) ...[
            ListTile(
              leading: const Icon(Icons.enhanced_encryption_outlined),
              title: const Text('Nieuwe kluis'),
              subtitle: const Text('Lege versleutelde map met wachtwoord'),
              onTap: () {
                Navigator.pop(ctx);
                _newVault();
              },
            ),
            if (_dir != null && !_roots.any((r) => p.equals(r.path, _dir!)))
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('Deze map versleutelen'),
                subtitle: Text(p.basename(_dir!)),
                onTap: () {
                  Navigator.pop(ctx);
                  _createVault(_dir!);
                },
              ),
          ],
        ]),
      ),
    );
  }

  Future<void> _removeVault(String root) async {
    final ok = await confirmDialog(context,
        title: 'Versleuteling opheffen',
        message: 'Alle bestanden in deze kluis worden permanent ontsleuteld '
            'en de map wordt weer een gewone map.',
        confirm: 'Ontsleutelen',
        destructive: true);
    if (!ok || !mounted) return;
    await runWithProgress(context, 'Ontsleutelen…', (update) async {
      await vaults.removeVault(root,
          onProgress: (d, t, n) => update('$d / $t\n$n'));
      await services.known.remove(root);
      await forgetBiometric(root);
    });
  }

  Future<void> _encryptPlain() async {
    final root = _vaultRoot;
    if (root == null) return;
    await runWithProgress(context, 'Versleutelen…', (update) async {
      await vaults.encryptPlainFiles(root,
          onProgress: (d, t, n) => update('$d / $t\n$n'));
    });
  }

  // --- Openen ---------------------------------------------------------------

  MediaItem _mediaItem(FsItem i) =>
      mediaItemForFile(i.entity as File, i.name, encrypted: i.encrypted);

  Future<void> _tap(FsItem item) async {
    if (_selecting) {
      _toggle(item);
      return;
    }
    if (item.isDir) {
      if (item.isVault && !vaults.isUnlocked(item.path)) {
        if (!await _unlock(item.path)) return;
      }
      _open(item.path);
      return;
    }
    if (widget.pickFileMode) {
      Navigator.pop(context, item.path);
      return;
    }
    final file = item.entity as File;
    if (isTextFile(item.name)) {
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TextEditorScreen(file: file, name: item.name)));
      _reload();
      return;
    }
    if (item.name.toLowerCase().endsWith('.zip')) {
      final ok = await confirmDialog(context,
          title: item.name,
          message: 'Uitpakken in een nieuwe map "${p.basenameWithoutExtension(item.name)}"?',
          confirm: 'Uitpakken');
      if (ok) await _unzip(item);
      return;
    }
    if (isMedia(item.name)) {
      final media = _items.where((i) => !i.isDir && isMedia(i.name)).toList();
      final deleted = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
              builder: (_) => MediaViewer(
                  items: media.map(_mediaItem).toList(),
                  initialIndex: media.indexOf(item))));
      if (deleted == true) _reload();
      return;
    }
    final plain = await runWithProgress(
        context,
        item.encrypted ? 'Ontsleutelen…' : 'Openen…',
        (_) => TempFiles.plainFor(file, services.ops.keyForFile(file)));
    if (plain == null) return;
    final r = await OpenFilex.open(plain.path);
    if (r.type != ResultType.done && mounted) {
      showMessage(context, 'Geen app gevonden om dit bestand te openen');
    }
  }

  void _toggle(FsItem item) => setState(() {
        if (!_selected.remove(item.path)) _selected.add(item.path);
      });

  List<FsItem> get _selectedItems =>
      _items.where((i) => _selected.contains(i.path)).toList();

  // --- Acties ---------------------------------------------------------------

  Future<void> _share(List<FsItem> items) async {
    final files = items.where((i) => !i.isDir).map((i) => i.entity as File).toList();
    if (files.isEmpty) {
      showMessage(context, 'Alleen bestanden kunnen worden gedeeld');
      return;
    }
    final encrypted = items.any((i) => i.encrypted);
    await runWithProgress(
      context,
      encrypted ? 'Tijdelijk ontsleutelen…' : 'Delen…',
      (update) => TempFiles.share(files, vaults,
          onProgress: (d, t) => update('$d / $t')),
    );
    if (encrypted && mounted) {
      showMessage(context,
          'Ontsleutelde kopie wordt over ${TempFiles.shareDelay.inMinutes} minuten verwijderd');
    }
    setState(_selected.clear);
  }

  Future<void> _delete(List<FsItem> items) async {
    final names = items.length == 1 ? '"${items.first.name}"' : '${items.length} items';
    final ok = await confirmDialog(context,
        title: 'Verwijderen',
        message: '$names naar de prullenbak verplaatsen? Je kunt het daar 30 dagen terugzetten.',
        confirm: 'Verwijderen',
        destructive: true);
    if (!ok || !mounted) return;
    await runWithProgress(context, 'Verwijderen…',
        (_) => services.ops.delete(items.map((i) => i.entity).toList()));
    for (final i in items.where((i) => i.isVault)) {
      await forgetBiometric(i.path);
    }
    _reload();
  }

  Future<void> _rename(FsItem item) async {
    final name = await askText(context,
        title: 'Hernoemen', initial: item.name, confirm: 'Hernoemen');
    if (name == null || name.isEmpty || name == item.name || !mounted) return;
    try {
      await services.ops.rename(item.entity, name);
      if (item.isVault) {
        vaults.lock(item.path);
        await services.known.remove(item.path);
        await forgetBiometric(item.path);
        await services.known.add(p.join(p.dirname(item.path), name));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _reload();
  }

  void _toClipboard(List<FsItem> items, {required bool move}) {
    services.clipboard = items.map((i) => i.entity).toList();
    services.clipboardMove = move;
    setState(_selected.clear);
    showMessage(context,
        '${items.length} item(s) ${move ? 'geknipt' : 'gekopieerd'} — kies een map en tik op Plakken');
  }

  Future<void> _paste() async {
    final dir = _dir;
    if (dir == null) return;
    final items = services.clipboard;
    final move = services.clipboardMove;
    await runWithProgress(context, move ? 'Verplaatsen…' : 'Kopiëren…',
        (update) async {
      await services.ops.transfer(items, dir, move: move, onItem: update);
    });
    if (move) services.clipboard = [];
    _reload();
  }

  Future<void> _openTrash() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const TrashScreen()));
    _reload();
  }

  /// Nieuwe (versleutelde, als de map in een kluis ligt) notitie.
  Future<void> _newNote() async {
    final dir = _dir;
    if (dir == null) return;
    final stamp = DateFormat('yyyy-MM-dd HH.mm').format(DateTime.now());
    final name = await askText(context,
        title: 'Nieuwe notitie', initial: 'Notitie $stamp.txt', confirm: 'Maken');
    if (name == null || name.isEmpty || !mounted) return;
    final plain = name.contains('.') ? name : '$name.txt';
    final key = vaults.keyForDir(dir);
    final inVault = vaults.vaultRootFor(dir) != null;
    try {
      final file = VaultManager.uniqueFile(dir, plain,
          encryptWith: inVault ? key : null);
      await MemoryFiles.writeText(file, '', inVault ? key : null);
      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TextEditorScreen(
                  file: file, name: VaultCrypto.plainName(p.basename(file.path), key))));
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _reload();
  }

  Future<void> _newFolder() async {
    final name = await askText(context,
        title: 'Nieuwe map', initial: 'Nieuwe map', confirm: 'Maken');
    if (name == null || name.isEmpty || _dir == null) return;
    try {
      await Directory(p.join(_dir!, name)).create();
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _reload();
  }

  void _details(FsItem item) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              SelectableText('Pad: ${item.path}'),
              if (!item.isDir) Text('Grootte: ${formatSize(item.size)}'),
              Text('Gewijzigd: ${formatDate(item.modified)}'),
              if (item.encrypted)
                const Text('Versleuteld met AES-256-GCM'),
              if (item.isVault)
                Text(vaults.isUnlocked(item.path)
                    ? 'Kluis (ontgrendeld)'
                    : 'Kluis (vergrendeld)'),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _itemMenu(FsItem item, String action) async {
    switch (action) {
      case 'share':
        await _share([item]);
      case 'rename':
        await _rename(item);
      case 'copy':
        _toClipboard([item], move: false);
      case 'move':
        _toClipboard([item], move: true);
      case 'delete':
        await _delete([item]);
      case 'encrypt':
        await _createVault(item.path);
      case 'lock':
        vaults.lock(item.path);
        await TempFiles.clearViewCache();
      case 'decrypt':
        if (!vaults.isUnlocked(item.path) && !await _unlock(item.path)) return;
        await _removeVault(item.path);
      case 'details':
        _details(item);
      case 'zip':
        await _zip([item]);
      case 'unzip':
        await _unzip(item);
    }
  }

  Future<void> _zip(List<FsItem> items) async {
    final dir = _dir;
    if (dir == null || items.isEmpty) return;
    final base = items.length == 1
        ? p.basenameWithoutExtension(items.first.name)
        : p.basename(dir);
    final name = await askText(context,
        title: 'Inpakken (zip)', initial: '$base.zip', confirm: 'Inpakken');
    if (name == null || name.isEmpty || !mounted) return;
    final zipName = name.toLowerCase().endsWith('.zip') ? name : '$name.zip';
    await runWithProgress(context, 'Inpakken…', (update) async {
      await services.zips.zip(items.map((i) => i.entity).toList(), dir, zipName,
          onItem: update);
    });
    setState(_selected.clear);
    _reload();
  }

  Future<void> _unzip(FsItem item) async {
    await runWithProgress(context, 'Uitpakken…', (update) async {
      await services.zips.unzip(item.entity as File, onItem: update);
    });
    _reload();
  }

  // --- Opbouw ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _dir == null && !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          setState(_selected.clear);
        } else if (_query != null) {
          _closeSearch();
        } else {
          _up();
        }
      },
      child: Scaffold(
        appBar: _selecting ? _selectionBar() : _normalBar(),
        body: _body(),
        floatingActionButton: _fab(),
      ),
    );
  }

  Widget? _fab() {
    if (_selecting || _vaultLocked || widget.pickFileMode || !_permission) {
      return null;
    }
    if (_dir == null) {
      if (_defaultVaultParent == null) return null;
      return FloatingActionButton.extended(
        onPressed: () => _newVault(),
        icon: const Icon(Icons.enhanced_encryption_outlined),
        label: const Text('Nieuwe kluis'),
      );
    }
    if (services.clipboard.isNotEmpty) {
      return FloatingActionButton.extended(
        onPressed: _paste,
        icon: const Icon(Icons.content_paste),
        label: Text('Plakken (${services.clipboard.length})'),
      );
    }
    return FloatingActionButton(
      tooltip: 'Nieuw',
      onPressed: _newMenu,
      child: const Icon(Icons.add),
    );
  }

  PreferredSizeWidget _selectionBar() {
    final items = _selectedItems;
    return AppBar(
      leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(_selected.clear)),
      title: Text('${_selected.length} geselecteerd'),
      actions: [
        if (_selected.length < _items.length)
          IconButton(
              tooltip: 'Alles selecteren',
              icon: const Icon(Icons.select_all),
              onPressed: () =>
                  setState(() => _selected.addAll(_items.map((i) => i.path))))
        else
          IconButton(
              tooltip: 'Niets selecteren',
              icon: const Icon(Icons.deselect),
              onPressed: () => setState(_selected.clear)),
        IconButton(
            tooltip: 'Delen',
            icon: const Icon(Icons.share),
            onPressed: () => _share(items)),
        IconButton(
            tooltip: 'Verwijderen',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(items)),
        PopupMenuButton<String>(
          onSelected: (a) {
            switch (a) {
              case 'copy':
                _toClipboard(items, move: false);
              case 'move':
                _toClipboard(items, move: true);
              case 'rename':
                _rename(items.single);
              case 'zip':
                _zip(items);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'copy', child: Text('Kopiëren')),
            const PopupMenuItem(value: 'move', child: Text('Knippen')),
            if (!items.any((i) => i.isVault))
              const PopupMenuItem(value: 'zip', child: Text('Inpakken (zip)')),
            if (items.length == 1)
              const PopupMenuItem(value: 'rename', child: Text('Hernoemen')),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _searchBar() => AppBar(
        leading: IconButton(
            tooltip: 'Zoeken sluiten',
            icon: const Icon(Icons.arrow_back),
            onPressed: _closeSearch),
        title: TextField(
          controller: _searchCtl,
          autofocus: true,
          decoration: InputDecoration(
              hintText: 'Zoeken in ${_rootLabel(_dir!)} en submappen',
              border: InputBorder.none),
          onChanged: _search,
        ),
        actions: [
          if (_searchCtl.text.isNotEmpty)
            IconButton(
                tooltip: 'Wissen',
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _searchCtl.clear();
                  _search('');
                }),
        ],
      );

  Future<void> _chooseSort() async {
    const options = [
      ('naam', 'Naam (A–Z)'),
      ('-naam', 'Naam (Z–A)'),
      ('-datum', 'Nieuwste eerst'),
      ('datum', 'Oudste eerst'),
      ('-grootte', 'Grootste eerst'),
      ('grootte', 'Kleinste eerst'),
    ];
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Sorteren'),
        children: [
          RadioGroup<String>(
            groupValue: services.settings.sort,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(children: [
              for (final (k, label) in options)
                RadioListTile<String>(value: k, title: Text(label)),
            ]),
          ),
        ],
      ),
    );
    if (v != null) {
      await services.settings.setSort(v);
      _reload();
    }
  }

  PreferredSizeWidget _normalBar() {
    final dir = _dir;
    final root = _vaultRoot;
    if (_query != null && dir != null) return _searchBar();
    return AppBar(
      leading: dir == null
          ? null
          : IconButton(icon: const Icon(Icons.arrow_upward), onPressed: _up),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (root != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(_vaultLocked ? Icons.lock : Icons.lock_open,
                    size: 18),
              ),
            Flexible(
              child: Text(
                  dir == null
                      ? (widget.pickFileMode ? 'Kies een bestand' : 'Bestanden')
                      : _rootLabel(dir),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          if (dir != null)
            Text(dir,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis),
        ],
      ),
      actions: [
        if (dir != null && !_vaultLocked)
          IconButton(
              tooltip: 'Zoeken',
              icon: const Icon(Icons.search),
              onPressed: () => setState(() {
                    _query = '';
                    _results = [];
                  })),
        if (dir != null &&
            !_vaultLocked &&
            !widget.pickFileMode &&
            _items.isNotEmpty)
          IconButton(
              tooltip: 'Alles selecteren',
              icon: const Icon(Icons.select_all),
              onPressed: () =>
                  setState(() => _selected.addAll(_items.map((i) => i.path)))),
        if (dir != null)
          PopupMenuButton<String>(
            onSelected: (a) async {
              switch (a) {
                case 'folder':
                  await _newFolder();
                case 'vault':
                  await _newVault();
                case 'encryptHere':
                  await _createVault(dir);
                case 'view':
                  setState(() => _grid = !_grid);
                case 'sort':
                  await _chooseSort();
                case 'hidden':
                  setState(() => _showHidden = !_showHidden);
                  _reload();
                case 'lock':
                  vaults.lock(root!);
                  await TempFiles.clearViewCache();
                case 'unlock':
                  await _unlock(root!);
                case 'password':
                  await changeVaultPassword(context, root!);
                case 'recovery':
                  await createAndShowRecoveryCode(context, root!);
                case 'recover':
                  if (await recoverVault(context, root!)) _reload();
                case 'remove':
                  await _removeVault(root!);
                case 'refresh':
                  _reload();
                case 'trash':
                  await _openTrash();
                case 'dupes':
                  await Navigator.push(context,
                      MaterialPageRoute(builder: (_) => DuplicatesScreen(dir: Directory(dir))));
                  _reload();
                case 'usage':
                  await Navigator.push(context,
                      MaterialPageRoute(builder: (_) => StorageScreen(dir: Directory(dir))));
              }
            },
            itemBuilder: (_) => [
              if (!_vaultLocked)
                const PopupMenuItem(value: 'folder', child: Text('Nieuwe map')),
              if (root == null) ...[
                const PopupMenuItem(value: 'vault', child: Text('Nieuwe kluis')),
                if (!_roots.any((r) => p.equals(r.path, dir)))
                  const PopupMenuItem(
                      value: 'encryptHere',
                      child: Text('Deze map versleutelen')),
              ],
              if (!_vaultLocked) ...[
                PopupMenuItem(
                    value: 'view',
                    child: Text(_grid ? 'Lijstweergave' : 'Galerijweergave')),
                const PopupMenuItem(value: 'sort', child: Text('Sorteren…')),
              ],
              CheckedPopupMenuItem(
                  value: 'hidden',
                  checked: _showHidden,
                  child: const Text('Verborgen bestanden')),
              const PopupMenuItem(value: 'refresh', child: Text('Vernieuwen')),
              if (!_vaultLocked) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'dupes', child: Text('Duplicaten zoeken')),
                const PopupMenuItem(value: 'usage', child: Text('Opslaganalyse')),
              ],
              const PopupMenuItem(value: 'trash', child: Text('Prullenbak')),
              if (root != null && !_vaultLocked) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(
                    value: 'lock', child: Text('Kluis vergrendelen')),
                const PopupMenuItem(
                    value: 'password', child: Text('Wachtwoord wijzigen')),
                const PopupMenuItem(
                    value: 'recovery', child: Text('Herstelcode maken')),
                const PopupMenuItem(
                    value: 'remove', child: Text('Versleuteling opheffen')),
              ],
              if (root != null && _vaultLocked) ...[
                const PopupMenuItem(
                    value: 'unlock', child: Text('Kluis ontgrendelen')),
                const PopupMenuItem(
                    value: 'recover', child: Text('Herstelcode gebruiken')),
              ],
            ],
          ),
      ],
    );
  }

  // --- Zoeken ---------------------------------------------------------------

  final _searchCtl = TextEditingController();

  /// null = niet zoeken.
  String? _query;
  List<FsItem> _results = [];
  bool _searchBusy = false;
  int _searchGen = 0;

  void _closeSearch() {
    _searchGen++;
    _searchCtl.clear();
    setState(() {
      _query = null;
      _results = [];
      _searchBusy = false;
    });
  }

  /// Zoekt (hoofdletterongevoelig) in de huidige map en alle submappen.
  /// Versleutelde namen worden met de sleutel van hun kluis gelezen;
  /// vergrendelde kluizen worden overgeslagen.
  Future<void> _search(String q) async {
    final gen = ++_searchGen;
    final dir = _dir;
    q = q.trim().toLowerCase();
    setState(() {
      _query = q;
      _results = [];
      _searchBusy = q.isNotEmpty;
    });
    if (q.isEmpty || dir == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (gen != _searchGen) return;
    final out = <FsItem>[];
    final queue = <String>[dir];
    var seen = 0;
    while (queue.isNotEmpty && out.length < 300 && gen == _searchGen) {
      final d = queue.removeAt(0);
      final root = vaults.vaultRootFor(d);
      if (root != null && !vaults.isUnlocked(root)) continue;
      final key = root == null ? null : vaults.keyFor(root);
      try {
        await for (final e in Directory(d).list(followLinks: false)) {
          final name = p.basename(e.path);
          if (name == VaultManager.markerName || name.endsWith('.part')) continue;
          if (!_showHidden && name.startsWith('.')) continue;
          final isDir = e is Directory;
          if (isDir) queue.add(e.path);
          final enc = !isDir && root != null && VaultCrypto.isEncryptedName(name);
          final shown = enc ? VaultCrypto.plainName(name, key) : name;
          if (shown.toLowerCase().contains(q)) {
            final st = await e.stat();
            out.add(FsItem(e,
                isDir: isDir,
                size: enc ? VaultCrypto.plainLength(st.size) : st.size,
                modified: st.modified,
                encrypted: enc,
                isVault: isDir && vaults.isVaultRoot(e.path),
                key: key));
          }
          // Af en toe tussenresultaten tonen.
          if (++seen % 500 == 0 && gen == _searchGen && mounted) {
            setState(() => _results = List.of(out));
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    if (gen != _searchGen || !mounted) return;
    setState(() {
      _results = out;
      _searchBusy = false;
    });
  }

  Widget _searchResults() {
    final q = _query ?? '';
    if (q.isEmpty) {
      return const _Message(
          icon: Icons.search, text: 'Typ een (deel van een) naam');
    }
    if (_results.isEmpty) {
      return _searchBusy
          ? const Center(child: CircularProgressIndicator())
          : const _Message(icon: Icons.search_off, text: 'Niets gevonden');
    }
    return Column(children: [
      if (_searchBusy) const LinearProgressIndicator(),
      Expanded(
        child: ListView.builder(
          itemCount: _results.length,
          itemBuilder: (context, n) {
            final i = _results[n];
            return ListTile(
              leading: SizedBox(
                  width: 40, height: 40, child: Center(child: _leading(i))),
              title: Text(i.name, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  p.relative(i.entity.parent.path, from: _dir!) == '.'
                      ? (i.isDir ? 'map' : formatSize(i.size))
                      : '${p.relative(i.entity.parent.path, from: _dir!)}'
                          '${i.isDir ? '' : ' · ${formatSize(i.size)}'}',
                  overflow: TextOverflow.ellipsis),
              onTap: () async {
                if (i.isDir) {
                  _closeSearch();
                  await _tap(i);
                } else {
                  await _openFound(i);
                }
              },
            );
          },
        ),
      ),
    ]);
  }

  /// Opent een zoekresultaat (in een andere map dan de huidige).
  Future<void> _openFound(FsItem item) async {
    final file = item.entity as File;
    if (widget.pickFileMode) {
      Navigator.pop(context, item.path);
      return;
    }
    if (isMedia(item.name)) {
      final deleted = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  MediaViewer(items: [_mediaItem(item)], initialIndex: 0)));
      if (deleted == true) {
        _reload();
        await _search(_searchCtl.text);
      }
      return;
    }
    final plain = await runWithProgress(
        context,
        item.encrypted ? 'Ontsleutelen…' : 'Openen…',
        (_) => TempFiles.plainFor(file, services.ops.keyForFile(file)));
    if (plain == null) return;
    final r = await OpenFilex.open(plain.path);
    if (r.type != ResultType.done && mounted) {
      showMessage(context, 'Geen app gevonden om dit bestand te openen');
    }
  }

  String _rootLabel(String dir) {
    for (final r in _roots) {
      if (p.equals(r.path, dir)) return r.name;
    }
    return p.basename(dir);
  }

  Widget _body() {
    if (!_permission) {
      return _Message(
        icon: Icons.folder_off_outlined,
        text: 'Bestandskluis heeft toegang tot alle bestanden nodig om je '
            'opslag te kunnen beheren.',
        action: FilledButton(
            onPressed: _init, child: const Text('Toegang verlenen')),
      );
    }
    if (_dir == null) return _rootsView();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _Message(icon: Icons.error_outline, text: _error!);
    }
    if (_vaultLocked) {
      return _Message(
        icon: Icons.lock,
        text: 'Deze kluis is vergrendeld.',
        action: Column(mainAxisSize: MainAxisSize.min, children: [
          FilledButton.icon(
              onPressed: () => _unlock(_vaultRoot!),
              icon: const Icon(Icons.lock_open),
              label: const Text('Ontgrendelen')),
          TextButton(
              onPressed: () async {
                if (await recoverVault(context, _vaultRoot!)) _reload();
              },
              child: const Text('Wachtwoord vergeten? Herstelcode gebruiken')),
        ]),
      );
    }
    if (_query != null) return _searchResults();
    final list = _items.isEmpty
        ? const _Message(icon: Icons.folder_open, text: 'Deze map is leeg')
        : RefreshIndicator(
            onRefresh: () => _open(_dir, keepSelection: true),
            child: _grid ? _gridView() : _listView(),
          );
    return Column(children: [
      if (_plainInVault > 0)
        MaterialBanner(
          leading: const Icon(Icons.warning_amber),
          content: Text(
              '$_plainInVault bestand(en) in deze map zijn nog niet versleuteld.'),
          actions: [
            TextButton(
                onPressed: _encryptPlain, child: const Text('Versleutelen')),
          ],
        ),
      Expanded(child: list),
    ]);
  }

  Widget _rootsView() {
    final quick = <(String, IconData, String)>[];
    if (_roots.isNotEmpty) {
      final base = _roots.first.path;
      for (final (name, icon, sub) in [
        ('Downloads', Icons.download, 'Download'),
        ('Camera', Icons.photo_camera, 'DCIM'),
        ('Afbeeldingen', Icons.image, 'Pictures'),
        ('Video\'s', Icons.movie, 'Movies'),
        ('Documenten', Icons.description, 'Documents'),
      ]) {
        final path = p.join(base, sub);
        if (Directory(path).existsSync()) quick.add((name, icon, path));
      }
    }
    final known = services.known.paths;
    final myVaults = [
      ...known,
      ...vaults.unlockedVaults.where((v) => !known.any((k) => p.equals(k, v))),
    ];
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.only(bottom: 88), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(children: [
          const AppLogo(size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Bestandskluis',
                  style: Theme.of(context).textTheme.titleLarge),
              Text('Bestanden, galerij, FTP en versleutelde mappen',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
      const ListTile(dense: true, title: Text('Mijn kluizen')),
      if (myVaults.isEmpty)
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Nog geen kluizen. Een kluis is een map waarvan de '
                  'bestanden met je wachtwoord worden versleuteld.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _newVault(),
                icon: const Icon(Icons.enhanced_encryption_outlined),
                label: const Text('Kluis maken'),
              ),
            ]),
          ),
        ),
      for (final v in myVaults)
        ListTile(
          leading: Icon(vaults.isUnlocked(v) ? Icons.lock_open : Icons.lock,
              color: scheme.tertiary),
          title: Text(p.basename(v)),
          subtitle: Text(v, overflow: TextOverflow.ellipsis),
          onTap: () async {
            if (!vaults.isUnlocked(v) && !await _unlock(v)) return;
            _open(v);
          },
          trailing: vaults.isUnlocked(v)
              ? IconButton(
                  tooltip: 'Vergrendelen',
                  icon: const Icon(Icons.lock),
                  onPressed: () {
                    vaults.lock(v);
                    TempFiles.clearViewCache();
                  },
                )
              : null,
        ),
      const Divider(),
      const ListTile(dense: true, title: Text('Opslag')),
      for (final r in _roots)
        ListTile(
          leading: const Icon(Icons.smartphone),
          title: Text(r.name),
          subtitle: Text(r.path),
          onTap: () => _open(r.path),
        ),
      if (quick.isNotEmpty) const Divider(),
      for (final (name, icon, path) in quick)
        ListTile(
            leading: Icon(icon), title: Text(name), onTap: () => _open(path)),
      const Divider(),
      ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Prullenbak'),
          onTap: _openTrash),
    ]);
  }

  Widget _leading(FsItem i, {double size = 40}) {
    if (i.isDir) {
      return Icon(
          i.isVault
              ? (vaults.isUnlocked(i.path) ? Icons.lock_open : Icons.lock)
              : Icons.folder,
          size: size * 0.8,
          color: i.isVault
              ? Theme.of(context).colorScheme.tertiary
              : Theme.of(context).colorScheme.primary);
    }
    final kind = kindOf(i.name);
    if (kind == FileKind.image && !i.encrypted) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(i.entity as File,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: (size * 3).round(),
            errorBuilder: (_, _, _) => Icon(iconFor(kind), size: size * 0.8)),
      );
    }
    if ((kind == FileKind.image || kind == FileKind.video) && i.encrypted) {
      return EncryptedThumb(
          file: i.entity as File,
          size: size,
          video: kind == FileKind.video);
    }
    return Stack(clipBehavior: Clip.none, children: [
      Icon(iconFor(kind), size: size * 0.8),
      if (i.encrypted)
        const Positioned(
            right: -4, bottom: -4, child: Icon(Icons.lock, size: 14)),
    ]);
  }

  Widget? _trailing(FsItem i) {
    if (_selecting) {
      return Checkbox(
          value: _selected.contains(i.path), onChanged: (_) => _toggle(i));
    }
    if (widget.pickFileMode) return null;
    final inVault = _inVault;
    return PopupMenuButton<String>(
      onSelected: (a) => _itemMenu(i, a),
      itemBuilder: (_) => [
        if (!i.isDir) const PopupMenuItem(value: 'share', child: Text('Delen')),
        const PopupMenuItem(value: 'rename', child: Text('Hernoemen')),
        const PopupMenuItem(value: 'copy', child: Text('Kopiëren')),
        const PopupMenuItem(value: 'move', child: Text('Knippen')),
        if (!i.isVault)
          const PopupMenuItem(value: 'zip', child: Text('Inpakken (zip)')),
        if (!i.isDir && i.name.toLowerCase().endsWith('.zip'))
          const PopupMenuItem(value: 'unzip', child: Text('Uitpakken')),
        if (i.isDir && !i.isVault && !inVault)
          const PopupMenuItem(value: 'encrypt', child: Text('Map versleutelen')),
        if (i.isVault && vaults.isUnlocked(i.path))
          const PopupMenuItem(value: 'lock', child: Text('Vergrendelen')),
        if (i.isVault)
          const PopupMenuItem(
              value: 'decrypt', child: Text('Versleuteling opheffen')),
        const PopupMenuItem(value: 'details', child: Text('Details')),
        const PopupMenuItem(value: 'delete', child: Text('Verwijderen')),
      ],
    );
  }

  Widget _listView() => ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _items.length,
        itemBuilder: (context, n) {
          final i = _items[n];
          return ListTile(
            selected: _selected.contains(i.path),
            leading: SizedBox(width: 40, height: 40, child: Center(child: _leading(i))),
            title: Text(i.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(i.isDir
                ? formatDate(i.modified)
                : '${formatSize(i.size)} · ${formatDate(i.modified)}'),
            trailing: _trailing(i),
            onTap: () => _tap(i),
            onLongPress: widget.pickFileMode ? null : () => _toggle(i),
          );
        },
      );

  Widget _gridView() => GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 130, mainAxisSpacing: 4, crossAxisSpacing: 4),
        itemCount: _items.length,
        itemBuilder: (context, n) {
          final i = _items[n];
          final selected = _selected.contains(i.path);
          return InkWell(
            onTap: () => _tap(i),
            onLongPress: widget.pickFileMode ? null : () => _toggle(i),
            child: Container(
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(fit: StackFit.expand, children: [
                Center(child: _leading(i, size: 130)),
                if (!i.isDir && kindOf(i.name) == FileKind.video)
                  const Center(
                      child: Icon(Icons.play_circle, color: Colors.white70, size: 36)),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: Colors.black45,
                    padding: const EdgeInsets.all(4),
                    child: Text(i.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ),
                if (selected)
                  const Positioned(
                      top: 4, right: 4, child: Icon(Icons.check_circle)),
              ]),
            ),
          );
        },
      );
}

/// Miniatuur van een versleutelde foto (tijdelijk ontsleuteld in de cache).
class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ]),
        ),
      );
}
