import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/person.dart';
import '../models/transaction.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import 'person_detail.dart';
import 'repay.dart';

/// Detail + edit + delete for one lend/borrow history entry.
///
/// Lending records are NOT transactions (the Lend/Borrow screens
/// write no transaction), so they can't open TransactionViewScreen —
/// this is the equivalent experience in the same visual language:
/// a read-only view first, Edit and Delete as explicit actions.
/// Every mutation goes through the data layer and refreshes the
/// lending status from the repayments, so the person's outstanding
/// can never disagree with the history.
class LendingDetailScreen extends StatefulWidget {
  final String lendingId;
  final Person person;
  const LendingDetailScreen(
      {super.key, required this.lendingId, required this.person});

  @override
  State<LendingDetailScreen> createState() => _LendingDetailScreenState();
}

class _LendingDetailScreenState extends State<LendingDetailScreen> {
  LendingRecord? _record;
  List<Repayment> _repayments = [];
  List<Person> _people = [];
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;

  final _amountCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  String _personId = '';

  @override
  void initState() {
    super.initState();
    _personId = widget.person.id;
    _load();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    LendingRecord? found;
    for (final r in await YaadDb.allLending()) {
      if (r.id == widget.lendingId) found = r;
    }
    final reps = await YaadDb.repaymentsFor(widget.lendingId);
    final people = await YaadDb.people();
    if (!mounted) return;
    setState(() {
      _record = found;
      _repayments = reps;
      _people = people;
      _loading = false;
      if (found != null) {
        _amountCtrl.text = _plainAmount(found.originalAmount);
        _reasonCtrl.text = found.reason;
        _date = found.date;
        _personId = found.personId;
      }
    });
  }

