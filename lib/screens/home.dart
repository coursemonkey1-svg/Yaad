import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/account.dart';
import '../models/lending.dart';
import '../models/transaction.dart';
import '../models/purposes.dart';
import '../models/settings.dart';
import '../services/demo_data.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import '../widgets/period_selector.dart';
import 'accounts.dart';
import 'review.dart';
import 'summary.dart';
import 'transaction_view.dart';
import 'timeline.dart';

/// "Left" for the month: what came in, minus what went out, minus
/// what got parked in savings. Parked money isn't spendable, so it
/// counts as used; taking it back frees it again. A negative number
/// is shown honestly — no jargon, no scary styling.
double monthLeft(
        {required double received,
        required double spent,
        required double parked}) =>
    received - spent - parked;

/// Dashboard: one question per glance (§3).
/// Spent this month, received, who owes you / you owe, needs-your-eye,
/// recent activity. Lending never mixes into spending (§2).
class HomeScreen extends StatelessWidget {
  /// Called when the user taps an Udhaar card (switches to the Udhaar tab).
  final VoidCallback? onGoToUdhaar;
  const HomeScreen({super.key, this.onGoToUdhaar});

  Future<_Dash> _load(Strings s) async {
    // The shared viewing period (v1.5 period picker): hero figures
    // and the Recent list all live inside it. Balances and udhaar
    // stay all-time — they are not period figures.
    final (fromMs, toMs) = appState.periodRangeMs();

    final monthSpent = await YaadDb.sumSpent(fromMs, toMs);
    final monthReceived = await YaadDb.sumReceived(fromMs, toMs);
    // "Left" = what came in, minus what went out, minus what got
    // parked in savings — all inside the selected period. Parked
    // money isn't spendable, so it counts as used; taking it back
    // frees it again.
    final monthParked = await YaadDb.savingsNet(fromMs, toMs);
    final left = monthLeft(
        received: monthReceived, spent: monthSpent, parked: monthParked);

    // Savings: the backup stash. A single transfer row carries both
    // legs (accountId = from, toAccountId = to), so total = in − out.
    final savingsTotal = await YaadDb.savingsTotal();
    final accounts = await YaadDb.accounts();
    Account? byId(String id) {
      for (final a in accounts) {
        if (a.id == id) return a;
      }
      return null;
    }

    final savingsAccount = byId(Account.seedSavings);
    final defaultId =
        resolveDefaultAccountId(accounts, appState.settings.defaultAccountId);
    final defaultAccount = byId(defaultId);
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

    final recent = await YaadDb.txns(limit: 5, fromMs: fromMs, toMs: toMs);
    // Any rows at all: drives the first-run empty state (a buyer with
    // a totally empty app gets the "see how it works" offer, not just
    // a blank Recent list).
    final hasAnyTxn = (await YaadDb.txns(limit: 1)).isNotEmpty;
    // Balances: opening + all legs, all time (v1.5). The hero stays
    // month-flow; the balance is its own element under it.
    final totalBalance = await YaadDb.totalBalance();
    return _Dash(
      hasAnyTxn: hasAnyTxn,
      totalBalance: totalBalance,
      monthSpent: monthSpent,
      monthReceived: monthReceived,
      monthLeft: left,
      reviewCount: reviewCount,
      owedToMe: owedToMe,
      iOwe: iOwe,
      peopleOwing: peopleOwing.length,
      peopleOwed: peopleOwed.length,
      recent: recent,
      savingsTotal: savingsTotal,
      hasSavingsAccount: savingsAccount != null,
      fromId: defaultId,
      fromName: defaultAccount?.displayName(s) ?? defaultId,
      toName: savingsAccount?.displayName(s) ?? Account.seedSavings,
    );
  }

