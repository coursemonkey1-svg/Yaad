import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/person.dart';
import '../models/transaction.dart';
import '../services/pro.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import 'borrow.dart';
import 'lend.dart';
import 'lending_detail.dart';
import 'pro.dart';
import 'repay.dart';

/// One person's Udhaar page: plain-words balance, four action buttons,
/// full history, Settle up, and a Pro-gated statement of account (§5).
class PersonDetailScreen extends StatefulWidget {
  final Person person;
  const PersonDetailScreen({super.key, required this.person});

  @override
  State<PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<PersonDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(widget.person.name)),
        body: FutureBuilder<_Detail>(
          future: _load(),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const YaadLoading();
            }
            final d = snap.data!;
            return ListView(
              // Extra bottom clearance: the history's last row must
              // never sit flush under the screen edge.
              padding: const EdgeInsets.fromLTRB(
                  Gap.x2, Gap.x2, Gap.x2, Gap.x4),
              children: [
                _BalanceHeader(detail: d, person: widget.person),
                const SizedBox(height: Gap.x2),
                // Four plain actions.
                GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 2,
                  mainAxisSpacing: Gap.x1 + 4,
                  crossAxisSpacing: Gap.x1 + 4,
                  childAspectRatio: 2.4,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _Action(
                      icon: Icons.south_west,
                      label: s.get('theyPaidMe'),
                      onTap: () => _openRepay(context, true),
                    ),
                    _Action(
                      icon: Icons.north_east,
                      label: s.get('iPaidThem'),
                      onTap: () => _openRepay(context, false),
                    ),
                    _Action(
                      icon: Icons.handshake_outlined,
                      label: s.get('lendMore'),
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute(
                              builder: (_) => LendScreen(
                                  initialPerson: widget.person)))
                          .then((_) => appState.refresh()),
                    ),
                    _Action(
                      icon: Icons.handshake_outlined,
                      label: s.get('borrowMore'),
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute(
                              builder: (_) => BorrowScreen(
                                  initialPerson: widget.person)))
                          .then((_) => appState.refresh()),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.x2),
                if (d.net != 0)
                  FilledButton.tonalIcon(
                    onPressed: () => _settleUp(context, d),
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(s.get('settleUp')),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                  ),
                const SizedBox(height: Gap.x1),
                OutlinedButton.icon(
                  onPressed: () => _statement(context, d),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(s.get('statementOfAccount')),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                ),
                const SizedBox(height: Gap.x2),
                SectionHeader(title: s.get('history')),
                if (d.records.isEmpty)
                  Text(s.get('noUdhaarYet'),
                      style: Theme.of(context).textTheme.bodyMedium),
                for (final e in d.entries)
                  if (e.repayment == null)
                    _LendingRow(
                        detail: d, record: e.record, person: widget.person)
                  else
                    _RepaymentRow(
                        record: e.record,
                        repayment: e.repayment!,
                        person: widget.person),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<_Detail> _load() async {
    final records = await YaadDb.lendingForPerson(widget.person.id);
    double owedToMe = 0, iOwe = 0;
    final remaining = <String, double>{};
    final repaid = <String, double>{};
    final entries = <_HistoryEntry>[];
    for (final r in records) {
      entries.add(_HistoryEntry(record: r, date: r.date));
      // Actual repayments for EVERY record — the statement needs the
      // real repaid figure even for settled/written-off records,
      // where "original − remaining" would claim a full repayment
      // that never happened.
      final paid = await YaadDb.totalRepaid(r.id);
      repaid[r.id] = paid;
      for (final rep in await YaadDb.repaymentsFor(r.id)) {
        entries.add(_HistoryEntry(record: r, repayment: rep, date: rep.date));
      }
      if (r.status == LendingStatus.settled ||
          r.status == LendingStatus.writtenOff ||
          r.status == LendingStatus.gift) {
        remaining[r.id] = 0;
        continue;
      }
      final rem = r.originalAmount - paid;
      remaining[r.id] = rem;
      if (rem <= 0.005) continue;
      if (r.isOwedToMe) {
        owedToMe += rem;
      } else {
        iOwe += rem;
      }
    }
    // Newest first; a lend/borrow sorts before its own repayments
    // when they share a timestamp.
    entries.sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      if (byDate != 0) return byDate;
      if (a.repayment == null && b.repayment != null) return -1;
      if (a.repayment != null && b.repayment == null) return 1;
      return 0;
    });
    return _Detail(records, remaining, repaid, entries, owedToMe, iOwe);
  }

  void _openRepay(BuildContext context, bool theyPaidMe) {
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) => RepayScreen(
                person: widget.person, theyPaidMe: theyPaidMe)))
        .then((_) => appState.refresh());
  }

  /// Settle up: record a full repayment for every open balance.
  Future<void> _settleUp(BuildContext context, _Detail d) async {
    final s = Strings(appState.settings.language);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.get('settleUp')),
        content: Text(s.get('settleUpConfirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.get('cancel'))),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(s.get('settleUp'))),
        ],
      ),
    );
    if (ok != true) return;
    final now = DateTime.now();
    for (final r in d.records) {
      final rem = d.remaining[r.id] ?? 0;
      if (rem <= 0.005) continue;
      await YaadDb.addRepayment(
          Repayment(lendingId: r.id, amount: rem, date: now));
      // Mirror RepayScreen: the settlement is real money movement,
      // so it also lands in Activity as a "Paid back" transaction —
      // settle-up must not be invisible there.
      await YaadDb.insertTxn(YaadTransaction(
        amount: rem,
        currency: appState.settings.currency,
        dateTime: now,
        kind: r.isOwedToMe ? TxnKind.repayIn : TxnKind.repayOut,
        direction:
            r.isOwedToMe ? TxnDirection.incoming : TxnDirection.out,
        rawMerchant: widget.person.name,
        purpose: 'uncategorized',
        note: r.reason,
        personId: widget.person.id,
        linkedLendingId: r.id,
        source: TxnSource.manual,
        accountId: appState.settings.defaultAccountId,
      ));
    }
    appState.refresh();
  }

  /// Statement of account: a shareable summary. Pro-gated (§11).
  Future<void> _statement(BuildContext context, _Detail d) async {
    final s = Strings(appState.settings.language);
    final settings = appState.settings;
    if (!ProService.canUseStatement(settings)) {
      if (!context.mounted) return;
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProScreen()));
      return;
    }
    final buf = StringBuffer()
      ..writeln('${s.get('statementOfAccount')}: ${widget.person.name}')
      ..writeln(
          '${s.get('generatedByYaad')}: ${appState.formatDate(DateTime.now())}')
      ..writeln('---');
    for (final r in d.records) {
      final dir = r.isOwedToMe ? s.get('iLent') : s.get('iBorrowed');
      final repaid = d.repaid[r.id] ?? 0;
      buf
        ..writeln(
            '$dir ${appState.money(r.originalAmount)} — ${appState.formatDate(r.date)}${r.reason.isNotEmpty ? ' (${r.reason})' : ''}')
        ..writeln(
            '  ${s.get('repaid')}: ${appState.money(repaid)} · ${s.get('remaining')}: ${appState.money(d.remaining[r.id] ?? 0)} · ${lendingStatusLabel(s, r.status)}');
    }
    buf
      ..writeln('---')
      ..writeln(_netLine(d));
    await Share.share(buf.toString(),
        subject: s.get('statementOfAccount'));
  }

  String _netLine(_Detail d) {
    final s = Strings(appState.settings.language);
    final net = d.owedToMe - d.iOwe;
    if (net > 0.005) {
      return s
          .get('owesYouLine')
          .replaceFirst('{name}', widget.person.name)
          .replaceFirst('{amount}', appState.money(net));
    }
    if (net < -0.005) {
      return s
          .get('youOweLine')
          .replaceFirst('{name}', widget.person.name)
          .replaceFirst('{amount}', appState.money(-net));
    }
    return s.get('settledWith').replaceFirst('{name}', widget.person.name);
  }
}

