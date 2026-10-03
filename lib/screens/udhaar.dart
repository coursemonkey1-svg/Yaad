import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/person.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import 'borrow.dart';
import 'lend.dart';
import 'person_detail.dart';

/// The Udhaar tab: who owes you, who you owe — in plain words (§5).
/// Searchable, calm when settled, with one-tap I-lent / I-borrowed.
class UdhaarScreen extends StatefulWidget {
  const UdhaarScreen({super.key});

  @override
  State<UdhaarScreen> createState() => _UdhaarScreenState();
}

class _UdhaarScreenState extends State<UdhaarScreen> {
  final _searchCtrl = TextEditingController();
  _UdhaarDirection _dirFilter = _UdhaarDirection.all;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleDirectionFilter(_UdhaarDirection dir) {
    setState(() {
      _dirFilter = _dirFilter == dir ? _UdhaarDirection.all : dir;
    });
  }

  Future<List<_PersonBalance>> _load() async {
    final people = await YaadDb.people();
    final out = <_PersonBalance>[];
    for (final p in people) {
      final records = await YaadDb.lendingForPerson(p.id);
      double owedToMe = 0, iOwe = 0;
      for (final l in records) {
        if (l.status == LendingStatus.settled ||
            l.status == LendingStatus.writtenOff ||
            l.status == LendingStatus.gift) {
          continue;
        }
        final repaid = await YaadDb.totalRepaid(l.id);
        final remaining = l.originalAmount - repaid;
        if (remaining <= 0.005) continue;
        if (l.isOwedToMe) {
          owedToMe += remaining;
        } else {
          iOwe += remaining;
        }
      }
      out.add(_PersonBalance(p, owedToMe, iOwe));
    }
    // Active balances first, then settled.
    out.sort((a, b) => (b.owedToMe + b.iOwe)
        .compareTo(a.owedToMe + a.iOwe));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(s.get('udhaar'))),
        body: FutureBuilder<List<_PersonBalance>>(
          future: _load(),
          builder: (context, snap) {
            if (snap.hasError) {
              return YaadErrorState(
                  message: '${snap.error}',
                  onRetry: () => appState.refresh());
            }
            if (!snap.hasData) return const YaadLoading();
            final all = snap.data!;
            final q = _searchCtrl.text.trim().toLowerCase();
            final items = all.where((b) {
              switch (_dirFilter) {
                case _UdhaarDirection.owedToMe:
                  if (b.owedToMe <= 0.005) return false;
                case _UdhaarDirection.iOwe:
                  if (b.iOwe <= 0.005) return false;
                case _UdhaarDirection.all:
                  break;
              }
              return q.isEmpty ||
                  b.person.name.toLowerCase().contains(q);
            }).toList();
            final owedToMe =
                all.fold<double>(0, (t, b) => t + b.owedToMe);
            final iOwe = all.fold<double>(0, (t, b) => t + b.iOwe);

            return RefreshIndicator(
              onRefresh: () async => appState.refresh(),
              child: ListView(
                // Bottom padding clears the shell's extended FAB —
                // Home and Activity already pad for it; without it
                // the last person's row sat hidden under the button.
                padding:
                    const EdgeInsets.fromLTRB(Gap.x2, Gap.x2, Gap.x2, 96),
                children: [
                  // Totals header.
                  Row(
                    children: [
                      Expanded(
                        child: _TotalCard(
                          label: s.get('peopleOweYou'),
                          amount: owedToMe,
                          color: Colors.green,
                          selected:
                              _dirFilter == _UdhaarDirection.owedToMe,
                          onTap: () => _toggleDirectionFilter(
                              _UdhaarDirection.owedToMe),
                        ),
                      ),
                      const SizedBox(width: Gap.x1 + 4),
                      Expanded(
                        child: _TotalCard(
                          label: s.get('youOwe'),
                          amount: iOwe,
                          color: cs.error,
                          selected: _dirFilter == _UdhaarDirection.iOwe,
                          onTap: () => _toggleDirectionFilter(
                              _UdhaarDirection.iOwe),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.x2),
                  // Actions.
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => Navigator.of(context)
                              .push(MaterialPageRoute(
                                  builder: (_) => const LendScreen()))
                              .then((_) => appState.refresh()),
                          icon: const Icon(Icons.north_east),
                          label: Text(s.get('iLent')),
                        ),
                      ),
                      const SizedBox(width: Gap.x1 + 4),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () => Navigator.of(context)
                              .push(MaterialPageRoute(
                                  builder: (_) =>
                                      const BorrowScreen()))
                              .then((_) => appState.refresh()),
                          icon: const Icon(Icons.south_west),
                          label: Text(s.get('iBorrowed')),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.x2),
                  // Search.
                  TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: s.get('searchPeople'),
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: Gap.x1),
                  if (items.isEmpty && all.isEmpty)
                    YaadEmptyState(
                      icon: Icons.handshake_outlined,
                      title: s.get('noUdhaarYetTitle'),
                      body: s.get('noUdhaarYetBody'),
                    )
                  else if (items.isEmpty &&
                      _dirFilter != _UdhaarDirection.all)
                    YaadEmptyState(
                      icon: _dirFilter == _UdhaarDirection.owedToMe
                          ? Icons.north_east
                          : Icons.south_west,
                      title: s.get(_dirFilter == _UdhaarDirection.owedToMe
                          ? 'filterOweYouEmptyTitle'
                          : 'filterYouOweEmptyTitle'),
                      body: s.get(_dirFilter == _UdhaarDirection.owedToMe
                          ? 'filterOweYouEmptyBody'
                          : 'filterYouOweEmptyBody'),
                      actionLabel: s.get('clearFilter'),
                      onAction: () => setState(() {
                        _dirFilter = _UdhaarDirection.all;
                      }),
                    )
                  else if (items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(Gap.x3),
                      child: Text(s.get('noMatch'),
                          textAlign: TextAlign.center),
                    ),
                  for (final b in items) _PersonRow(balance: b),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Tapped balance-card filter for the Udhaar people list (§5):
/// tap "People owe you" to see only people who owe you, tap "You owe"
/// for only people you owe, tap the active card again to clear.
enum _UdhaarDirection { all, owedToMe, iOwe }

class _PersonBalance {
  final Person person;
  final double owedToMe, iOwe;
  double get net => owedToMe - iOwe;
  _PersonBalance(this.person, this.owedToMe, this.iOwe);
}

class _TotalCard extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _TotalCard({
    required this.label,
    required this.amount,
    required this.color,
    this.selected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radius.tile));
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? color.withValues(alpha: 0.14)
            : cs.surfaceContainerHighest.withValues(alpha: 0.6),
        shape: shape,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: Container(
            padding: const EdgeInsets.all(Gap.x2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radius.tile),
              border: Border.all(
                color: selected ? color : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style:
                              Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 4),
                      MoneyText(amount, size: 20, color: color),
                    ],
                  ),
                ),
                if (selected)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 4),
                    child: Icon(Icons.check_circle,
                        color: color, size: 20),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  final _PersonBalance balance;
  const _PersonRow({required this.balance});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final net = balance.net;
    final String line;
    final Color color;
    if (net > 0.005) {
      // "Ahmed owes you Rs 2,000"
      line = s
          .get('owesYouLine')
          .replaceFirst('{name}', balance.person.name)
          .replaceFirst('{amount}', appState.money(net));
      color = Colors.green;
    } else if (net < -0.005) {
      // "You owe Sara Rs 500"
      line = s
          .get('youOweLine')
          .replaceFirst('{name}', balance.person.name)
          .replaceFirst('{amount}', appState.money(-net));
      color = Theme.of(context).colorScheme.error;
    } else {
      // "Settled with Bilal"
      line =
          s.get('settledWith').replaceFirst('{name}', balance.person.name);
      color = Theme.of(context).colorScheme.onSurfaceVariant;
    }
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.7),
        child: Text(balance.person.name.isEmpty
            ? '?'
            : balance.person.name[0].toUpperCase()),
      ),
      title: Text(balance.person.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(line, style: TextStyle(color: color)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(
              builder: (_) =>
                  PersonDetailScreen(person: balance.person)))
          .then((_) => appState.refresh()),
    );
  }
}
