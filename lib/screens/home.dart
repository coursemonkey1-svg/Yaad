import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/transaction.dart';
import '../models/purposes.dart';
import '../models/alias.dart';
import 'review.dart';
import 'summary.dart';
import 'confirm.dart';
import 'timeline.dart';

/// Dashboard: spending this week/month, needs-review count,
/// lent-out totals, outstanding balances, recent transactions.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<_Dash> _load() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final weekMs = appState.startOfWeekMs();
    final monthMs = appState.startOfMonthMs();
    final dayMs = appState.startOfTodayMs();

    final weekOut = await YaadDb.sumOut(weekMs, nowMs);
    final monthOut = await YaadDb.sumOut(monthMs, nowMs);
    final todayOut = await YaadDb.sumOut(dayMs, nowMs);
    final reviewCount =
        await YaadDb.countByStatus(TxnStatus.needsReview.name);

    // Lending totals.
    final lending = await YaadDb.allLending();
    double lentOut = 0, owedToMe = 0;
    for (final l in lending) {
      if (l.status == LendingStatus.settled ||
          l.status == LendingStatus.writtenOff ||
          l.status == LendingStatus.gift) {
        continue;
      }
      final repaid = await YaadDb.totalRepaid(l.id);
      final remaining = l.originalAmount - repaid;
      if (remaining <= 0) continue;
      if (l.isOwedToMe) {
        lentOut += remaining;
      } else {
        owedToMe += remaining;
      }
    }

    final recent = await YaadDb.txns(limit: 5);
    return _Dash(
      weekOut: weekOut,
      monthOut: monthOut,
      todayOut: todayOut,
      reviewCount: reviewCount,
      lentOut: lentOut,
      owedToMe: owedToMe,
      recent: recent,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Yaad',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text(s.get('appTagline'),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        body: FutureBuilder<_Dash>(
          future: _load(),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final d = snap.data!;
            return RefreshIndicator(
              onRefresh: () async => appState.refresh(),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _HeroCard(
                      label: s.get('thisMonth'),
                      amount: appState.money(d.monthOut),
                      sub:
                          '${s.get('thisWeek')}: ${appState.money(d.weekOut)}',
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const SummaryScreen()))),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                          child: _MiniCard(
                              icon: Icons.inbox_outlined,
                              label: s.get('needsReview'),
                              value: '${d.reviewCount}',
                              onTap: () => Navigator.of(context)
                                  .push(MaterialPageRoute(
                                      builder: (_) =>
                                          const ReviewScreen())))),
                      const SizedBox(width: 12),
                      Expanded(
                          child: _MiniCard(
                              icon: Icons.handshake_outlined,
                              label: s.get('lentOut'),
                              value: appState.money(d.lentOut),
                              onTap: null)),
                    ],
                  ),
                  if (d.owedToMe > 0) ...[
                    const SizedBox(height: 12),
                    _MiniCard(
                        icon: Icons.warning_amber_outlined,
                        label: s.get('owedToYou'),
                        value: appState.money(d.owedToMe),
                        onTap: null),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(s.get('recent'),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const TimelineScreen())),
                        child: Text(s.get('seeAll')),
                      ),
                    ],
                  ),
                  if (d.recent.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                          child: Text(s.get('noTransactions'),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium)),
                    ),
                  for (final t in d.recent) _TxnRow(txn: t),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Dash {
  final double weekOut, monthOut, todayOut, lentOut, owedToMe;
  final int reviewCount;
  final List<YaadTransaction> recent;
  _Dash({
    required this.weekOut,
    required this.monthOut,
    required this.todayOut,
    required this.reviewCount,
    required this.lentOut,
    required this.owedToMe,
    required this.recent,
  });
}

class _HeroCard extends StatelessWidget {
  final String label, amount, sub;
  final VoidCallback onTap;
  const _HeroCard(
      {required this.label,
      required this.amount,
      required this.sub,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.tertiary,
          ]),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onPrimary
                        .withValues(alpha: 0.8))),
            const SizedBox(height: 4),
            Text(amount,
                style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimary)),
            Text(sub,
                style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onPrimary
                        .withValues(alpha: 0.8))),
          ],
        ),
      ),
    );
  }
}

class _MiniCard extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  const _MiniCard(
      {required this.icon,
      required this.label,
      required this.value,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:
              Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            Text(value,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            Text(label,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// One transaction row, reused across screens.
class TxnRow extends StatelessWidget {
  final YaadTransaction txn;
  final VoidCallback? onTap;
  const TxnRow({super.key, required this.txn, this.onTap});

  @override
  Widget build(BuildContext context) {
    return _TxnRow(txn: txn, onTap: onTap);
  }
}

class _TxnRow extends StatelessWidget {
  final YaadTransaction txn;
  final VoidCallback? onTap;
  const _TxnRow({required this.txn, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isOut = txn.direction == TxnDirection.out;
    return FutureBuilder<MerchantAlias?>(
      future: YaadDb.aliasFor(txn.rawMerchant),
      builder: (context, snap) {
        final alias = snap.data?.alias;
        final title = (alias != null && alias.isNotEmpty)
            ? alias
            : (txn.rawMerchant.isEmpty ? '—' : txn.rawMerchant);
        final subtitle = alias != null && alias.isNotEmpty
            ? txn.rawMerchant
            : purposeLabel(txn.purpose);
        return ListTile(
          onTap: onTap ??
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ConfirmScreen(editing: txn))),
          leading: CircleAvatar(
            backgroundColor: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest,
            child: Icon(purposeIcon(txn.purpose),
                color: Theme.of(context).colorScheme.primary),
          ),
          title: Text(title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(subtitle,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${isOut ? '−' : '+'}${appState.money(txn.amount)}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isOut
                      ? Theme.of(context).colorScheme.error
                      : Colors.green,
                ),
              ),
              if (txn.status == TxnStatus.needsReview)
                const Icon(Icons.pending_outlined, size: 14),
            ],
          ),
        );
      },
    );
  }
}