  /// The hero's first line always names the period being shown —
  /// never a bare figure with an unclear window. "Spent in October",
  /// "Spent in March 2025", "Spent in 2026", "Spent — all time".
  /// Last month shows its own month name (it IS September, not the
  /// phrase "last month", on a money card).
  String _heroLabel(Strings s) {
    final period = appState.settings.period;
    if (period == AppSettings.periodAllTime) {
      return s.get('spentAllTime');
    }
    if (period == AppSettings.periodLastMonth) {
      final n = appState.nowInTz();
      final last = DateTime(n.year, n.month - 1);
      return '${s.get('spentIn')} ${s.monthFull(last.month)}';
    }
    return '${s.get('spentIn')} ${appState.periodLabel()}';
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
          future: _load(s),
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
                // Bottom padding clears the shell's floating Add
                // button: the last card can always scroll fully
                // above it, on every tab that shares the FAB.
                padding: const EdgeInsets.fromLTRB(
                    Gap.x2, Gap.x2, Gap.x2, 96),
                children: [
                  // 0. Period: which window everything below shows.
                  const Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: PeriodSelector(),
                  ),
                  const SizedBox(height: Gap.x1 + 4),
                  // 1. Hero: spent in the selected period.
                  _HeroCard(
                    label: _heroLabel(s),
                    amount: d.monthSpent,
                    sub:
                        '${s.get('received')}: ${appState.money(d.monthReceived)}',
                    sub2: '${s.get('left')}: ${appState.money(d.monthLeft)}',
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SummaryScreen())),
                  ),
                  const SizedBox(height: Gap.x1 + 4),
                  // 1b. Balance: what he actually HAS, all time. Its
                  // own element — the Spent hero stays untouched.
                  _BalanceCard(total: d.totalBalance),
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
                                '${d.peopleOwing} ${d.peopleOwing == 1 ? s.get('personOne') : s.get('personMany')}',
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
                                '${d.peopleOwed} ${d.peopleOwed == 1 ? s.get('personOne') : s.get('personMany')}',
                            onTap: onGoToUdhaar ?? () {},
                          ),
                        ),
                    ],
                  ),
                  if (d.owedToMe > 0 || d.iOwe > 0)
                    const SizedBox(height: Gap.x1 + 4),
                  // 2b. Savings — the parked backup stash. Lives next to
                  // Udhaar: money that is neither spent nor spendable.
                  // Hidden entirely when the user turns it off in Settings
                  // (the money math is unaffected — display only).
                  if (d.hasSavingsAccount && appState.settings.showSavings)
                    _SavingsCard(
                      total: d.savingsTotal,
                      fromId: d.fromId,
                      fromName: d.fromName,
                      toName: d.toName,
                    ),
                  if (d.hasSavingsAccount && appState.settings.showSavings)
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
                      // An empty PERIOD on a non-empty app says so —
                      // "no spending recorded yet" would be a lie
                      // when he is simply looking at a quiet month.
                      title: d.hasAnyTxn
                          ? s
                              .get('noTxnsInPeriod')
                              .replaceFirst(
                                  '{period}', appState.periodLabel())
                          : s.get('noSpendingYet'),
                      body: s.get('tapAddHint'),
                    ),
                  // Totally empty app: offer the guided look around.
                  // One tap fills in sample figures (Settings → Demo
                  // data takes them back out just as fast).
                  if (!d.hasAnyTxn) ...[
                    const SizedBox(height: Gap.x1),
                    Center(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.science_outlined),
                        label: Text(
                            '${s.get('seeHowItWorks')} — ${s.get('addDemoDataCta')}'),
                        onPressed: () async {
                          await DemoData.addDemo(
                              currency: appState.settings.currency);
                          appState.refresh();
                        },
                      ),
                    ),
                  ],
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
  final bool hasAnyTxn;
  final double totalBalance;
  final double monthSpent, monthReceived, monthLeft;
  final double owedToMe, iOwe;
  final double savingsTotal;
  final bool hasSavingsAccount;
  final String fromId, fromName, toName;
  final int reviewCount, peopleOwing, peopleOwed;
  final List<YaadTransaction> recent;
  _Dash({
    required this.hasAnyTxn,
    required this.totalBalance,
    required this.monthSpent,
    required this.monthReceived,
    required this.monthLeft,
    required this.reviewCount,
    required this.owedToMe,
    required this.iOwe,
    required this.peopleOwing,
    required this.peopleOwed,
    required this.recent,
    required this.savingsTotal,
    required this.hasSavingsAccount,
    required this.fromId,
    required this.fromName,
    required this.toName,
  });
}