  static String _plainAmount(double v) =>
      v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2);

  double get _repaid =>
      _repayments.fold(0.0, (a, r) => a + r.amount);

  double get _remaining =>
      (_record?.originalAmount ?? 0) - _repaid;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (_saving || _record == null) return;
    final s = Strings(appState.settings.language);
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('enterAmount'))));
      return;
    }
    setState(() => _saving = true);
    final updated = _record!.copyWith(
      originalAmount: amount,
      date: _date,
      reason: _reasonCtrl.text.trim(),
      personId: _personId,
    );
    await YaadDb.updateLending(updated);
    // Amount (or a fresh set of figures) may have changed what the
    // repayments mean — recompute open/partial/settled from them.
    await YaadDb.refreshLendingStatus(updated.id);
    appState.refresh();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _editing = false;
    });
    await _load();
  }

  Future<void> _delete() async {
    final s = Strings(appState.settings.language);
    final n = _repayments.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.get('deleteLendTitle')),
        content: Text(n == 0
            ? s.get('deleteLendBody')
            : s
                .get('deleteLendWithRepayments')
                .replaceFirst('{n}', '$n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.get('cancel'))),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor:
                    Theme.of(context).colorScheme.error),
            child: Text(s.get('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Cascades: repayments + their linked transactions go too.
    await YaadDb.deleteLending(widget.lendingId);
    appState.refresh();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.get('entryDeleted'))));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.get('details')),
        actions: [
          if (!_loading && _record != null && !_editing)
            IconButton(
              tooltip: s.get('edit'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => setState(() => _editing = true),
            ),
          if (!_loading && _record != null)
            IconButton(
              tooltip: s.get('delete'),
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _record == null
              ? YaadEmptyState(
                  icon: Icons.error_outline,
                  title: s.get('somethingWrong'),
                  body: s.get('captureTxnGone'),
                )
              : _editing
                  ? _editForm(s)
                  : _view(s),
    );
  }

  Widget _view(Strings s) {
    final r = _record!;
    final dirLabel = r.isOwedToMe ? s.get('iLent') : s.get('iBorrowed');
    final personName = _personName(r.personId);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x2, Gap.x2, Gap.x4),
      children: [
        Center(
          child: Text(appState.money(r.originalAmount),
              style: const TextStyle(
                  fontSize: 32, fontWeight: FontWeight.bold)),
        ),
        Center(
          child: Text('$dirLabel · ${lendingStatusLabel(s, r.status)}',
              style: Theme.of(context).textTheme.bodyMedium),
        ),
        const SizedBox(height: Gap.x2),
        _row(s.get('personName'), personName),
        _row(s.get('date'), appState.formatDate(r.date)),
        if (r.reason.isNotEmpty) _row(s.get('whatFor'), r.reason),
        _row(s.get('repaid'), appState.money(_repaid)),
        _row(s.get('remaining'), appState.money(_remaining)),
        if (_remaining > 0.005) ...[
          const SizedBox(height: Gap.x2),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => RepayScreen(
                        person: widget.person,
                        theyPaidMe: r.isOwedToMe,
                        preselected: r)))
                .then((_) async {
              appState.refresh();
              await _load();
            }),
            icon: const Icon(Icons.payments_outlined),
            label: Text(s.get('repay')),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48)),
          ),
        ],
      ],
    );
  }

  String _personName(String id) {
    for (final p in _people) {
      if (p.id == id) return p.name;
    }
    return widget.person.id == id ? widget.person.name : id;
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _editForm(Strings s) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x2, Gap.x2, Gap.x4),
      children: [
        TextField(
          controller: _amountCtrl,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
          ],
          style:
              const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            labelText: s.get('amount'),
            prefixText: '${appState.settings.currency} ',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.x2),
        DropdownButtonFormField<String>(
          initialValue:
              _people.any((p) => p.id == _personId) ? _personId : null,
          decoration: InputDecoration(
            labelText: s.get('personName'),
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final p in _people)
              DropdownMenuItem(value: p.id, child: Text(p.name)),
          ],
          onChanged: (v) => setState(() => _personId = v ?? _personId),
        ),
        const SizedBox(height: Gap.x1),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.calendar_today_outlined),
          title: Text(s.get('date')),
          subtitle: Text(appState.formatDate(_date)),
          onTap: _pickDate,
        ),
        TextField(
          controller: _reasonCtrl,
          decoration: InputDecoration(
            labelText: s.get('whatFor'),
            hintText: s.get('whatForHint'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.x3),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52)),
          child: Text(s.get('save'),
              style: const TextStyle(fontSize: 18)),
        ),
        TextButton(
          onPressed: () => setState(() => _editing = false),
          child: Text(s.get('cancel')),
        ),
      ],
    );
  }
}

/// Detail + edit + delete for one repayment in a person's history.
///
/// Deleting a repayment also deletes its linked "Paid back"
/// transaction (found via Repayment.transactionId, or — for
/// repayments recorded before that link was stored — the transaction
/// carrying this lending's id), so Activity and Udhaar never
/// disagree. Editing goes through YaadDb.updateRepayment, which
/// keeps the linked transaction's amount/date in step.
class RepaymentDetailScreen extends StatefulWidget {
  final Repayment repayment;
  final LendingRecord record;
  final Person person;
  const RepaymentDetailScreen({
    super.key,
    required this.repayment,
    required this.record,
    required this.person,
  });

  @override
  State<RepaymentDetailScreen> createState() =>
      _RepaymentDetailScreenState();
}