class _Detail {
  final List<LendingRecord> records;
  final Map<String, double> remaining;
  final Map<String, double> repaid;
  final List<_HistoryEntry> entries;
  final double owedToMe, iOwe;
  double get net => owedToMe - iOwe;
  _Detail(this.records, this.remaining, this.repaid, this.entries,
      this.owedToMe, this.iOwe);
}

/// One row of the unified History: a lend/borrow record
/// ([repayment] == null) or one of its repayments.
class _HistoryEntry {
  final LendingRecord record;
  final Repayment? repayment;
  final DateTime date;
  const _HistoryEntry(
      {required this.record, this.repayment, required this.date});
}

/// Plain-words, localised label for a lending status — never the raw
/// enum name ("partial") in the UI or the shared statement.
String lendingStatusLabel(Strings s, LendingStatus status) =>
    s.get('lendingStatus_${status.name}');

class _BalanceHeader extends StatelessWidget {
  final _Detail detail;
  final Person person;
  const _BalanceHeader({required this.detail, required this.person});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    final net = detail.net;
    // The outstanding amount is the HEADLINE: the full plain-words
    // line ("Ahmed owes you PKR 500" / "You owe Ahmed PKR 500") at
    // display size. (The old build composed the 'owesYou' fragment,
    // which has no {amount} placeholder — the amount never showed.)
    final String line;
    final Color color;
    if (net > 0.005) {
      line = s
          .get('owesYouLine')
          .replaceFirst('{name}', person.name)
          .replaceFirst('{amount}', appState.money(net));
      color = Colors.green;
    } else if (net < -0.005) {
      line = s
          .get('youOweLine')
          .replaceFirst('{name}', person.name)
          .replaceFirst('{amount}', appState.money(-net));
      color = cs.error;
    } else {
      // Settled: calm, no figure.
      line = s.get('allSettled');
      color = cs.onSurfaceVariant;
    }
    return Container(
      padding: const EdgeInsets.all(Gap.x3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radius.card),
      ),
      child: Column(
        children: [
          Icon(Icons.handshake_outlined, size: 40, color: color),
          const SizedBox(height: Gap.x1),
          Text(person.name,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(line,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: color)),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Action(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radius.tile),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(Radius.tile),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: cs.primary),
            const SizedBox(width: Gap.x1),
            Flexible(
                child: Text(label,
                    style:
                        const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      ),
    );
  }
}

