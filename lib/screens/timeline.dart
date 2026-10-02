import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/account.dart';
import '../models/custom_purpose.dart';
import '../models/purposes.dart';
import '../models/settings.dart';
import '../models/transaction.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import '../widgets/filter_sheet.dart';
import '../widgets/period_selector.dart';
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

  /// Search lookups: person id → name, and lowercased raw merchant →
  /// the user's own name for it. Search matches what the user SEES
  /// (alias, person, purpose label), not just the raw bank text.
  Map<String, String> _personNames = {};
  Map<String, String> _aliasByRaw = {};
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadLookups();
    // Renames / new purposes / new people made on other screens are
    // reflected here without reopening Activity.
    appState.addListener(_loadLookups);
  }

  Future<void> _loadLookups() async {
    final customs = await YaadDb.customPurposes();
    final accounts = await YaadDb.accounts();
    final people = await YaadDb.people();
    final aliases = await YaadDb.allAliases();
    if (!mounted) return;
    setState(() {
      _customs = customs;
      _allAccounts = accounts;
      _personNames = {for (final p in people) p.id: p.name};
      _aliasByRaw = {
        for (final a in aliases) a.rawName.trim().toLowerCase(): a.alias
      };
    });
  }

  @override
  void dispose() {
    appState.removeListener(_loadLookups);
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
    await _loadLookups();
  }

  /// Literal, case-insensitive match against everything the row
  /// shows: bank text, note, purpose id AND label, the user's own
  /// name for the shop, and the person's name. Done in Dart (not SQL
  /// LIKE) so "%" and "_" typed by the user stay literal characters
  /// instead of wildcards that match everything. A purely numeric
  /// query also matches the amount.
  bool _matchesQuery(YaadTransaction t, String q) {
    bool hit(String? v) => v != null && v.toLowerCase().contains(q);
    if (hit(t.rawMerchant) || hit(t.note) || hit(t.purpose)) return true;
    if (hit(purposeLabel(t.purpose))) return true;
    if (hit(_aliasByRaw[t.rawMerchant.trim().toLowerCase()])) return true;
    if (t.personId != null && hit(_personNames[t.personId])) return true;
    if (RegExp(r'^\d+$').hasMatch(q) &&
        t.amount.toStringAsFixed(0).contains(q)) {
      return true;
    }
    return false;
  }

  Future<List<YaadTransaction>> _loadTxns() async {
    // The shared viewing period composes with every other filter:
    // period AND purposes AND accounts AND direction AND search.
    final (fromMs, toMs) = appState.periodRangeMs();
    var items = await YaadDb.txns(
      limit: 500,
      purposes: _purposes.isEmpty ? null : _purposes,
      accountIds: _accounts.isEmpty ? null : _accounts,
      fromMs: fromMs,
      toMs: toMs,
    );
    if (_direction != null) {
      items = items.where((t) => t.direction == _direction).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items.where((t) => _matchesQuery(t, q)).toList();
    }
    return items;
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
            // The shared viewing period (same one Home/Summary use).
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: const PeriodSelector(),
              ),
            ),
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
                future: _loadTxns(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return YaadErrorState(
                      message: '${snap.error}',
                      onRetry: () => appState.refresh(),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }
                  final items = snap.data!;
                  if (items.isEmpty) {
                    return _emptyState(s);
                  }
                  return ListView.builder(
                    // Bottom clearance for the shell's "+ Add" FAB
                    // (a tab screen): the last card must be able to
                    // scroll fully clear of it.
                    padding: const EdgeInsets.only(bottom: 96),
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
    if (!filtering &&
        appState.settings.period != AppSettings.periodThisMonth) {
      // A past/empty period is not an empty app: say which period is
      // empty and offer the way back to this month.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.x3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.calendar_month_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: Gap.x1),
              Text(
                  s
                      .get('noTxnsInPeriod')
                      .replaceFirst('{period}', appState.periodLabel()),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: Gap.x1),
              TextButton(
                onPressed: () => appState.update(appState.settings
                    .copyWith(period: AppSettings.periodThisMonth)),
                child: Text(s.get('thisMonth')),
              ),
            ],
          ),
        ),
      );
    }
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
