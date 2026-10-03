import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../main.dart';

/// The date range chosen for a CSV export.
class ExportRange {
  /// Inclusive. Time is ignored — the export covers whole days.
  final DateTime? from;

  /// Inclusive. Time is ignored — the export covers whole days.
  final DateTime? to;

  /// File-name fragment, e.g. '2026-09', '2026', 'all',
  /// '2026-09-01_to_2026-09-15'.
  final String fileLabel;

  const ExportRange({this.from, this.to, required this.fileLabel});
}

enum _Preset { thisMonth, last3Months, thisYear, allTime, custom }

/// Asks which transactions to export. Returns null when cancelled.
Future<ExportRange?> showExportRangeDialog(BuildContext context) {
  final s = Strings(appState.settings.language);
  return showDialog<ExportRange>(
    context: context,
    builder: (_) => _RangeDialog(s: s),
  );
}

class _RangeDialog extends StatefulWidget {
  final Strings s;
  const _RangeDialog({required this.s});

  @override
  State<_RangeDialog> createState() => _RangeDialogState();
}

class _RangeDialogState extends State<_RangeDialog> {
  _Preset _preset = _Preset.thisMonth;
  DateTime? _customFrom;
  DateTime? _customTo;

  static DateTime _endOfMonth(int year, int month) =>
      DateTime(year, month + 1, 0);

  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  ExportRange _rangeFor(_Preset preset) {
    final now = DateTime.now();
    switch (preset) {
      case _Preset.thisMonth:
        final from = DateTime(now.year, now.month, 1);
        return ExportRange(
          from: from,
          to: _endOfMonth(now.year, now.month),
          fileLabel:
              '${from.year}-${from.month.toString().padLeft(2, '0')}',
        );
      case _Preset.last3Months:
        final from = DateTime(now.year, now.month - 2, 1);
        return ExportRange(
          from: from,
          to: _endOfMonth(now.year, now.month),
          fileLabel: 'last-3-months',
        );
      case _Preset.thisYear:
        return ExportRange(
          from: DateTime(now.year, 1, 1),
          to: DateTime(now.year, 12, 31),
          fileLabel: '${now.year}',
        );
      case _Preset.allTime:
        return const ExportRange(fileLabel: 'all');
      case _Preset.custom:
        // Only reachable when both dates are set and from <= to —
        // the dialog disables Export otherwise (see _customInvalid).
        return ExportRange(
          from: _customFrom!,
          to: _customTo!,
          fileLabel: '${_ymd(_customFrom!)}_to_${_ymd(_customTo!)}',
        );
    }
  }

  /// A custom range whose start is after its end. Previously the
  /// dates were silently swapped, so the export covered a different
  /// range than the one on the buttons.
  bool get _customInvalid =>
      _preset == _Preset.custom &&
      _customFrom != null &&
      _customTo != null &&
      _customFrom!.isAfter(_customTo!);

  String _span(_Preset preset) {
    final r = _rangeFor(preset);
    return '${appState.formatDate(r.from!)} – ${appState.formatDate(r.to!)}';
  }

  Future<void> _pickCustomDate(bool isFrom) async {
    final d = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _customFrom : _customTo) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null || !mounted) return;
    setState(() {
      _preset = _Preset.custom;
      if (isFrom) {
        _customFrom = d;
      } else {
        _customTo = d;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;

    Widget presetTile(_Preset preset, String title, String? subtitle) {
      return RadioListTile<_Preset>(
        value: preset,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        dense: true,
        contentPadding: EdgeInsets.zero,
      );
    }

    Widget dateButton(String label, DateTime? date, bool isFrom) {
      return Expanded(
        child: OutlinedButton(
          onPressed: () => _pickCustomDate(isFrom),
          child: Text(
            date == null ? label : appState.formatDate(date),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    final canExport = !_customInvalid &&
        (_preset != _Preset.custom ||
            (_customFrom != null && _customTo != null));

    return AlertDialog(
      title: Text(s.get('exportRangeTitle')),
      content: SingleChildScrollView(
        child: RadioGroup<_Preset>(
          groupValue: _preset,
          onChanged: (v) => setState(() => _preset = v!),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              presetTile(_Preset.thisMonth, s.get('thisMonth'),
                  _span(_Preset.thisMonth)),
              presetTile(_Preset.last3Months, s.get('rangeLast3Months'),
                  _span(_Preset.last3Months)),
              presetTile(_Preset.thisYear, s.get('rangeThisYear'),
                  _span(_Preset.thisYear)),
              presetTile(_Preset.allTime, s.get('rangeAllTime'),
                  s.get('rangeAllTimeSub')),
              const Divider(),
              presetTile(_Preset.custom, s.get('rangeCustom'), null),
              if (_preset == _Preset.custom)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      dateButton(s.get('rangeFrom'), _customFrom, true),
                      const SizedBox(width: 8),
                      dateButton(s.get('rangeTo'), _customTo, false),
                    ],
                  ),
                ),
              if (_customInvalid)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    s.get('rangeInvalid'),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.get('cancel')),
        ),
        FilledButton(
          onPressed: canExport
              ? () => Navigator.of(context).pop(_rangeFor(_preset))
              : null,
          child: Text(s.get('export')),
        ),
      ],
    );
  }
}
