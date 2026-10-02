import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../main.dart';
import '../models/transaction.dart';
import '../services/importer.dart';
import '../theme.dart';

/// Import preview (§7): what the statement parser found, before anything
/// is written. Uncheck what you don't want, tap a kind chip to change
/// it, confirm likely self-transfers, then import.
class ImportPreviewScreen extends StatefulWidget {
  final ParsedStatement statement;
  const ImportPreviewScreen({super.key, required this.statement});

  @override
  State<ImportPreviewScreen> createState() => _ImportPreviewScreenState();
}

class _ImportPreviewScreenState extends State<ImportPreviewScreen> {
  bool _importing = false;
  bool _transfersMarked = false;

  List<ParsedRow> get _rows => widget.statement.rows;
  int get _selected => _rows.where((r) => r.selected && !r.isDuplicate).length;
  int get _suggested =>
      _rows.where((r) => r.suggestedTransfer && !r.isDuplicate).length;

  void _markTransfers() {
    setState(() {
      for (final r in _rows) {
        if (r.suggestedTransfer && !r.isDuplicate) {
          r.kind = TxnKind.transfer;
        }
      }
      _transfersMarked = true;
    });
  }

  void _cycleKind(ParsedRow row) {
    setState(() {
      row.kind = switch (row.kind) {
        TxnKind.spend => TxnKind.receive,
        TxnKind.receive => TxnKind.transfer,
        _ => TxnKind.spend,
      };
    });
  }

  Future<void> _import() async {
    if (_importing) return;
    setState(() => _importing = true);
    final selected = _rows.where((r) => r.selected && !r.isDuplicate).toList();
    try {
      final report = await StatementImporter().commitRows(
        selected,
        widget.statement.mappingSignature,
        mapping: widget.statement.mapping,
        accountId: appState.settings.defaultAccountId,
      );
      appState.refresh();
      if (mounted) Navigator.of(context).pop(report);
    } catch (_) {
      // A failed commit must not strand the user on a spinning,
      // disabled Import button: stop the spinner, stay on the
      // preview (nothing was confirmed as imported), and say so.
      if (!mounted) return;
      setState(() => _importing = false);
      final s = Strings(appState.settings.language);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.get('somethingWrong'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      // While a commit is writing, a stray back tap must not pop the
      // screen out from under it — the write finishes in a moment and
      // the screen pops itself with the report.
      canPop: !_importing,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.get('importPreviewTitle')),
        ),
        body: Column(
          children: [
            if (!_transfersMarked && _suggested > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x2, Gap.x2, 0),
                child: Card(
                  color: cs.secondaryContainer.withValues(alpha: 0.5),
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.x2),
                    child: Row(
                      children: [
                        Icon(Icons.swap_horiz, color: cs.onSecondaryContainer),
                        const SizedBox(width: Gap.x1 + 4),
                        Expanded(
                          child: Text(
                            s
                                .get('transferPairHint')
                                .replaceFirst('{n}', '$_suggested'),
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        TextButton(
                          onPressed: _markTransfers,
                          child: Text(s.get('markTransfers')),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (widget.statement.errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x1, Gap.x2, 0),
                child: Text(
                  widget.statement.errors.join('\n'),
                  style: TextStyle(color: cs.error, fontSize: 13),
                ),
              ),
            Expanded(
              child: _rows.isEmpty
                  ? Center(
                      child: Text(s.get('importNoRows'),
                          style: Theme.of(context).textTheme.bodyMedium),
                    )
                  : ListView.builder(
                      // The Import button below is in-flow (Column +
                      // SafeArea), so it can never cover a row; the
                      // extra bottom padding just keeps the last row
                      // breathing clear of it at full scroll.
                      padding: const EdgeInsets.fromLTRB(
                          Gap.x1, Gap.x1, Gap.x1, Gap.x2),
                      itemCount: _rows.length,
                      itemBuilder: (_, i) {
                        final r = _rows[i];
                        final enabled = !r.isDuplicate;
                        return Opacity(
                          opacity: enabled ? 1 : 0.5,
                          child: CheckboxListTile(
                            value: r.selected && enabled,
                            enabled: enabled,
                            onChanged: enabled
                                ? (v) => setState(() => r.selected = v ?? false)
                                : null,
                            title: Text(r.merchant,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                                '${appState.formatDate(r.date)}${r.isDuplicate ? ' · ${s.get('duplicate')}' : ''}'),
                            secondary: GestureDetector(
                              onTap: enabled ? () => _cycleKind(r) : null,
                              child: _KindChip(kind: r.kind),
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                        );
                      },
                    ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(Gap.x2),
                child: FilledButton(
                  onPressed: (_selected == 0 || _importing) ? null : _import,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  child: _importing
                      ? const CircularProgressIndicator()
                      : Text(
                          s.get('importN').replaceFirst('{n}', '$_selected')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  final TxnKind kind;
  const _KindChip({required this.kind});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = kindLabel(kind);
    final Color bg;
    switch (kind) {
      case TxnKind.spend:
        bg = cs.errorContainer;
        break;
      case TxnKind.receive:
        bg = Colors.green.withValues(alpha: 0.2);
        break;
      default:
        bg = cs.surfaceContainerHighest;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radius.chip),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
