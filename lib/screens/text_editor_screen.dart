import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../services/memory_files.dart';
import '../widgets/dialogs.dart';

/// Tekstbestanden die in de app worden geopend.
bool isTextFile(String name) {
  final n = name.toLowerCase();
  return const [
    '.txt', '.md', '.log', '.csv', '.json', '.xml', '.ini', '.conf',
    '.yaml', '.yml', '.html', '.htm', '.css', '.js', '.dart', '.py',
  ].any(n.endsWith);
}

/// Notities en tekstbestanden bekijken en bewerken, ook in een kluis.
/// De tekst wordt alleen in het geheugen ontsleuteld.
class TextEditorScreen extends StatefulWidget {
  const TextEditorScreen({super.key, required this.file, required this.name});

  final File file;
  final String name;

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> {
  final _text = TextEditingController();
  String _saved = '';
  bool _loading = true;
  bool _editing = false;
  String? _error;

  bool get _dirty => _text.text != _saved;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await MemoryFiles.readText(
          widget.file, services.ops.keyForFile(widget.file));
      if (!mounted) return;
      setState(() {
        _saved = s;
        _text.text = s;
        _loading = false;
        _editing = s.isEmpty;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<bool> _save() async {
    try {
      await MemoryFiles.writeText(
          widget.file, _text.text, services.ops.keyForFile(widget.file));
      if (!mounted) return true;
      setState(() => _saved = _text.text);
      showMessage(context, 'Opgeslagen');
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final save = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Wijzigingen opslaan?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Niet opslaan')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Opslaan')),
            ],
          ),
        );
        if (save == null || !context.mounted) return;
        if (save && !await _save()) return;
        if (!save) _text.text = _saved;
        if (context.mounted) Navigator.pop(context, true);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.name, overflow: TextOverflow.ellipsis),
          actions: [
            if (!_loading && _error == null && !_editing)
              IconButton(
                  tooltip: 'Bewerken',
                  icon: const Icon(Icons.edit),
                  onPressed: () => setState(() => _editing = true)),
            if (_editing)
              IconButton(
                  tooltip: 'Opslaan',
                  icon: const Icon(Icons.save),
                  onPressed: _dirty ? _save : null),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(
                    padding: const EdgeInsets.all(24), child: Text(_error!)))
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      controller: _text,
                      readOnly: !_editing,
                      autofocus: _editing && _saved.isEmpty,
                      maxLines: null,
                      expands: true,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontSize: 15, height: 1.4),
                      decoration: const InputDecoration(
                          border: InputBorder.none, hintText: 'Typ je notitie…'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
      ),
    );
  }
}
