import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/account.dart';
import '../models/custom_purpose.dart';
import '../models/settings.dart';
import '../models/transaction.dart';
import '../theme.dart';
import '../widgets/filter_sheet.dart';
import 'home.dart';

/// Transaction timeline with search and filters.
/// Filters combine: direction AND (any selected purpose)
/// AND (any selected account) AND search text.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key});
  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  String _query = '';
  Set<String> _purposes = {};
  Set<String> _accounts = {};
  TxnDirection? _direction;
  List<CustomPurpose> _customs = [];
  List<Account> _allAccounts = [];
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCustoms();
    _loadAccounts();
  }

  Future<void> _loadCustoms() async {
    final customs = await YaadDb.customPurposes();
    if (!mounted) return;
    setState(() => _customs = customs);
  }

  Future<void> _loadAccounts() async {
    final accounts = await YaadDb.accounts();
    if (!mounted) return;
    setState(() => _allAccounts = accounts);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  int get _activeCount =>
      _purposes.length + (_direction != null ? 1 : 0) + _accounts.length;

  Future<void> _openFilters() async {
    final s = Strings(appState.settings.language);
    await showActivityFilterSheet(
      context,
      s: s,
      initialPurposes: _purposes,
      initialDirection: _direction,
      initialAccounts: _accounts,
      customs: _customs,
      accounts: _allAccounts,
      onChanged: (sel) => setState(() {
        _purposes = sel.purposes;
        _direction = sel.direction;
        _accounts = sel.accountIds;
      }),
    );
    // A custom purpose may have been deleted inside the sheet.
    await _loadCustoms();
  }

  void _clearAll(Strings s) {
    _searchCtrl.clear();
    setState(() {
      _query = '';
      _purposes = {};
      _direction = null;
      _accounts = {};
    });
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.get('filtersCleared'))));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(s.get('activity'))),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: s.get('search'),
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _filtersButton(s),
                  const Spacer(),
                  _viewToggle(s),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<YaadTransaction>>(
                future: YaadDb.txns(
                  limit: 500,
                  query: _query.isEmpty ? null : _query,
                  purposes: _purposes.isEmpty ? null : _purposes,
                  accountIds: _accounts.isEmpty ? null : _accounts,
                ),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }
                  var items = snap.data!;
                  if (_direction != null) {
                    items = items
                        .where((t) => t.direction == _direction)
                        .toList();
                  }
                  if (items.isEmpty) {
                    return _emptyState(s);
                  }
                  return ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) => TxnRow(
                      txn: items[i],
                      compact: appState.settings.activityView ==
                          AppSettings.viewCompact,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filtersButton(Strings s) {
    final button = OutlinedButton.icon(
      onPressed: _openFilters,
      icon: const Icon(Icons.filter_list),
      label: Text(s.get('filters')),
    );
    final n = _activeCount;
    if (n == 0) return button;
    return Badge(label: Text('$n'), child: button);
  }

  /// Detailed vs Compact list density. Persisted in [AppSettings].
  Widget _viewToggle(Strings s) {
    return SegmentedButton<String>(
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 12),
      ),
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: AppSettings.viewDetailed,
          label: Text(s.get('viewDetailed')),
          icon: const Icon(Icons.view_agenda_outlined, size: 16),
        ),
        ButtonSegment(
          value: AppSettings.viewCompact,
          label: Text(s.get('viewCompact')),
          icon: const Icon(Icons.view_list_outlined, size: 16),
        ),
      ],
      selected: {appState.settings.activityView},
      onSelectionChanged: (sel) => appState.update(
        appState.settings.copyWith(activityView: sel.first),
      ),
    );
  }

  /// Never a blank screen: the empty state says what to do next.
  Widget _emptyState(Strings s) {
    final filtering = _purposes.isNotEmpty ||
        _direction != null ||
        _accounts.isNotEmpty ||
        _query.isNotEmpty;
    if (!filtering) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.x3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.get('noTransactions')),
              const SizedBox(height: 4),
              Text(s.get('activityEmptySub'),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.x3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 40,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: Gap.x1),
            Text(s.get('noMatchFilters'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(s.get('tryClearing'),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.x1),
            TextButton(
                onPressed: () => _clearAll(s),
                child: Text(s.get('clearAll'))),
          ],
        ),
      ),
    );
  }
}