/// A lend/borrow history row. Layout: the amount lives in its own
/// trailing column and NEVER wraps (the old one-phrase title wrapped
/// mid-amount: "I borrowed PKR" / "500"); title and subtitle are
/// single lines with ellipsis as the backstop. The whole row taps
/// into the entry's detail view (view / edit / delete).
class _LendingRow extends StatelessWidget {
  final _Detail detail;
  final LendingRecord record;
  final Person person;
  const _LendingRow(
      {required this.detail, required this.record, required this.person});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    final rem = detail.remaining[record.id] ?? 0;
    final dir = record.isOwedToMe ? s.get('iLent') : s.get('iBorrowed');
    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            cs.surfaceContainerHighest.withValues(alpha: 0.7),
        child: Icon(
            record.isOwedToMe ? Icons.north_east : Icons.south_west),
      ),
      title: Text(
          record.reason.isEmpty ? dir : '$dir · ${record.reason}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
          '${appState.formatDate(record.date)} · ${lendingStatusLabel(s, record.status)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(appState.money(record.originalAmount),
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15)),
          Text(
              '${s.get('remaining')}: ${appState.money(rem)}',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
        ],
      ),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(
              builder: (_) => LendingDetailScreen(
                  lendingId: record.id, person: person)))
          .then((_) => appState.refresh()),
    );
  }
}

/// A repayment history row — same one-line-amount layout, taps into
/// the repayment's detail view (view / edit / delete).
class _RepaymentRow extends StatelessWidget {
  final LendingRecord record;
  final Repayment repayment;
  final Person person;
  const _RepaymentRow(
      {required this.record, required this.repayment, required this.person});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            cs.surfaceContainerHighest.withValues(alpha: 0.7),
        child: const Icon(Icons.payments_outlined),
      ),
      title: Text(s.get('kind_repayIn'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
          repayment.note.isEmpty
              ? appState.formatDate(repayment.date)
              : '${appState.formatDate(repayment.date)} · ${repayment.note}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: Text(appState.money(repayment.amount),
          maxLines: 1,
          softWrap: false,
          style:
              const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(
              builder: (_) => RepaymentDetailScreen(
                  repayment: repayment, record: record, person: person)))
          .then((_) => appState.refresh()),
    );
  }
}
