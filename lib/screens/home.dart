import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/transaction.dart';
import '../models/purposes.dart';
import '../models/alias.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import 'review.dart';
import 'summary.dart';
import 'confirm.dart';
import 'timeline.dart';

/// Dashboard: one question per glance (§3).
/// Spent this month, received, who owes you / you owe, needs-your-eye,
/// recent activity. Lending never mixes into spending (§2).
class HomeScreen extends StatelessWidget {
  /// Called when the user taps an Udhaar card (switches to the Udhaar tab).
  final VoidCallback? onGoToUdhaar;
  const HomeScreen({super.key, this.onGoToUdhaar});

  Future<_Dash> _load() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final monthMs = appState.startOfMonthMs();

    final monthSpent = await YaadDb.sumSpent(monthMs, nowMs);
    final monthReceived = await YaadDb.sumReceived(monthMs, nowMs);
    final reviewCount =
        await YaadDb.countByStatus(TxnStatus.needsReview.name);

    // Udhaar totals: plain separation from spending.
    final lending = await YaadDb.allLending();
    double owedToMe = 0, iOwe = 0;
    final peopleOwing = <String>{};
    final peopleOwed = <String>{};
    for (final l in lending) {
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
        peopleOwing.add(l.personId);
      } else {
        iOwe += remaining;
        peopleOwed.add(l.personId);
      }
    }

    final recent = await YaadDb.txns(limit: 5);
    return _Dash(
      monthSpent: monthSpent,
      monthReceived: monthReceived,
      reviewCount: reviewCount,
      owedToMe: owedToMe,
      iOwe: iOwe,
      peopleOwing: peopleOwing.length,
      peopleOwed: peopleOwed.length,
      recent: recent,
    );
  }

  String _monthName(BuildContext context) {
    const en = [
      'January', 'February', 'March', 'April', 'May', 'June', 'July',
      'August', 'September', 'October', 'November', 'December'
    ];
    const ur = [
      'جنوری', 'فروری', 'مارچ', 'اپریل', 'مئی', 'جون', 'جولائی',
      'اگست', 'ستمبر', 'اکتوبر', 'نومبر', 'دسمبر'
    ];
    final m = appState.nowInTz().month;
    return appState.settings.language == 'ur' ? ur[m - 1] : en[m - 1];
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
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
            if (snap.hasError) {
              return YaadErrorState(
                message: '${snap.error}',
                onRetry: () => appState.refresh(),
              );
            }
            if (!snap.hasData) {
              return const YaadLoading();
            }
            final d = snap.data!;
            return RefreshIndicator(
              onRefresh: () async => appState.refresh(),
              child: ListView(
                padding: const EdgeInsets.all(Gap.x2),
                children: [
                  // 1. Hero: spent this month.
                  _HeroCard(
                    label: '${s.get('spentIn')} ${_monthName(context)}',
                    amount: d.monthSpent,
                    sub:
                        '${s.get('received')}: ${appState.money(d.monthReceived)}',
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SummaryScreen())),
                  ),
                  const SizedBox(height: Gap.x1 + 4),
                  // 2. Udhaar cards (hidden when zero — calm screen).
                  Row(
                    children: [
                      if (d.owedToMe > 0)
                        Expanded(
                          child: _MiniCard(
                            icon: Icons.handshake_outlined,
                            iconColor: Colors.green,
                            label: s.get('peopleOweYou'),
                            value: d.owedToMe,
                            sub:
                                '${d.peopleOwing} ${d.peopleOwing == 1 ? 'person' : 'people'}',
                            onTap: onGoToUdhaar ?? () {},
                          ),
                        ),
                      if (d.owedToMe > 0 && d.iOwe > 0)
                        const SizedBox(width: Gap.x1 + 4),
                      if (d.iOwe > 0)
                        Expanded(
                          child: _MiniCard(
                            icon: Icons.handshake_outlined,
                            iconColor: cs.error,
                            label: s.get('youOwe'),
                            value: d.iOwe,
                            sub:
                                '${d.peopleOwed} ${d.peopleOwed == 1 ? 'person' : 'people'}',
                            onTap: onGoToUdhaar ?? () {},
                          ),
                        ),
                    ],
                  ),
                  if (d.owedToMe > 0 || d.iOwe > 0)
                    const SizedBox(height: Gap.x1 + 4),
                  // 3. Needs your eye.
                  if (d.reviewCount > 0)
                    _ReviewCard(count: d.reviewCount),
                  if (d.reviewCount > 0)
                    const SizedBox(height: Gap.x1 + 4),
                  // 4. Recent activity.
                  const SizedBox(height: Gap.x1),
                  SectionHeader(
                    title: s.get('recent'),
                    actionLabel: s.get('seeAll'),
                    onAction: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const TimelineScreen())),
                  ),
                  if (d.recent.isEmpty)
                    YaadEmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: s.get('noSpendingYet'),
                      body: s.get('tapAddHint'),
                    ),
                  for (final t in d.recent) TxnRow(txn: t),
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
  final double monthSpent, monthReceived;
  final double owedToMe, iOwe;
  final int reviewCount, peopleOwing, peopleOwed;
  final List<YaadTransaction> recent;
  _Dash({
    required this.monthSpent,
    required this.monthReceived,
    required this.reviewCount,
    required this.owedToMe,
    required this.iOwe,
    required this.peopleOwing,
    required this.peopleOwed,
    required this.recent,
  });
}

