import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/person.dart';
import '../theme.dart';

/// "I lent money" — one direction only, no toggles (§5).
/// The money is tracked as Udhaar; it never touches spending.
class LendScreen extends StatefulWidget {
  final double? initialAmount;
  final Person? initialPerson;
  const LendScreen({super.key, this.initialAmount, this.initialPerson});

  @override
  State<LendScreen> createState() => _LendScreenState();
}

class _LendScreenState extends State<LendScreen> {
  final _personCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  List<Person> _people = [];
  Person? _selectedPerson;
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialAmount != null) {
      _amountCtrl.text = widget.initialAmount!
          .toStringAsFixed(widget.initialAmount!.truncateToDouble() ==
                  widget.initialAmount!
              ? 0
              : 2);
    }
    if (widget.initialPerson != null) {
      _selectedPerson = widget.initialPerson;
      _personCtrl.text = widget.initialPerson!.name;
    }
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

  List<Person> _matches() {
    final q = _personCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return [];
    // Once a person is picked (text == their name), the suggestion
    // list would only repeat that same person — hide it.
    if (_selectedPerson != null &&
        _selectedPerson!.name.toLowerCase() == q) {
      return [];
    }
    return _people
        .where((p) => p.name.toLowerCase().contains(q))
        .take(5)
        .toList();
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
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
    final name = _personCtrl.text.trim();
    if (amount <= 0 || name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Strings(appState.settings.language).get('whoAndHowMuch'))));
      return;
    }
    setState(() => _saving = true);
    final person = _selectedPerson ?? await YaadDb.findOrCreatePerson(name);
    await YaadDb.insertLending(LendingRecord(
      personId: person.id,
      originalAmount: amount,
      currency: appState.settings.currency,
      date: _date,
      reason: _reasonCtrl.text.trim(),
      isOwedToMe: true,
    ));
    appState.refresh();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return Scaffold(
      appBar: AppBar(title: Text(s.get('iLentMoney'))),
      body: ListView(
        // Bottom clearance so the Save button and the note under it
        // can always scroll clear of the keyboard / screen edge.
        padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x2, Gap.x2, Gap.x4),
        children: [
          Text(s.get('whoDidYouLendTo'),
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.x1),
          TextField(
            controller: _personCtrl,
            decoration: InputDecoration(
              labelText: s.get('personName'),
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.person_outline),
            ),
            onChanged: (_) {
              _selectedPerson = null;
              for (final p in _people) {
                if (p.name.toLowerCase() ==
                    _personCtrl.text.trim().toLowerCase()) {
                  _selectedPerson = p;
                  break;
                }
              }
              setState(() {});
            },
          ),
          for (final m in _matches())
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(m.name),
              onTap: () => setState(() {
                _selectedPerson = m;
                _personCtrl.text = m.name;
              }),
            ),
          const SizedBox(height: Gap.x2),
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
              labelText: s.get('amount'),
              prefixText: '${appState.settings.currency} ',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.x2),
          TextField(
            controller: _reasonCtrl,
            decoration: InputDecoration(
              labelText: s.get('whatFor'),
              hintText: s.get('whatForHint'),
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
          const SizedBox(height: Gap.x3),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52)),
            child: _saving
                ? const CircularProgressIndicator()
                : Text(s.get('save'),
                    style: const TextStyle(fontSize: 18)),
          ),
          const SizedBox(height: Gap.x1),
          Text(
            s.get('udhaarNotSpending'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
