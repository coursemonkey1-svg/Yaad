import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../models/account.dart';
import '../models/custom_purpose.dart';
import '../models/purposes.dart';
import '../models/transaction.dart';
import '../theme.dart';
import 'purpose_dialogs.dart';

/// The current filter state. Purposes and accounts are multi-select;
/// direction stays single-select (All / Money out / Money in).
/// Filters combine: direction AND (any selected purpose)
/// AND (any selected account) AND search text.
class FilterSelection {
  final Set<String> purposes;
  final TxnDirection? direction;
  final Set<String> accountIds;

  const FilterSelection(
      {this.purposes = const {}, this.direction, this.accountIds = const {}});

  bool get isEmpty =>
      purposes.isEmpty && direction == null && accountIds.isEmpty;

  int get activeCount =>
      purposes.length + (direction != null ? 1 : 0) + accountIds.length;
}

/// Bottom sheet with the Activity filters. Applies live: every toggle
/// calls [onChanged] immediately so the list behind the sheet updates
/// while it is still open.
///
/// Sections: Direction (single) → Purpose (multi) → My purposes (multi,
/// long-press to delete) → Received from (multi) → Account (multi) →
/// Clear all.
class ActivityFilterSheet extends StatefulWidget {
  final Strings s;
  final Set<String> initialPurposes;
  final TxnDirection? initialDirection;
  final Set<String> initialAccounts;
  final List<CustomPurpose> customs;
  final List<Account> accounts;
  final ValueChanged<FilterSelection> onChanged;

  const ActivityFilterSheet({
    super.key,
    required this.s,
    required this.initialPurposes,
    required this.initialDirection,
    required this.initialAccounts,
    required this.customs,
    required this.accounts,
    required this.onChanged,
  });

  @override
  State<ActivityFilterSheet> createState() => _ActivityFilterSheetState();
}

class _ActivityFilterSheetState extends State<ActivityFilterSheet> {
  late Set<String> _purposes;
  late TxnDirection? _direction;
  late Set<String> _accounts;
  late List<CustomPurpose> _customs;

  @override
  void initState() {
    super.initState();
    _purposes = Set.of(widget.initialPurposes);
    _direction = widget.initialDirection;
    _accounts = Set.of(widget.initialAccounts);
    _customs = List.of(widget.customs);
  }

  void _emit() => widget.onChanged(FilterSelection(
      purposes: Set.of(_purposes),
      direction: _direction,
      accountIds: Set.of(_accounts)));

  void _togglePurpose(String id) {
    setState(() {
      if (_purposes.contains(id)) {
        _purposes.remove(id);
      } else {
        _purposes.add(id);
      }
    });
    _emit();
  }

  void _toggleAccount(String id) {
    setState(() {
      if (_accounts.contains(id)) {
        _accounts.remove(id);
      } else {
        _accounts.add(id);
      }
    });
    _emit();
  }

  void _setDirection(TxnDirection? d) {
    setState(() => _direction = _direction == d ? null : d);
    _emit();
  }

  void _clearAll() {
    setState(() {
      _purposes.clear();
      _direction = null;
      _accounts.clear();
    });
    _emit();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.s.get('filtersCleared'))));
  }

  Future<void> _confirmDeleteCustom(CustomPurpose cp) async {
    final s = widget.s;
    final ok = await confirmDeleteCustomPurpose(context, s, cp.label);
    if (!ok || !mounted) return;
    await YaadDb.deleteCustomPurpose(cp.id);
    setState(() {
      _customs.removeWhere((c) => c.id == cp.id);
      _purposes.remove(cp.id);
    });
    _emit();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            s.get('purposeDeleted').replaceFirst('{name}', cp.label))));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x1, Gap.x1, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(s.get('filters'),
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                TextButton(
                    onPressed: _clearAll, child: Text(s.get('clearAll'))),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  Gap.x2, Gap.x1, Gap.x2, Gap.x3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sectionTitle(s.get('direction')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _dirChip(null, s.get('all'), null),
                      _dirChip(TxnDirection.out, s.get('moneyOut'),
                          Icons.north_east),
                      _dirChip(TxnDirection.incoming, s.get('moneyIn'),
                          Icons.south_west),
                    ],
                  ),
                  _sectionTitle(s.get('purpose')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in kSpendPurposes)
                        _purposeChip(p.id, p.label, p.icon),
                    ],
                  ),
                  _sectionTitle(s.get('myPurposes')),
                  if (_customs.isEmpty)
                    Text(s.get('noCustomHint'),
                        style: Theme.of(context).textTheme.bodySmall)
                  else ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in _customs)
                          GestureDetector(
                            onLongPress: () => _confirmDeleteCustom(c),
                            child: _purposeChip(c.id, c.label, Icons.tag),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(s.get('longPressHint'),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                  _sectionTitle(s.get('source')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in kReceiveSources)
                        _purposeChip(p.id, p.label, p.icon),
                    ],
                  ),
                  _sectionTitle(s.get('accountFilter')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final a in widget.accounts)
                        _accountChip(a),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: Gap.x2, bottom: Gap.x1),
        child: Text(text,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Widget _dirChip(TxnDirection? d, String label, IconData? icon) {
    return FilterChip(
      label: Text(label),
      avatar: icon == null ? null : Icon(icon, size: 18),
      selected: _direction == d,
      onSelected: (_) => _setDirection(d),
    );
  }

  Widget _purposeChip(String id, String label, IconData icon) {
    return FilterChip(
      label: Text(label),
      avatar: Icon(icon, size: 18),
      selected: _purposes.contains(id),
      onSelected: (_) => _togglePurpose(id),
    );
  }

  Widget _accountChip(Account a) {
    return FilterChip(
      label: Text(a.displayName(widget.s)),
      avatar:
          const Icon(Icons.account_balance_wallet_outlined, size: 18),
      selected: _accounts.contains(a.id),
      onSelected: (_) => _toggleAccount(a.id),
    );
  }
}

/// Opens the filter sheet. Small-screen safe: scroll-controlled and the
/// content scrolls inside a bounded height.
Future<void> showActivityFilterSheet(
  BuildContext context, {
  required Strings s,
  required Set<String> initialPurposes,
  required TxnDirection? initialDirection,
  required Set<String> initialAccounts,
  required List<CustomPurpose> customs,
  required List<Account> accounts,
  required ValueChanged<FilterSelection> onChanged,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.88,
      child: ActivityFilterSheet(
        s: s,
        initialPurposes: initialPurposes,
        initialDirection: initialDirection,
        initialAccounts: initialAccounts,
        customs: customs,
        accounts: accounts,
        onChanged: onChanged,
      ),
    ),
  );
}
