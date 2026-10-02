import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/purposes.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import '../widgets/period_selector.dart';

/// Spending totals by purpose for the shared viewing period — the
/// same persisted period Home and Activity use (PeriodSelector).
/// No charts library needed — honest bars.
class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Strings(appState.settings.language);
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final (fromMs, toMs) = appState.periodRangeMs();
        return Scaffold(
          appBar: AppBar(title: Text(t.get('spending'))),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    const PeriodSelector(),
                    const Spacer(),
                    Text(appState.periodLabel(),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Map<String, Object?>>>(
                  future: YaadDb.sumByPurpose(fromMs, toMs),
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
                    final rows = snap.data!;
                    if (rows.isEmpty) {
                      return YaadEmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: t.get('noSpendingPeriod'),
                        body: t.get('noSpendingPeriodBody'),
                      );
                    }
                    final max = (rows.first['total'] as num).toDouble();
                    final total = rows.fold<double>(
                        0, (a, r) => a + (r['total'] as num).toDouble());
                    return ListView(
                      padding:
                          const EdgeInsets.fromLTRB(16, 16, 16, Gap.x4),
                      children: [
                        Text(appState.money(total),
                            style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold)),
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
      },
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
                    Expanded(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 8),
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
