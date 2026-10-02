import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/person.dart';
import '../models/transaction.dart';
import '../theme.dart';

/// Record a repayment with explicit direction — no toggles (§5).
/// [theyPaidMe] = true: "They paid me" (against money I lent).
/// [theyPaidMe] = false: "I paid them" (against money I borrowed).
/// The repayment lands in the "Paid back" bucket, and reduces the
/// Udhaar balance — spending is never touched.
class RepayScreen extends StatefulWidget {
  final Person person;
  final bool theyPaidMe;
  final LendingRecord? preselected;
  const RepayScreen(
      {super.key,
      required this.person,
      required this.theyPaidMe,
      this.preselected});

  @override
  State<RepayScreen> createState() => _RepayScreenState();
}

class _RepayScreenState extends State<RepayScreen> {
  final _amountCtrl = TextEditingController();
  List<_Open> _open = [];
  LendingRecord? _selected;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await YaadDb.openLendingForPerson(widget.person.id,
        owedToMe: widget.theyPaidMe);
    final list = <_Open>[];
    for (final r in records) {
      final repaid = await YaadDb.totalRepaid(r.id);
      list.add(_Open(r, r.originalAmount - repaid));
    }
    if (!mounted) return;
    setState(() {
      _open = list;
      _selected = widget.preselected ??
          (list.isNotEmpty ? list.first.record : null);
      if (_selected != null) {
        final rem = list
            .firstWhere((o) => o.record.id == _selected!.id)
            .remaining;
        _amountCtrl.text =
            rem.toStringAsFixed(rem.truncateToDouble() == rem ? 0 : 2);
      }
      _loading = false;
    });
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Strings(appState.settings.language).get('enterAmount'))));
      return;
    }
    setState(() => _saving = true);
    final now = DateTime.now();
    final personName = widget.person.name;

    if (_selected != null) {
      await YaadDb.addRepayment(Repayment(
        lendingId: _selected!.id,
        amount: amount,
        date: now,
      ));
    }
    // A transaction in the "Paid back" bucket — this is real money
    // movement, but it is not spending and not receiving (§2).
    await YaadDb.insertTxn(YaadTransaction(
      amount: amount,
      currency: appState.settings.currency,
      dateTime: now,
      kind: widget.theyPaidMe ? TxnKind.repayIn : TxnKind.repayOut,
      direction: widget.theyPaidMe
          ? TxnDirection.incoming
          : TxnDirection.out,
      rawMerchant: personName,
      purpose: 'uncategorized',
      note: _selected?.reason ?? '',
      personId: widget.person.id,
      source: TxnSource.manual,
      accountId: appState.settings.defaultAccountId,
    ));
    appState.refresh();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final title =
        widget.theyPaidMe ? s.get('theyPaidMe') : s.get('iPaidThem');
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Gap.x2),
              children: [
                Text(
                  widget.theyPaidMe
                      ? s.get('theyPaidMeSub')
                      : s.get('iPaidThemSub'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ).let((w) => Padding(
                    padding: const EdgeInsets.only(bottom: Gap.x2),
                    child: w)),
                if (_open.isEmpty)
                  Text(
                    widget.theyPaidMe
                        ? s.get('noOpenLent')
                        : s.get('noOpenBorrowed'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                RadioGroup<LendingRecord>(
                  groupValue: _selected,
                  onChanged: (r) => setState(() {
                    _selected = r;
                    final o = _open.firstWhere(
                        (e) => e.record.id == r!.id);
                    _amountCtrl.text = o.remaining.toStringAsFixed(
                        o.remaining.truncateToDouble() == o.remaining
                            ? 0
                            : 2);
                  }),
                  child: Column(
                    children: [
                      for (final o in _open)
                        RadioListTile<LendingRecord>(
                          value: o.record,
                          title: Text(
                              '${appState.money(o.record.originalAmount)}'
                              '${o.record.reason.isNotEmpty ? ' · ${o.record.reason}' : ''}'),
                          subtitle: Text(
                              '${s.get('remaining')}: ${appState.money(o.remaining)}'),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Gap.x2),
                TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
                  ],
                  style: const TextStyle(
                      fontSize: 32, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: s.get('amount'),
                    prefixText: '${appState.settings.currency} ',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: Gap.x3),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  child: _saving
                      ? const CircularProgressIndicator()
                      : Text(title,
                          style: const TextStyle(fontSize: 18)),
                ),
              ],
            ),
    );
  }
}

class _Open {
  final LendingRecord record;
  final double remaining;
  _Open(this.record, this.remaining);
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
