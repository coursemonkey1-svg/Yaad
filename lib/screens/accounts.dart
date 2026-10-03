import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  Map<String, double> _balances = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final accounts = await YaadDb.accounts();
    final counts = await YaadDb.txnCountsByAccount();
    final balances = await YaadDb.accountBalances();
    if (!mounted) return;
    // The default must always point at a real account (e.g. a restore
    // or an old settings row referencing a deleted id).
    final def = resolveDefaultAccountId(
        accounts, appState.settings.defaultAccountId);
    if (def != appState.settings.defaultAccountId) {
      await appState.update(
          appState.settings.copyWith(defaultAccountId: def));
      if (!mounted) return;
    }
    setState(() {
      _accounts = accounts;
      _counts = counts;
      _balances = balances;
      _loading = false;
    });
  }

  double get _totalBalance =>
      _balances.values.fold(0.0, (a, b) => a + b);

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
    if (!mounted) return;
    setState(() {});
  }

  /// Add or rename (+ opening balance). Returns the trimmed name and
  /// the raw opening-balance text, or null when cancelled.
  /// The dialog is a StatefulWidget that owns (and disposes) its
  /// controllers — disposing them here, right after the dialog
  /// future completes, crashes the exit animation: the field rebuilds
  /// once more while the dialog slides out ("used after disposed").
  Future<({String name, String opening})?> _promptAccount(Strings s,
      {String? initialName,
      double initialOpening = 0,
      required String title}) {
    return showDialog<({String name, String opening})>(
      context: context,
      builder: (_) => _AccountDialog(
        title: title,
        nameHint: s.get('accountNameHint'),
        initialName: initialName,
        openingLabel: s.get('openingBalance'),
        openingHint: s.get('openingBalanceHint'),
        initialOpening: initialOpening == 0
            ? ''
            : initialOpening.toStringAsFixed(
                initialOpening.truncateToDouble() == initialOpening
                    ? 0
                    : 2),
        currency: appState.settings.currency,
        cancelLabel: s.get('cancel'),
        saveLabel: s.get('save'),
      ),
    );
  }

  /// Parses the opening-balance field: blank = 0, negatives allowed
  /// (an account can be overdrawn), non-numeric = null (refused).
  double? _parseOpening(String text) {
    final clean = text.trim().replaceAll(',', '');
    if (clean.isEmpty) return 0;
    return double.tryParse(clean);
  }

  Future<void> _add(Strings s) async {
    final result = await _promptAccount(s, title: s.get('addAccount'));
    if (result == null || !mounted) return;
    final name = result.name;
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('emptyAccountName'))));
      return;
    }
    final opening = _parseOpening(result.opening);
    if (opening == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('invalidOpening'))));
      return;
    }
    try {
      final a = await YaadDb.insertAccount(name, openingBalance: opening);
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
    final result = await _promptAccount(s,
        initialName: a.name,
        initialOpening: a.openingBalance,
        title: s.get('rename'));
    if (result == null || !mounted) return;
    final name = result.name;
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('emptyAccountName'))));
      return;
    }
    final opening = _parseOpening(result.opening);
    if (opening == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('invalidOpening'))));
      return;
    }
    final nameChanged = name != a.name;
    final openingChanged = (opening - a.openingBalance).abs() > 0.005;
    // Nothing changed: a no-op. (Renaming a seeded account to its
    // own stored name would flip `customName` and freeze its
    // localised label (e.g. "میزان") to the English word forever.)
    if (!nameChanged && !openingChanged) return;
    try {
      if (nameChanged) await YaadDb.renameAccount(a.id, name);
      if (openingChanged) {
        await YaadDb.setOpeningBalance(a.id, opening);
      }
      if (!mounted) return;
      await _reload();
      if (nameChanged) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(s
                .get('accountRenamed')
                .replaceFirst('{name}', name))));
      }
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
                padding: const EdgeInsets.fromLTRB(
                    Gap.x2, Gap.x2, Gap.x2, Gap.x4),
                children: [
                  Text(s.get('defaultAccountSub'),
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: Gap.x1),
                  // Total across every account — the same figure
                  // Home's Balance card shows.
                  Row(
                    children: [
                      Text(s.get('totalBalance'),
                          style: const TextStyle(
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(appState.money(_totalBalance),
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
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
      String defId) {    final isDefault = a.id == defId;
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
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(appState.money(_balances[a.id] ?? a.openingBalance),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14.5)),
            Text(
              '${s.get('accountTxns').replaceFirst('{n}', '$n')}'
              '${isDefault ? ' · ${s.get('defaultAccount')}' : ''}',
            ),
          ],
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

/// The add/rename account dialog: name + optional opening balance.
/// Owns its text controllers and disposes them in [State.dispose] —
/// i.e. only once the dialog route (and its exit animation) is fully
/// gone. Pops a (name, openingText) record, or null when cancelled;
/// the caller parses/validates the opening text.
class _AccountDialog extends StatefulWidget {
  final String title;
  final String nameHint;
  final String? initialName;
  final String openingLabel;
  final String openingHint;
  final String initialOpening;
  final String currency;
  final String cancelLabel;
  final String saveLabel;
  const _AccountDialog({
    required this.title,
    required this.nameHint,
    required this.initialName,
    required this.openingLabel,
    required this.openingHint,
    required this.initialOpening,
    required this.currency,
    required this.cancelLabel,
    required this.saveLabel,
  });

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.initialName ?? '');
  late final TextEditingController _openingCtrl =
      TextEditingController(text: widget.initialOpening);

  @override
  void dispose() {
    _nameCtrl.dispose();
    _openingCtrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context)
      .pop((name: _nameCtrl.text.trim(), opening: _openingCtrl.text));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: widget.nameHint,
              border: const OutlineInputBorder(),
            ),
            // A name is a tag on every transaction card — cap it so a
            // pasted paragraph can't wreck every list in the app.
            maxLength: 40,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: Gap.x1),
          TextField(
            controller: _openingCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true, signed: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,-]'))
            ],
            decoration: InputDecoration(
              labelText: widget.openingLabel,
              hintText: widget.openingHint,
              prefixText: '${widget.currency} ',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.cancelLabel)),
        FilledButton(
            onPressed: _submit, child: Text(widget.saveLabel)),
      ],
    );
  }
}
