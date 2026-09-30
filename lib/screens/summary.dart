import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/purposes.dart';

/// Simple weekly / monthly spending totals by purpose.
/// No charts library needed — honest bars, tap to see transactions.
class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});
  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  bool _monthly = true;
  DateTime _anchor = DateTime.now();

  (int, int) _range() {
    final loc = appState.nowInTz().location;
    tz.TZDateTime start;
    tz.TZDateTime end;
    if (_monthly) {
      start = tz.TZDateTime(loc, _anchor.year, _anchor.month, 1);
      final next = _anchor.month == 12
          ? tz.TZDateTime(loc, _anchor.year + 1, 1, 1)
          : tz.TZDateTime(loc, _anchor.year, _anchor.month + 1, 1);
      end = next.subtract(const Duration(milliseconds: 1));
    } else {
      final first = appState.settings.firstDayOfWeek;
      final diff = (_anchor.weekday - first) % 7;
      final monday = _anchor.subtract(Duration(days: diff));
      start = tz.TZDateTime(loc, monday.year, monday.month, monday.day);
      end = start.add(const Duration(days: 7)).subtract(const Duration(milliseconds: 1));
    }
    return (start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
  }

  String _title(Strings t) {
    if (_monthly) return '${t.monthAbbr(_anchor.month)} ${_anchor.year}';
    final (s, _) = _range();
    final d = DateTime.fromMillisecondsSinceEpoch(s);
    return '${t.get('weekOf')} ${d.day} ${t.monthAbbr(d.month)}';
  }

  void _shift(int dir) {
    setState(() {
      _anchor = _monthly
          ? DateTime(_anchor.year, _anchor.month + dir, 1)
          : _anchor.add(Duration(days: 7 * dir));
    });
  }

  @override
  Widget build(BuildContext context) {
    final (from, to) = _range();
    final t = Strings(appState.settings.language);
    return Scaffold(
      appBar: AppBar(title: Text(t.get('spending'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                IconButton(
                    onPressed: () => _shift(-1),
                    icon: const Icon(Icons.chevron_left)),
                Expanded(
                    child: Center(
                        child: Text(_title(t),
                            style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold)))),
                IconButton(
                    onPressed: () => _shift(1),
                    icon: const Icon(Icons.chevron_right)),
              ],
            ),
          ),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(t.get('week'))),
              ButtonSegment(value: true, label: Text(t.get('month'))),
            ],
            selected: {_monthly},
            onSelectionChanged: (v) =>
                setState(() => _monthly = v.first),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<Map<String, Object?>>>(
              future: YaadDb.sumByPurpose(from, to),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(
                      child: CircularProgressIndicator());
                }
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return Center(
                      child: Text(t.get('noSpendingPeriod')));
                }
                final max =
                    (rows.first['total'] as num).toDouble();
                final total =
                    rows.fold<double>(0, (a, r) => a + (r['total'] as num).toDouble());
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(appState.money(total),
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    for (final r in rows)
                      _Bar(
                        label: purposeLabel(r['purpose'] as String),
                        icon: purposeIcon(r['purpose'] as String),
                        amount: (r['total'] as num).toDouble(),
                        max: max,
                        count: (r['n'] as int?) ?? 0,
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  final String label;
  final IconData icon;
  final double amount, max;
  final int count;
  const _Bar(
      {required this.label,
      required this.icon,
      required this.amount,
      required this.max,
      required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600)),
                    Text(appState.money(amount),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: max == 0 ? 0 : amount / max,
                    minHeight: 8,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                  ),
                ),
                Text(
                    Strings(appState.settings.language)
                        .get('transactionsCount')
                        .replaceFirst('{n}', '$count')
                        .replaceFirst('{s}', count == 1 ? '' : 's'),
                    style:
                        Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
