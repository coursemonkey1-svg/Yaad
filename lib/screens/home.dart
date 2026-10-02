import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/account.dart';
import '../models/lending.dart';
import '../models/transaction.dart';
import '../models/purposes.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import 'review.dart';
import 'summary.dart';
import 'transaction_view.dart';
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
                size: 36, color: cs.onPrimary, animated: true),
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

/// One transaction card, reused across Home / Activity / Review.
/// Plain words first: kind label + amount, never bare −/+ signs.
///
/// [compact] renders the glanceable single-row density (icon + title +
/// amount); otherwise the detailed card shows purpose, date/time, note
/// snippet, person/merchant and a source badge.
class TxnRow extends StatelessWidget {
  final YaadTransaction txn;
  final VoidCallback? onTap;
  final bool compact;
  const TxnRow(
      {super.key, required this.txn, this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return _TxnRow(txn: txn, onTap: onTap, compact: compact);
  }
}

/// Friendly-name lookups for a row (merchant alias + person + account).
class _TxnRowNames {
  final String? alias;
  final String? personName;
  final String accountLabel;
  const _TxnRowNames(this.alias, this.personName, this.accountLabel);
}

class _TxnRow extends StatelessWidget {
  final YaadTransaction txn;
  final VoidCallback? onTap;
  final bool compact;
  const _TxnRow(
      {required this.txn, this.onTap, this.compact = false});

  Future<_TxnRowNames> _loadNames(Strings s) async {
    final alias = await YaadDb.aliasFor(txn.rawMerchant);
    String? personName;
    if (txn.personId != null) {
      personName = (await YaadDb.personById(txn.personId!))?.name;
    }
    // NULL accountId (pre-v1.4 rows or raw inserts) reads as the
    // default account — a row is never shown without an account tag.
    final accountId = txn.accountId ?? Account.seedMeezan;
    final account = await YaadDb.accountById(accountId);
    return _TxnRowNames(
      (alias != null && alias.alias.isNotEmpty) ? alias.alias : null,
      (personName != null && personName.isNotEmpty) ? personName : null,
      account?.displayName(s) ?? accountId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = Strings(appState.settings.language);
    final tint = _colorFor(context, txn.kind);
    return FutureBuilder<_TxnRowNames>(
      future: _loadNames(s),
      builder: (context, snap) {
        final names = snap.data;
        final title = names?.alias ??
            (txn.rawMerchant.isEmpty ? kindLabel(txn.kind) : txn.rawMerchant);
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: InkWell(
            onTap: onTap ??
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => TransactionViewScreen(txn: txn))),
            borderRadius: BorderRadius.circular(Radius.chip),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Radius.chip),
                border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.45)),
              ),
              child: Row(
                crossAxisAlignment: compact
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(_iconFor(txn.kind, txn.purpose),
                        color: tint, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: compact
                        ? _compactBody(context, s, title, names)
                        : _detailedBody(context, s, title, names, tint),
                  ),
                  const SizedBox(width: 8),
                  _amountColumn(context, s, tint),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Glanceable single row: title + account tag + amount.
  Widget _compactBody(BuildContext context, Strings s, String title,
      _TxnRowNames? names) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 15, height: 1.3)),
        Text(names?.accountLabel ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
      ],
    );
  }

  /// The full card: purpose, date/time, note snippet, person, source badge.
  Widget _detailedBody(BuildContext context, Strings s, String title,
      _TxnRowNames? names, Color tint) {
    final cs = Theme.of(context).colorScheme;
    final needsReview = txn.status == TxnStatus.needsReview;
    final timeOfDay =
        MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay.fromDateTime(txn.dateTime));
    final meta = StringBuffer(appState.formatDate(txn.dateTime))
      ..write(' · ')
      ..write(timeOfDay);
    if (names?.personName != null) {
      meta
        ..write(' · ')
        ..write(names!.personName);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 15, height: 1.3)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _chip(context, kindLabel(txn.kind), tint),
            _chip(context, purposeLabel(txn.purpose),
                cs.onSurfaceVariant),
            _chip(context, names?.accountLabel ?? '', cs.tertiary,
                icon: Icons.account_balance_wallet_outlined),
            if (needsReview)
              _chip(context, s.get('needsReview'), cs.error,
                  icon: Icons.visibility_outlined),
            _sourceChip(context, s),
          ],
        ),
        const SizedBox(height: 8),
        Text(meta.toString(),
            style: TextStyle(
                fontSize: 12, color: cs.onSurfaceVariant, height: 1.35)),
        if (txn.note.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(txn.note.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                  height: 1.35)),
        ],
      ],
    );
  }

  /// Bank-captured vs added-by-hand, shown as a small badge.
  Widget _sourceChip(BuildContext context, Strings s) {
    final bankCaptured = txn.source != TxnSource.manual;
    final cs = Theme.of(context).colorScheme;
    return _chip(
      context,
      bankCaptured ? s.get('sourceBankAlert') : s.get('sourceManual'),
      bankCaptured ? cs.tertiary : cs.onSurfaceVariant,
      icon: bankCaptured
          ? Icons.account_balance_outlined
          : Icons.edit_outlined,
    );
  }

  Widget _chip(BuildContext context, String label, Color tint,
      {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(Radius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: tint),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: tint,
                  height: 1.2)),
        ],
      ),
    );
  }

  Widget _amountColumn(BuildContext context, Strings s, Color tint) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          appState.money(txn.amount),
          textAlign: TextAlign.end,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: tint,
          ),
        ),
        if (compact && txn.status == TxnStatus.needsReview)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Icon(Icons.pending_outlined,
                size: 14, color: cs.onSurfaceVariant),
          ),
      ],
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
