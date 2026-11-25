import 'package:flutter/material.dart';

Future<String?> askText(BuildContext context,
    {required String title,
    String initial = '',
    String label = 'Naam',
    String confirm = 'OK'}) {
  final c = TextEditingController(text: initial);
  // Selecteer de naam zonder extensie.
  final dot = initial.lastIndexOf('.');
  c.selection =
      TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Annuleren')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(confirm)),
      ],
    ),
  );
}

Future<bool> confirmDialog(BuildContext context,
    {required String title,
    required String message,
    String confirm = 'OK',
    bool destructive = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuleren')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Wachtwoord vragen; met [repeat] moet het twee keer worden ingevoerd.
Future<String?> askPassword(BuildContext context,
    {required String title, bool repeat = false, String? message}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _PasswordDialog(title: title, repeat: repeat, message: message),
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog(
      {required this.title, required this.repeat, this.message});
  final String title;
  final bool repeat;
  final String? message;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _hide = true;
  String? _error;

  void _submit() {
    if (_a.text.isEmpty) {
      setState(() => _error = 'Vul een wachtwoord in');
      return;
    }
    if (widget.repeat) {
      if (_a.text.length < 6) {
        setState(() => _error = 'Gebruik minstens 6 tekens');
        return;
      }
      if (_a.text != _b.text) {
        setState(() => _error = 'Wachtwoorden komen niet overeen');
        return;
      }
    }
    Navigator.pop(context, _a.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _a,
            autofocus: true,
            obscureText: _hide,
            decoration: InputDecoration(
              labelText: 'Wachtwoord',
              suffixIcon: IconButton(
                icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hide = !_hide),
              ),
            ),
            onSubmitted: (_) => widget.repeat ? null : _submit(),
          ),
          if (widget.repeat)
            TextField(
              controller: _b,
              obscureText: _hide,
              decoration:
                  const InputDecoration(labelText: 'Herhaal wachtwoord'),
              onSubmitted: (_) => _submit(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuleren')),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}

/// Voert [task] uit met een blokkerende voortgangsdialoog.
Future<T?> runWithProgress<T>(
  BuildContext context,
  String title,
  Future<T> Function(void Function(String status) update) task,
) async {
  final status = ValueNotifier<String>('');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, s, _) =>
                  Text(s, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          ),
        ]),
      ),
    ),
  );
  final nav = Navigator.of(context, rootNavigator: true);
  try {
    return await task((s) => status.value = s);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  } finally {
    nav.pop();
    status.dispose();
  }
}

void showError(BuildContext context, Object e) {
  var msg = e.toString();
  for (final prefix in ['Bad state: ', 'Invalid argument(s): ', 'Exception: ']) {
    if (msg.startsWith(prefix)) msg = msg.substring(prefix.length);
  }
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

void showMessage(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
