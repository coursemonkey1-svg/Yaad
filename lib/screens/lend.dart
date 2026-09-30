import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/person.dart';
import '../models/transaction.dart';

/// "I lent money" and "Someone repaid me".
/// Repayments suggest an open balance to link — the user always confirms.
class LendScreen extends StatefulWidget {
  final bool isRepayment;
  const LendScreen({super.key, this.isRepayment = false});

  @override
  State<LendScreen> createState() => _LendScreenState();
}

class _LendScreenState extends State<LendScreen> {
  final _personCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  List<Person> _people = [];
  Person? _selectedPerson;
  bool _owedToMe = true; // lending out vs borrowing
  LendingType _type = LendingType.loan;
  LendingRecord? _linkTarget; // repayment link suggestion
  double _linkRemaining = 0;
  bool _saving = false;

  bool get isRepay => widget.isRepayment;

  @override
  void initState() {
    super.initState();
    YaadDb.people().then((p) {
      if (mounted) setState(() => _people = p);
    });
  }

  @override
  void dispose() {
    _personCtrl.dispose();
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _onPersonChanged() async {    final name = _personCtrl.text.trim();
    _selectedPerson = null;
    _linkTarget = null;
    if (name.isEmpty) {
      setState(() {});
      return;
    }
    for (final p in _people) {
      if (p.name.toLowerCase() == name.toLowerCase()) {
        _selectedPerson = p;
        break;
      }
    }
    if (isRepay && _selectedPerson != null) {
      final open = await YaadDb.openLendingForPerson(_selectedPerson!.id,
          owedToMe: _owedToMe);
      if (open.isNotEmpty && mounted) {
        final first = open.first;
        final repaid = await YaadDb.totalRepaid(first.id);
        setState(() {
          _linkTarget = first;
          _linkRemaining = first.originalAmount - repaid;
        });
      } else {
        setState(() {});
      }
    } else {
      setState(() {});
    }
  }

  List<Person> _matches() {
    final q = _personCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return [];
    return _people
        .where((p) => p.name.toLowerCase().contains(q))
        .take(5)
        .toList();
  }

  Future<void> _save() async {
    if (_saving) return;
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
    final name = _personCtrl.text.trim();
    if (amount <= 0 || name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter who and how much.')));
      return;
    }
    setState(() => _saving = true);
    final person = _selectedPerson ?? await YaadDb.findOrCreatePerson(name);
    final now = DateTime.now();

    if (isRepay) {
      if (_linkTarget == null) {
        // No open balance: just record the money-in transaction.
        await YaadDb.insertTxn(YaadTransaction(
          amount: amount,
          currency: appState.settings.currency,
          dateTime: now,
          direction: TxnDirection.incoming,
          rawMerchant: person.name,
          purpose: 'repaymentIn',
          note: _reasonCtrl.text.trim(),
          personId: person.id,
          source: TxnSource.manual,
        ));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Recorded. No open balance to link.')));
        }
      } else {
        final remaining = await YaadDb.addRepayment(Repayment(
          lendingId: _linkTarget!.id,
          amount: amount,
          date: now,
          note: _reasonCtrl.text.trim(),
        ));
        await YaadDb.insertTxn(YaadTransaction(
          amount: amount,
          currency: appState.settings.currency,
          dateTime: now,
          direction:
              _owedToMe ? TxnDirection.incoming : TxnDirection.out,
          rawMerchant: person.name,
          purpose: 'repaymentIn',
          note: _reasonCtrl.text.trim(),
          personId: person.id,
          linkedLendingId: _linkTarget!.id,
          source: TxnSource.manual,
        ));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(remaining <= 0
                  ? 'Settled! Balance is zero.'
                  : 'Linked. ${appState.money(remaining)} remaining.')));
        }
      }
    } else {
      await YaadDb.insertLending(LendingRecord(
        personId: person.id,
        type: _type,
        originalAmount: amount,
        currency: appState.settings.currency,
        date: now,
        reason: _reasonCtrl.text.trim(),
        isOwedToMe: _owedToMe,
      ));
      // The outflow itself, so spending stays honest.
      await YaadDb.insertTxn(YaadTransaction(
        amount: amount,
        currency: appState.settings.currency,
        dateTime: now,
        direction: _owedToMe ? TxnDirection.out : TxnDirection.incoming,
        rawMerchant: person.name,
        purpose: _type == LendingType.gift ? 'gift' : 'loan',
        note: _reasonCtrl.text.trim(),
        personId: person.id,
        source: TxnSource.manual,
      ));
    }
    appState.refresh();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return Scaffold(
      appBar: AppBar(
          title: Text(isRepay
              ? s.get('someoneRepaidMe')
              : s.get('iLentMoney'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Who — type a name, tap a known person if they appear.
          TextField(
            controller: _personCtrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: s.get('who'),
              hintText: 'e.g. Ahmed',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.person_outline),
            ),
            onChanged: (_) => _onPersonChanged(),
          ),
          if (_matches().isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _matches()
                  .map((p) => ActionChip(
                        label: Text(p.name),
                        avatar: const Icon(Icons.person, size: 16),
                        onPressed: () {
                          _personCtrl.text = p.name;
                          _onPersonChanged();
                        },
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _amountCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
            ],
            style: const TextStyle(
                fontSize: 32, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              labelText: s.get('howMuch'),
              prefixText: '${appState.settings.currency} ',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (!isRepay) ...[
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: true, label: Text('They owe me')),
                ButtonSegment(
                    value: false, label: Text('I owe them')),
              ],
              selected: {_owedToMe},
              onSelectionChanged: (v) =>
                  setState(() => _owedToMe = v.first),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: LendingType.values
                  .map((t) => ChoiceChip(
                        label: Text(_typeLabel(t)),
                        selected: _type == t,
                        onSelected: (_) =>
                            setState(() => _type = t),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
          ] else ...[
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: true, label: Text('They repaid me')),
                ButtonSegment(
                    value: false, label: Text('I repaid them')),
              ],
              selected: {_owedToMe},
              onSelectionChanged: (v) {
                setState(() => _owedToMe = v.first);
                _onPersonChanged();
              },
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _reasonCtrl,
            decoration: InputDecoration(
              labelText: s.get('reason'),
              border: const OutlineInputBorder(),
            ),
          ),
          // Repayment link suggestion — always requires confirmation.
          if (isRepay && _linkTarget != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Link to the open ${appState.money(_linkTarget!.originalAmount)} '
                      'balance (${appState.money(_linkRemaining)} left)?',
                      style:
                          const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _linkTarget = null),
                    child: const Text("Don't link"),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52)),
            child: _saving
                ? const CircularProgressIndicator()
                : Text(s.get('save'),
                    style: const TextStyle(fontSize: 18)),
          ),
        ],
      ),
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
}
