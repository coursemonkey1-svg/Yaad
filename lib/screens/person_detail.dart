import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/person.dart';
import '../services/pro.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import 'borrow.dart';
import 'lend.dart';
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
              padding: const EdgeInsets.all(Gap.x2),
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
                for (final r in d.records)
                  _RecordRow(
                      detail: d, record: r, person: widget.person),
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
    for (final r in records) {
      if (r.status == LendingStatus.settled ||
          r.status == LendingStatus.writtenOff ||
          r.status == LendingStatus.gift) {
        remaining[r.id] = 0;
        continue;
      }
      final repaid = await YaadDb.totalRepaid(r.id);
      final rem = r.originalAmount - repaid;
      remaining[r.id] = rem;
      if (rem <= 0.005) continue;
      if (r.isOwedToMe) {
        owedToMe += rem;
      } else {
        iOwe += rem;
      }
    }
    return _Detail(records, remaining, owedToMe, iOwe);
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
      final repaid = r.originalAmount - (d.remaining[r.id] ?? 0);
      buf
        ..writeln(
            '$dir ${appState.money(r.originalAmount)} — ${appState.formatDate(r.date)}${r.reason.isNotEmpty ? ' (${r.reason})' : ''}')
        ..writeln(
            '  ${s.get('repaid')}: ${appState.money(repaid)} · ${s.get('remaining')}: ${appState.money(d.remaining[r.id] ?? 0)} · ${r.status.name}');
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
  final double owedToMe, iOwe;
  double get net => owedToMe - iOwe;
  _Detail(this.records, this.remaining, this.owedToMe, this.iOwe);
}

class _BalanceHeader extends StatelessWidget {
  final _Detail detail;
  final Person person;
  const _BalanceHeader({required this.detail, required this.person});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    final net = detail.net;
    final String line;
    final Color color;
    if (net > 0.005) {
      line = s
          .get('owesYou')
          .replaceFirst('{amount}', appState.money(net));
      color = Colors.green;
    } else if (net < -0.005) {
      line = s.get('youOwe').replaceFirst('{amount}', appState.money(-net));
      color = cs.error;
    } else {
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
                  fontSize: 20,
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

class _RecordRow extends StatelessWidget {
  final _Detail detail;
  final LendingRecord record;
  final Person person;
  const _RecordRow(
      {required this.detail, required this.record, required this.person});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final rem = detail.remaining[record.id] ?? 0;
    final dir = record.isOwedToMe ? s.get('iLent') : s.get('iBorrowed');
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.7),
        child: Icon(
            record.isOwedToMe ? Icons.north_east : Icons.south_west),
      ),
      title: Text(
          '$dir ${appState.money(record.originalAmount)}${record.reason.isNotEmpty ? ' · ${record.reason}' : ''}'),
      subtitle: Text(
          '${appState.formatDate(record.date)} · ${s.get('remaining')}: ${appState.money(rem)} · ${record.status.name}'),
      trailing: rem > 0.005
          ? TextButton(
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(
                      builder: (_) => RepayScreen(
                          person: person,
                          theyPaidMe: record.isOwedToMe,
                          preselected: record)))
                  .then((_) => appState.refresh()),
              child: Text(s.get('repay')),
            )
          : null,
    );
  }
}
