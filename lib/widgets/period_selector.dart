import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../main.dart';
import '../models/settings.dart';
import '../services/app_state.dart';
import '../theme.dart';

/// The shared viewing-period selector: one persisted period
/// ([AppSettings.period]) drives Home, Activity and Summary alike.
///
/// Renders as a single chip-like button showing the current period
/// label ("October", "Last month", "All time", …) with a drop-down
/// menu: This week · This month · Last month · This year · All time ·
/// Pick a month…. Selecting anything persists the choice via
/// [AppState.update] — every screen listening to appState refreshes.
///
/// Contract for other screens: just drop `const PeriodSelector()` in;
/// read ranges via `appState.periodRangeMs()` and names via
/// `appState.periodLabel()`.
class PeriodSelector extends StatelessWidget {
  const PeriodSelector({super.key});

  static const _pickValue = 'pick';

  Future<void> _onSelected(BuildContext context, String value) async {
    if (value == _pickValue) {
      final picked = await showPeriodMonthPicker(context);
      if (picked == null) return;
      await appState
          .update(appState.settings.copyWith(period: picked));
      return;
    }
    if (value != appState.settings.period) {
      await appState
          .update(appState.settings.copyWith(period: value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final current = appState.settings.period;
        PopupMenuItem<String> item(String value, String label) =>
            CheckedPopupMenuItem<String>(
              value: value,
              checked: current == value ||
                  (value == _pickValue &&
                      AppState.periodMonthParts(current) != null),
              child: Text(label),
            );
        return PopupMenuButton<String>(
          onSelected: (v) => _onSelected(context, v),
          itemBuilder: (_) => [
            item(AppSettings.periodThisWeek, s.get('thisWeek')),
            item(AppSettings.periodThisMonth, s.get('thisMonth')),
            item(AppSettings.periodLastMonth, s.get('lastMonth')),
            item(AppSettings.periodThisYear, s.get('rangeThisYear')),
            item(AppSettings.periodAllTime, s.get('rangeAllTime')),
            const PopupMenuDivider(),
            item(_pickValue, s.get('pickMonth')),
          ],
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context).colorScheme.outline),
              borderRadius: BorderRadius.circular(Radius.chip),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.calendar_month_outlined, size: 18),
                const SizedBox(width: 6),
                Text(appState.periodLabel(),
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Whether a month in the picker may be chosen: never the future.
/// [now] is "now" in the user's timezone. Pure — unit-tested.
bool periodMonthSelectable(int year, int month, DateTime now) =>
    year < now.year || (year == now.year && month <= now.month);

/// Month + year picker for a specific period month. Returns the
/// period value ('month:YYYY-MM') or null when cancelled. Future
/// months (and future years) are not selectable.
Future<String?> showPeriodMonthPicker(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _PeriodMonthPickerDialog(),
  );
}

class _PeriodMonthPickerDialog extends StatefulWidget {
  const _PeriodMonthPickerDialog();

  @override
  State<_PeriodMonthPickerDialog> createState() =>
      _PeriodMonthPickerDialogState();
}

class _PeriodMonthPickerDialogState
    extends State<_PeriodMonthPickerDialog> {
  late int _year;

  @override
  void initState() {
    super.initState();
    _year = appState.nowInTz().year;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final now = appState.nowInTz();
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(s.get('pickMonth')),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() => _year--),
                ),
                Text('$_year',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  // No stepping into the future.
                  onPressed: _year < now.year
                      ? () => setState(() => _year++)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: Gap.x1),
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              childAspectRatio: 1.9,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var m = 1; m <= 12; m++)
                  _monthButton(context, s, now, m, cs),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.get('cancel')),
        ),
      ],
    );
  }

  Widget _monthButton(BuildContext context, Strings s, DateTime now,
      int month, ColorScheme cs) {
    final enabled = periodMonthSelectable(_year, month, now);
    final isCurrent = _year == now.year && month == now.month;
    return OutlinedButton(
      onPressed: enabled
          ? () => Navigator.of(context).pop(
              'month:${_year.toString().padLeft(4, '0')}-'
              '${month.toString().padLeft(2, '0')}')
          : null,
      style: OutlinedButton.styleFrom(
        backgroundColor:
            isCurrent ? cs.primaryContainer.withValues(alpha: 0.5) : null,
        padding: EdgeInsets.zero,
      ),
      child: Text(s.monthAbbr(month),
          style: const TextStyle(fontSize: 13)),
    );
  }
}
