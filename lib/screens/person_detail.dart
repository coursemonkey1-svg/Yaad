import 'package:flutter/material.dart';

import '../data/db.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/person.dart';

/// One person's full lending story: every record with
/// original / repaid / remaining, repayment timeline, due dates.
class PersonDetailScreen extends StatefulWidget {
  final Person person;
  const PersonDetailScreen({super.key, required this.person});

  @override
  State<PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<PersonDetailScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.person.name)),
      body: FutureBuilder<List<LendingRecord>>(
        future: YaadDb.lendingForPerson(widget.person.id),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final records = snap.data!;
          if (records.isEmpty) {
            return const Center(child: Text('No records.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: records.length,
            itemBuilder: (_, i) => _LendingCard(
              record: records[i],
              onChanged: () => setState(() {}),
            ),
          );
        },
      ),
    );
  }
}

class _LendingCard extends StatelessWidget {
  final LendingRecord record;
  final VoidCallback onChanged;
  const _LendingCard({required this.record, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<double>(
      future: YaadDb.totalRepaid(record.id),
      builder: (context, snap) {
        final repaid = snap.data ?? 0;
        final remaining = record.originalAmount - repaid;
        final progress = record.originalAmount == 0
            ? 0.0
            : (repaid / record.originalAmount).clamp(0.0, 1.0);
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        record.reason.isEmpty
                            ? _typeLabel(record.type)
                            : record.reason,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    _StatusChip(status: record.status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_typeLabel(record.type)} · ${record.isOwedToMe ? 'they owe me' : 'I owe them'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 10,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _Amt('Original',
                        appState.money(record.originalAmount)),
                    _Amt('Repaid', appState.money(repaid),
                        color: Colors.green),
                    _Amt('Remaining', appState.money(remaining < 0 ? 0 : remaining),
                        color: remaining <= 0.005
                            ? Colors.green
                            : Theme.of(context).colorScheme.error),
                  ],
                ),
                if (record.dueDate != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.event_outlined, size: 16),
                      const SizedBox(width: 4),
                      Text(
                          'Due ${_fmtDate(record.dueDate!)}',
                          style:
                              Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                // Repayment timeline.
                FutureBuilder<List<Repayment>>(
                  future: YaadDb.repaymentsFor(record.id),
                  builder: (context, rsnap) {
                    final reps = rsnap.data ?? [];
                    if (reps.isEmpty) {
                      return const Text('No repayments yet.',
                          style: TextStyle(fontStyle: FontStyle.italic));
                    }
                    return Column(
                      children: reps
                          .map((r) => ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                    Icons.check_circle_outline,
                                    color: Colors.green),
                                title: Text(appState.money(r.amount)),
                                subtitle: Text(_fmtDate(r.date) +
                                    (r.note.isEmpty
                                        ? ''
                                        : ' · ${r.note}')),
                                trailing: IconButton(
                                  icon: const Icon(Icons.link_off,
                                      size: 18),
                                  tooltip: 'Unlink repayment',
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (_) => AlertDialog(
                                        title: const Text(
                                            'Unlink repayment?'),
                                        content: Text(
                                            'This will add ${appState.money(r.amount)} back to the balance.'),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.of(context)
                                                      .pop(false),
                                              child:
                                                  const Text('Cancel')),
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.of(context)
                                                      .pop(true),
                                              child:
                                                  const Text('Unlink')),
                                        ],
                                      ),
                                    );
                                    if (ok == true) {
                                      await YaadDb.deleteRepayment(r.id);
                                      appState.refresh();
                                      onChanged();
                                    }
                                  },
                                ),
                              ))
                          .toList(),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _typeLabel(LendingType t) {
    switch (t) {
      case LendingType.loan:
        return 'Loan';
      case LendingType.advance:
        return 'Advance';
      case LendingType.sharedExpense:
        return 'Shared expense';
      case LendingType.reimbursement:
        return 'Reimbursement';
      case LendingType.gift:
        return 'Gift';
    }
  }

  String _fmtDate(DateTime d) => appState.formatDate(d);
}

class _Amt extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _Amt(this.label, this.value, {this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value,
            style: TextStyle(fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final LendingStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final label = {
      LendingStatus.open: 'Open',
      LendingStatus.partial: 'Partial',
      LendingStatus.settled: 'Settled',
      LendingStatus.writtenOff: 'Written off',
      LendingStatus.gift: 'Gift',
    }[status]!;
    final color = status == LendingStatus.settled
        ? Colors.green
        : status == LendingStatus.open
            ? Colors.orange
            : Theme.of(context).colorScheme.primary;
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: color.withValues(alpha: 0.15),
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
    );
  }
}