class _RepaymentDetailScreenState extends State<RepaymentDetailScreen> {
  bool _editing = false;
  bool _saving = false;
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    _amountCtrl.text = widget.repayment.amount.toStringAsFixed(
        widget.repayment.amount.truncateToDouble() ==
                widget.repayment.amount
            ? 0
            : 2);
    _noteCtrl.text = widget.repayment.note;
    _date = widget.repayment.date;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (_saving) return;
    final s = Strings(appState.settings.language);
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('enterAmount'))));
      return;
    }
    setState(() => _saving = true);
    await YaadDb.updateRepayment(Repayment(
      id: widget.repayment.id,
      lendingId: widget.repayment.lendingId,
      amount: amount,
      date: _date,
      note: _noteCtrl.text.trim(),
      transactionId: widget.repayment.transactionId,
    ));
    appState.refresh();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Deletes the linked "Paid back" transaction for [repayment], if
  /// one can be identified with confidence.
  Future<void> _deleteLinkedTxn(Repayment repayment) async {
    if (repayment.transactionId != null) {
      await YaadDb.deleteTxn(repayment.transactionId!);
      return;
    }
    // Older repayments stored no transactionId; RepayScreen links
    // the transaction side instead (linkedLendingId). Match on the
    // parent lending + amount + same calendar day before deleting —
    // anything less certain is left alone.
    final kind =
        widget.record.isOwedToMe ? TxnKind.repayIn : TxnKind.repayOut;
    final candidates = await YaadDb.txns(
        personId: widget.person.id, kind: kind, limit: 500);
    for (final t in candidates) {
      final sameDay = t.dateTime.year == repayment.date.year &&
          t.dateTime.month == repayment.date.month &&
          t.dateTime.day == repayment.date.day;
      if (t.linkedLendingId == widget.record.id &&
          (t.amount - repayment.amount).abs() <= 0.005 &&
          sameDay) {
        await YaadDb.deleteTxn(t.id);
        return;
      }
    }
  }

  Future<void> _delete() async {
    final s = Strings(appState.settings.language);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.get('unlinkRepayment')),
        content: Text(s.get('unlinkRepaymentBody')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.get('cancel'))),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor:
                    Theme.of(context).colorScheme.error),
            child: Text(s.get('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _deleteLinkedTxn(widget.repayment);
    // Recomputes the lending status (a settled loan reopens).
    await YaadDb.deleteRepayment(widget.repayment.id);
    appState.refresh();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.get('repaymentDeleted'))));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final r = widget.repayment;
    final parentDir =
        widget.record.isOwedToMe ? s.get('iLent') : s.get('iBorrowed');
    return Scaffold(
      appBar: AppBar(
        title: Text(s.get('details')),
        actions: [
          if (!_editing)
            IconButton(
              tooltip: s.get('edit'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => setState(() => _editing = true),
            ),
          IconButton(
            tooltip: s.get('delete'),
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      body: _editing ? _editForm(s) : _view(s, r, parentDir),
    );
  }

  Widget _view(Strings s, Repayment r, String parentDir) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x2, Gap.x2, Gap.x4),
      children: [
        Center(
          child: Text(appState.money(r.amount),
              style: const TextStyle(
                  fontSize: 32, fontWeight: FontWeight.bold)),
        ),
        Center(
          child: Text(s.get('kind_repayIn'),
              style: Theme.of(context).textTheme.bodyMedium),
        ),
        const SizedBox(height: Gap.x2),
        _row(s.get('date'), appState.formatDate(r.date)),
        _row(parentDir,
            '${appState.money(widget.record.originalAmount)} · ${widget.person.name}'),
        if (r.note.isNotEmpty) _row(s.get('note'), r.note),
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _editForm(Strings s) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x2, Gap.x2, Gap.x4),
      children: [
        TextField(
          controller: _amountCtrl,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
          ],
          style:
              const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            labelText: s.get('amount'),
            prefixText: '${appState.settings.currency} ',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.x1),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.calendar_today_outlined),
          title: Text(s.get('date')),
          subtitle: Text(appState.formatDate(_date)),
          onTap: _pickDate,
        ),
        TextField(
          controller: _noteCtrl,
          decoration: InputDecoration(
            labelText: s.get('note'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.x3),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52)),
          child: Text(s.get('save'),
              style: const TextStyle(fontSize: 18)),
        ),
        TextButton(
          onPressed: () => setState(() => _editing = false),
          child: Text(s.get('cancel')),
        ),
      ],
    );
  }
}