class _HeroCard extends StatelessWidget {
  final String label, sub, sub2;
  final double amount;
  final VoidCallback onTap;
  const _HeroCard(
      {required this.label,
      required this.amount,
      required this.sub,
      required this.sub2,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subStyle = TextStyle(
        color: cs.onPrimary.withValues(alpha: 0.85), fontSize: 14);
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
            // Received and Left sit side by side; Wrap keeps both
            // readable on narrow screens and in RTL.
            Wrap(
              spacing: 14,
              runSpacing: 2,
              children: [
                Text(sub, style: subStyle),
                Text(sub2, style: subStyle),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Total balance across all accounts: opening balances + every
/// transaction leg, all time. Its own slim element under the hero —
/// the hero stays month-flow ("Spent in October"), this answers
/// "what do I actually have?". Taps through to My accounts.
class _BalanceCard extends StatelessWidget {
  final double total;
  const _BalanceCard({required this.total});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AccountsScreen())),
      borderRadius: BorderRadius.circular(Radius.tile),
      child: Container(
        padding: const EdgeInsets.all(Gap.x2),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(Radius.tile),
        ),
        child: Row(
          children: [
            Icon(Icons.account_balance_wallet_outlined, color: cs.primary),
            const SizedBox(width: Gap.x1),
            Text(s.get('balance'),
                style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            MoneyText(total, size: 22),
            const Icon(Icons.chevron_right, size: 20),
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

/// The savings stash: what he parked in the backup account, with the
/// two moves he actually does — put money aside, take it back.
/// Sits next to the Udhaar cards: parked money is neither spent nor
/// spendable. Hidden entirely when there is no savings account.
class _SavingsCard extends StatelessWidget {
  final double total;
  final String fromId;
  final String fromName;
  final String toName;
  const _SavingsCard({
    required this.total,
    required this.fromId,
    required this.fromName,
    required this.toName,
  });

  void _openSheet(BuildContext context, {required bool add}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SavingsSheet(
        add: add,
        fromId: add ? fromId : Account.seedSavings,
        fromName: add ? fromName : toName,
        toId: add ? Account.seedSavings : fromId,
        toName: add ? toName : fromName,
      ),
    ).then((_) => appState.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.x2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radius.tile),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.savings_outlined, color: cs.primary),
              const SizedBox(width: Gap.x1),
              Text(s.get('savings'),
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              MoneyText(total, size: 22),
            ],
          ),
          if (total <= 0) ...[
            const SizedBox(height: 4),
            Text(s.get('savingsEmpty'),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.x1),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => _openSheet(context, add: true),
                  // Single-line, always: the label scales down
                  // instead of wrapping to two lines.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(s.get('addToSavings'), maxLines: 1),
                  ),
                ),
              ),
              // Nothing to take back when the stash is empty.
              if (total > 0) ...[
                const SizedBox(width: Gap.x1),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _openSheet(context, add: false),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(s.get('takeBack'), maxLines: 1),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Amount → Move. One sheet: the from → to line is the confirmation,
/// so the whole move is two taps. Keyboard-safe like the capture
/// sheet (lifts by viewInsets, scrolls on small screens).
class _SavingsSheet extends StatefulWidget {
  final bool add;
  final String fromId;
  final String fromName;
  final String toId;
  final String toName;
  const _SavingsSheet({
    required this.add,
    required this.fromId,
    required this.fromName,
    required this.toId,
    required this.toName,
  });

  @override
  State<_SavingsSheet> createState() => _SavingsSheetState();
}

class _SavingsSheetState extends State<_SavingsSheet> {
  final _amountCtrl = TextEditingController();
  bool _moving = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  double get _amount =>
      double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;

  /// One transfer row: from-account → to-account. Kind 'transfer' is
  /// never counted as spending or income, so the month totals stay
  /// clean; [YaadDb.savingsNet] derives in−out from these rows.
  ///
  /// After the move, the user SEES what it did: a plain confirmation
  /// with the amount and the month's new Left — before v1.5 the math
  /// was right but invisible, and parking looked like it did nothing.
  Future<void> _move() async {
    // Rapid double-tap guard: one tap, one transfer row.
    if (_moving) return;
    final amount = _amount;
    if (amount <= 0) return;
    setState(() => _moving = true);
    final s = Strings(appState.settings.language);
    final messenger = ScaffoldMessenger.of(context);
    await YaadDb.insertTxn(YaadTransaction(
      amount: amount,
      dateTime: DateTime.now(),
      direction: TxnDirection.ownTransfer,
      kind: TxnKind.transfer,
      purpose: 'savings',
      source: TxnSource.manual,
      accountId: widget.fromId,
      toAccountId: widget.toId,
    ));
    // Recompute the confirmation over the period Home is actually
    // showing, so the Left in the message matches the hero. When the
    // move lands OUTSIDE the shown period (he is browsing last month
    // while parking today), the plain message is used instead — the
    // same honesty rule as saving an out-of-period transaction.
    final (fromMs, toMs) = appState.periodRangeMs();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final inPeriod = nowMs >= fromMs && nowMs <= toMs;
    final left = monthLeft(
      received: await YaadDb.sumReceived(fromMs, toMs),
      spent: await YaadDb.sumSpent(fromMs, toMs),
      parked: await YaadDb.savingsNet(fromMs, toMs),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(
      content: Text(inPeriod
          ? (widget.add
                  ? s.get('movedSnackPark')
                  : s.get('movedSnackBack'))
              .replaceFirst('{amount}', appState.money(amount))
              .replaceFirst('{left}', appState.money(left))
          : (widget.add
                  ? s.get('movedSnackParkPlain')
                  : s.get('movedSnackBackPlain'))
              .replaceFirst('{amount}', appState.money(amount))),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(Gap.x3, Gap.x1 + 4, Gap.x3, Gap.x4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: cs.outlineVariant,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: Gap.x2),
                Text(
                    widget.add ? s.get('addToSavings') : s.get('takeBack'),
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text('${widget.fromName} → ${widget.toName}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurfaceVariant)),
                const SizedBox(height: Gap.x2),
                TextField(
                  controller: _amountCtrl,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
                  ],
                  style: const TextStyle(
                      fontSize: 40, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    labelText: s.get('amount'),
                    prefixText: '${appState.settings.currency} ',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: Gap.x2),
                FilledButton(
                  onPressed: _amount > 0 && !_moving ? _move : null,
                  child: Text(s.get('move')),
                ),
              ],
            ),
          ),
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

/// Friendly-name lookups for a row (merchant alias + person + accounts).
class _TxnRowNames {
  final String? alias;
  final String? personName;
  final String accountLabel;
  final String toAccountLabel;
  const _TxnRowNames(
      this.alias, this.personName, this.accountLabel, this.toAccountLabel);
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
    String toLabel = '';
    if (txn.toAccountId != null) {
      final to = await YaadDb.accountById(txn.toAccountId!);
      toLabel = to?.displayName(s) ?? txn.toAccountId!;
    }
    return _TxnRowNames(
      (alias != null && alias.alias.isNotEmpty) ? alias.alias : null,
      (personName != null && personName.isNotEmpty) ? personName : null,
      account?.displayName(s) ?? accountId,
      toLabel,
    );
  }

  /// The card's big line. Transfers say WHERE the money went — a park
  /// and a take-back must be unmistakable at a glance (before v1.5
  /// both rendered as "Moved" with the same chips stacked four deep).
  /// Anything else: the user's name for it, the bank's name, or — when
  /// there is no name at all — the purpose. Never the kind word: it
  /// already sits in the chip directly underneath.
  String _title(Strings s, _TxnRowNames? names) {
    if (txn.kind == TxnKind.transfer) {
      final from = names?.accountLabel ?? '';
      final to = names?.toAccountLabel ?? '';
      if (txn.purpose == 'savings') {
        if (txn.toAccountId == Account.seedSavings && to.isNotEmpty) {
          return s.get('movedTo').replaceFirst('{account}', to);
        }
        if (txn.accountId == Account.seedSavings && from.isNotEmpty) {
          return s.get('takenBackFrom').replaceFirst('{account}', from);
        }
      }
      if (from.isNotEmpty && to.isNotEmpty) return '$from → $to';
      return kindLabel(txn.kind);
    }
    final alias = names?.alias;
    if (alias != null) return alias;
    if (txn.rawMerchant.isNotEmpty) return txn.rawMerchant;
    return purposeLabel(txn.purpose);
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
        final title = _title(s, names);
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
    // Transfers show the whole move on the sub-line: from → to.
    final sub = (txn.kind == TxnKind.transfer &&
            (names?.toAccountLabel ?? '').isNotEmpty)
        ? '${names?.accountLabel ?? ''} → ${names!.toAccountLabel}'
        : (names?.accountLabel ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 15, height: 1.3)),
        Text(sub,
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
    // Date + time stay together on ONE line (they used to wrap
    // raggedly mid-phrase); the person gets their own line.
    final dateLine =
        '${appState.formatDate(txn.dateTime)} · $timeOfDay';
    final isTransfer = txn.kind == TxnKind.transfer;
    final from = names?.accountLabel ?? '';
    final to = names?.toAccountLabel ?? '';
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
            if (isTransfer) ...[
              // One chip says it all: from → to. No kind chip, no
              // purpose chip, no second account chip repeating it.
              if (from.isNotEmpty && to.isNotEmpty)
                _chip(context, '$from → $to', cs.tertiary,
                    icon: Icons.swap_horiz),
            ] else ...[
              _chip(context, kindLabel(txn.kind), tint),
              _chip(context, purposeLabel(txn.purpose),
                  cs.onSurfaceVariant),
              _chip(context, names?.accountLabel ?? '', cs.tertiary,
                  icon: Icons.account_balance_wallet_outlined),
            ],
            if (needsReview)
              _chip(context, s.get('needsReview'), cs.error,
                  icon: Icons.visibility_outlined),
            _sourceChip(context, s),
          ],
        ),
        const SizedBox(height: 8),
        Text(dateLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12, color: cs.onSurfaceVariant, height: 1.35)),
        if (names?.personName != null)
          Text(names!.personName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