class _HeroCard extends StatelessWidget {
  final String label, sub;
  final double amount;
  final VoidCallback onTap;
  const _HeroCard(
      {required this.label,
      required this.amount,
      required this.sub,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radius.card),
      child: Container(
        padding: const EdgeInsets.all(Gap.x3),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.primary, cs.tertiary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(Radius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    color: cs.onPrimary.withValues(alpha: 0.85),
                    fontSize: 14)),
            const SizedBox(height: 4),
            MoneyText(amount,
                size: 36, color: cs.onPrimary),
            const SizedBox(height: 4),
            Text(sub,
                style: TextStyle(
                    color: cs.onPrimary.withValues(alpha: 0.85),
                    fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class _MiniCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label, sub;
  final double value;
  final VoidCallback onTap;
  const _MiniCard({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.sub,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radius.tile),
      child: Container(
        padding: const EdgeInsets.all(Gap.x2),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(Radius.tile),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(height: Gap.x1),
            MoneyText(value, size: 20),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(sub,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final int count;
  const _ReviewCard({required this.count});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ReviewScreen())),
      borderRadius: BorderRadius.circular(Radius.tile),
      child: Container(
        padding: const EdgeInsets.all(Gap.x2),
        decoration: BoxDecoration(
          color: cs.secondaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Radius.tile),
        ),
        child: Row(
          children: [
            Icon(Icons.visibility_outlined, color: cs.secondary),
            const SizedBox(width: Gap.x1 + 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.get('needsYourEye'),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('$count ${s.get('needsYourEyeSub')}',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

/// One transaction row, reused across Home / Activity / Review.
/// Plain words first: kind label + amount, never bare −/+ signs.
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
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<MerchantAlias?>(
      future: YaadDb.aliasFor(txn.rawMerchant),
      builder: (context, snap) {
        final alias = snap.data?.alias;
        final title = (alias != null && alias.isNotEmpty)
            ? alias
            : (txn.rawMerchant.isEmpty
                ? kindLabel(txn.kind)
                : txn.rawMerchant);
        final subtitle =
            '${kindLabel(txn.kind)} · ${purposeLabel(txn.purpose)} · ${appState.formatDate(txn.dateTime)}';
        return ListTile(
          onTap: onTap ??
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ConfirmScreen(editing: txn))),
          leading: CircleAvatar(
            backgroundColor:
                cs.surfaceContainerHighest.withValues(alpha: 0.7),
            child: Icon(_iconFor(txn.kind, txn.purpose),
                color: _colorFor(context, txn.kind)),
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
                appState.money(txn.amount),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: _colorFor(context, txn.kind),
                ),
              ),
              if (txn.status == TxnStatus.needsReview)
                Icon(Icons.pending_outlined,
                    size: 14, color: cs.onSurfaceVariant),
            ],
          ),
        );
      },
    );
  }

  IconData _iconFor(TxnKind kind, String purpose) {
    switch (kind) {
      case TxnKind.spend:
        return purposeIcon(purpose);
      case TxnKind.receive:
        return Icons.south_west;
      case TxnKind.lendOut:
        return Icons.north_east;
      case TxnKind.borrowIn:
        return Icons.south_west;
      case TxnKind.repayOut:
      case TxnKind.repayIn:
        return Icons.payments_outlined;
      case TxnKind.transfer:
        return Icons.swap_horiz;
    }
  }

  Color _colorFor(BuildContext context, TxnKind kind) {
    final cs = Theme.of(context).colorScheme;
    switch (kind) {
      case TxnKind.spend:
        return cs.error;
      case TxnKind.receive:
        return Colors.green;
      case TxnKind.lendOut:
      case TxnKind.borrowIn:
      case TxnKind.repayOut:
      case TxnKind.repayIn:
        return cs.primary;
      case TxnKind.transfer:
        return cs.onSurfaceVariant;
    }
  }
}
