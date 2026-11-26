import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../services/file_tools.dart';
import '../services/trash.dart';
import '../util/format.dart';
import '../widgets/dialogs.dart';

// --- Prullenbak ---------------------------------------------------------------

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});
  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<TrashItem>? _items;
  final _date = DateFormat('d MMM yyyy HH:mm', 'nl');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await services.trash.list(services.known.paths);
    if (mounted) setState(() => _items = items);
  }

  Future<void> _restore(TrashItem i) async {
    final ok = await runWithProgress(context, 'Terugzetten…', (_) async {
      await services.trash.restore(i);
      return true;
    });
    if (ok == true && mounted) showMessage(context, '"${i.name}" is teruggezet');
    await _load();
  }

  Future<void> _deleteForever(TrashItem i) async {
    final ok = await confirmDialog(context,
        title: 'Definitief verwijderen',
        message: '"${i.name}" kan daarna niet meer worden teruggezet.',
        confirm: 'Verwijderen',
        destructive: true);
    if (!ok) return;
    await services.trash.deleteForever(i);
    await _load();
  }

  Future<void> _empty() async {
    final items = _items ?? [];
    final ok = await confirmDialog(context,
        title: 'Prullenbak legen',
        message: '${items.length} item(s) definitief verwijderen?',
        confirm: 'Legen',
        destructive: true);
    if (!ok || !mounted) return;
    await runWithProgress(context, 'Legen…', (_) async {
      for (final i in items) {
        await services.trash.deleteForever(i);
      }
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Prullenbak'), actions: [
        if (items != null && items.isNotEmpty)
          IconButton(
              tooltip: 'Legen',
              icon: const Icon(Icons.delete_forever),
              onPressed: _empty),
      ]),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(
                  child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                      'De prullenbak is leeg.\nVerwijderde bestanden blijven hier '
                      '${Trash.keepDays} dagen staan.',
                      textAlign: TextAlign.center),
                ))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, n) {
                    final i = items[n];
                    final days = i.expires.difference(DateTime.now()).inDays;
                    return ListTile(
                      leading: Icon(i.isDir
                          ? Icons.folder
                          : (i.vaultRoot != null
                              ? Icons.lock
                              : iconFor(kindOf(i.name)))),
                      title: Text(i.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${p.dirname(i.original)}\nVerwijderd ${_date.format(i.deleted)} · '
                          'nog ${days < 0 ? 0 : days} dag(en)',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      isThreeLine: true,
                      trailing: PopupMenuButton<String>(
                        onSelected: (a) =>
                            a == 'terug' ? _restore(i) : _deleteForever(i),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'terug', child: Text('Terugzetten')),
                          PopupMenuItem(
                              value: 'weg', child: Text('Definitief verwijderen')),
                        ],
                      ),
                      onTap: () => _restore(i),
                    );
                  },
                ),
    );
  }
}

// --- Duplicaten ---------------------------------------------------------------

class DuplicatesScreen extends StatefulWidget {
  const DuplicatesScreen({super.key, required this.dir});
  final Directory dir;
  @override
  State<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends State<DuplicatesScreen> {
  List<List<FileInfo>>? _groups;
  String _status = 'Zoeken…';

  /// Paden die worden verwijderd (standaard alles behalve de oudste).
  final Set<String> _remove = {};

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final groups = await services.tools.findDuplicates(widget.dir,
        onProgress: (s) {
      if (mounted) setState(() => _status = s);
    });
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _remove
        ..clear()
        ..addAll([for (final g in groups) ...g.skip(1).map((f) => f.file.path)]);
    });
  }

  int get _saving => [
        for (final g in _groups ?? <List<FileInfo>>[])
          for (final f in g)
            if (_remove.contains(f.file.path)) f.size
      ].fold(0, (a, b) => a + b);

  Future<void> _delete() async {
    final files = _remove.map(File.new).toList();
    final ok = await confirmDialog(context,
        title: 'Duplicaten verwijderen',
        message: '${files.length} bestand(en) naar de prullenbak verplaatsen '
            '(${formatSize(_saving)})?',
        confirm: 'Verwijderen',
        destructive: true);
    if (!ok || !mounted) return;
    await runWithProgress(
        context, 'Verwijderen…', (_) => services.ops.delete(files));
    if (!mounted) return;
    showMessage(context, '${files.length} duplicaten in de prullenbak');
    setState(() => _groups = null);
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(title: Text('Duplicaten in ${p.basename(widget.dir.path)}')),
      bottomNavigationBar: groups == null || groups.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: _remove.isEmpty ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: Text('${_remove.length} verwijderen · '
                      '${formatSize(_saving)} vrij'),
                ),
              ),
            ),
      body: groups == null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(_status),
            ]))
          : groups.isEmpty
              ? const Center(child: Text('Geen duplicaten gevonden'))
              : ListView(children: [
                  for (final g in groups) ...[
                    ListTile(
                      dense: true,
                      title: Text('${g.length}× ${formatSize(g.first.size)}'),
                    ),
                    for (final f in g)
                      CheckboxListTile(
                        value: _remove.contains(f.file.path),
                        onChanged: (v) => setState(() => v == true
                            ? _remove.add(f.file.path)
                            : _remove.remove(f.file.path)),
                        secondary: Icon(
                            f.encrypted ? Icons.lock : iconFor(kindOf(f.name))),
                        title: Text(f.name, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            p.relative(f.file.parent.path, from: widget.dir.path),
                            overflow: TextOverflow.ellipsis),
                      ),
                    const Divider(),
                  ],
                ]),
    );
  }
}

// --- Opslaganalyse --------------------------------------------------------------

class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key, required this.dir});
  final Directory dir;
  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  StorageReport? _report;
  String _status = 'Tellen…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final r = await services.tools.analyze(widget.dir, onProgress: (s) {
      if (mounted) setState(() => _status = s);
    });
    if (mounted) setState(() => _report = r);
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('Opslag: ${p.basename(widget.dir.path)}')),
      body: r == null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(_status),
            ]))
          : ListView(children: [
              ListTile(
                title: Text(formatSize(r.total),
                    style: Theme.of(context).textTheme.headlineSmall),
                subtitle: Text('${r.files} bestanden'),
              ),
              if (r.dirs.isNotEmpty) ...[
                const ListTile(dense: true, title: Text('Mappen')),
                for (final d in r.dirs.take(40))
                  ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(p.basename(d.dir.path),
                        overflow: TextOverflow.ellipsis),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: LinearProgressIndicator(
                        value: r.total == 0 ? 0 : d.bytes / r.total,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                    trailing: Text(formatSize(d.bytes)),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => StorageScreen(dir: d.dir))),
                  ),
              ],
              if (r.largest.isNotEmpty) ...[
                const ListTile(dense: true, title: Text('Grootste bestanden')),
                for (final f in r.largest)
                  ListTile(
                    leading: Icon(
                        f.encrypted ? Icons.lock : iconFor(kindOf(f.name))),
                    title: Text(f.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        p.relative(f.file.parent.path, from: widget.dir.path),
                        overflow: TextOverflow.ellipsis),
                    trailing: Text(formatSize(f.size)),
                  ),
              ],
            ]),
    );
  }
}
