import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/account.dart';
import '../theme.dart';

/// Manage money accounts: add, rename, delete, pick the default.
/// Deleting an account NEVER deletes or orphans transactions — they
/// move to the default account (or the new default, when the deleted
/// one was default). The last account cannot be deleted.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  List<Account> _accounts = [];
  Map<String, int> _counts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final accounts = await YaadDb.accounts();
    final counts = await YaadDb.txnCountsByAccount();
    if (!mounted) return;
    // The default must always point at a real account (e.g. a restore
    // or an old settings row referencing a deleted id).
    final def = resolveDefaultAccountId(
        accounts, appState.settings.defaultAccountId);
    if (def != appState.settings.defaultAccountId) {
      await appState.update(
          appState.settings.copyWith(defaultAccountId: def));
    }
    setState(() {
      _accounts = accounts;
      _counts = counts;
      _loading = false;
    });
  }

  String _label(Account a, Strings s) => a.displayName(s);

  String _labelFor(String id, Strings s) {
    for (final a in _accounts) {
      if (a.id == id) return _label(a, s);
    }
    return id;
  }

  Future<void> _setDefault(Account a) async {
    final settings = appState.settings;
    if (settings.defaultAccountId == a.id) return;
    await appState.update(settings.copyWith(defaultAccountId: a.id));
    setState(() {});
  }

  /// Add or rename. Returns the trimmed name, or null when cancelled.
  Future<String?> _promptName(Strings s,
      {String? initial, required String title}) async {
    final ctrl = TextEditingController(text: initial ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            hintText: s.get('accountNameHint'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) =>
              Navigator.of(ctx).pop(ctrl.text.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(s.get('cancel'))),
          FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(ctrl.text.trim()),
              child: Text(s.get('save'))),
        ],
      ),
    );
    ctrl.dispose();
    return name;
  }

  Future<void> _add(Strings s) async {
    final name = await _promptName(s, title: s.get('addAccount'));
    if (name == null || !mounted) return;
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('emptyAccountName'))));
      return;
    }
    try {
      final a = await YaadDb.insertAccount(name);
      if (!mounted) return;
      await _reload();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s
              .get('accountAdded')
              .replaceFirst('{name}', _label(a, s)))));
    } on StateError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('accountExists'))));
    }
  }

  Future<void> _rename(Strings s, Account a) async {
    final name = await _promptName(s,
        initial: a.name, title: s.get('rename'));
    if (name == null || !mounted) return;
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('emptyAccountName'))));
      return;
    }
    try {
      await YaadDb.renameAccount(a.id, name);
      if (!mounted) return;
      await _reload();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s
              .get('accountRenamed')
              .replaceFirst('{name}', name))));
    } on StateError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('accountExists'))));
    }
  }

  Future<void> _delete(Strings s, Account a) async {
    if (_accounts.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('atLeastOneAccount'))));
      return;
    }
    final settings = appState.settings;
    var reassignTo = settings.defaultAccountId;
    if (a.id == reassignTo) {
      // Deleting the default: the oldest surviving account becomes
      // the new default so nothing is left without one.
      reassignTo = resolveDefaultAccountId(
          _accounts.where((x) => x.id != a.id).toList(), '');
    }
    final n = _counts[a.id] ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.get('deleteAccountTitle')),
        content: Text(s
            .get('deleteAccountBody')
            .replaceFirst('{name}', _label(a, s))
            .replaceFirst('{default}', _labelFor(reassignTo, s))
            .replaceFirst('{n}', '$n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(s.get('cancel'))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(s.get('delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await YaadDb.deleteAccount(a.id, reassignTo: reassignTo);
    await appState.update(
        appState.settings.copyWith(defaultAccountId: reassignTo));
    if (!mounted) return;
    await _reload();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s
            .get('accountDeleted')
            .replaceFirst('{name}', _label(a, s))
            .replaceFirst('{default}', _labelFor(reassignTo, s)))));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    final defId = appState.settings.defaultAccountId;
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(s.get('accounts'))),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(Gap.x2),
                children: [
                  Text(s.get('defaultAccountSub'),
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: Gap.x1),
                  for (final a in _accounts) _row(context, s, cs, a, defId),
                  const SizedBox(height: Gap.x2),
                  FilledButton.tonalIcon(
                    onPressed: () => _add(s),
                    icon: const Icon(Icons.add),
                    label: Text(s.get('addAccount')),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52)),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _row(BuildContext context, Strings s, ColorScheme cs, Account a,
      String defId) {
    final isDefault = a.id == defId;
    final n = _counts[a.id] ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.x1),
      child: ListTile(
        leading: Icon(
          isDefault
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
          color: isDefault ? cs.primary : cs.onSurfaceVariant,
        ),
        title: Text(_label(a, s),
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${s.get('accountTxns').replaceFirst('{n}', '$n')}'
          '${isDefault ? ' · ${s.get('defaultAccount')}' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: s.get('rename'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _rename(s, a),
            ),
            IconButton(
              tooltip: s.get('delete'),
              icon: Icon(Icons.delete_outline,
                  color: cs.error.withValues(alpha: 0.85)),
              onPressed: () => _delete(s, a),
            ),
          ],
        ),
        onTap: () => _setDefault(a),
      ),
    );
  }
}
