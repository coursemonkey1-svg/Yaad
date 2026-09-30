import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/alias.dart';
import '../models/transaction.dart';
import '../services/ocr.dart';
import '../services/suggest.dart';
import '../widgets/note_field.dart';
import '../widgets/purpose_grid.dart';

/// The confirmation card: amount / merchant / date prefilled from the
/// receipt, one-tap purpose, optional note + voice, Save.
/// Used for: shared receipts, OCR images, manual entry, and editing.
class ConfirmScreen extends StatefulWidget {
  final OcrResult? initial;
  final YaadTransaction? editing;
  const ConfirmScreen({super.key, this.initial, this.editing});

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  final _amountCtrl = TextEditingController();
  final _merchantCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _aliasCtrl = TextEditingController();
  final _suggest = SuggestionService();

  String _purpose = 'uncategorized';
  String? _suggestedPurpose;
  String? _suggestionReason;
  MerchantAlias? _aliasSuggestion;
  bool _isOut = true;
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    final r = widget.initial;
    if (e != null) {
      _amountCtrl.text = e.amount.toStringAsFixed(
          e.amount.truncateToDouble() == e.amount ? 0 : 2);
      _merchantCtrl.text = e.rawMerchant;
      _noteCtrl.text = e.note;
      _purpose = e.purpose;
      _isOut = e.direction == TxnDirection.out;
      _date = e.dateTime;
      _loadAlias(e.rawMerchant);
    } else if (r != null) {
      if (r.amount != null) {
        _amountCtrl.text = r.amount!.toStringAsFixed(
            r.amount!.truncateToDouble() == r.amount! ? 0 : 2);
      }
      if (r.merchant != null) {
        _merchantCtrl.text = r.merchant!;
        _loadAlias(r.merchant!);
        _loadSuggestion(r.merchant!);
      }
      if (r.date != null) _date = r.date!;
    }
  }

  Future<void> _loadAlias(String raw) async {
    final a = await YaadDb.aliasFor(raw);
    if (!mounted) return;
    if (a != null) {
      setState(() => _aliasCtrl.text = a.alias);
    } else {
      final sug = await _suggest.suggestAlias(raw);
      if (mounted) setState(() => _aliasSuggestion = sug);
    }
  }

  Future<void> _loadSuggestion(String raw) async {
    if (!appState.settings.smartSuggestions) return;
    final s = await _suggest.suggestPurpose(raw);
    if (mounted && s != null) {
      setState(() {
        _suggestedPurpose = s.purpose;
        _suggestionReason = s.reason;
      });
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _merchantCtrl.dispose();
    _noteCtrl.dispose();
    _aliasCtrl.dispose();
    super.dispose();
  }

  Future<void> _save({required bool needsReview}) async {
    if (_saving) return;
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter an amount.')));
      return;
    }
    setState(() => _saving = true);
    final merchant = _merchantCtrl.text.trim();
    final aliasText = _aliasCtrl.text.trim();
    String? aliasId;
    if (merchant.isNotEmpty && aliasText.isNotEmpty) {
      await YaadDb.upsertAlias(merchant, aliasText);
      aliasId = (await YaadDb.aliasFor(merchant))?.id;
    }

    final e = widget.editing;
    if (e != null) {
      await YaadDb.updateTxn(e.copyWith(
        amount: amount,
        dateTime: _date,
        direction: _isOut ? TxnDirection.out : TxnDirection.incoming,
        rawMerchant: merchant,
        aliasId: aliasId ?? e.aliasId,
        purpose: _purpose,
        note: _noteCtrl.text.trim(),
        status: needsReview ? TxnStatus.needsReview : TxnStatus.confirmed,
      ));
    } else {
      final r = widget.initial;
      // Duplicate guard for receipt imports.
      if (r != null) {
        final dup = await YaadDb.findDuplicate(
          bankReference: r.reference,
          amount: amount,
          rawMerchant: merchant,
          date: _date,
        );
        if (dup != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Already recorded — skipped duplicate.')));
          setState(() => _saving = false);
          Navigator.of(context).pop();
          return;
        }
      }
      await YaadDb.insertTxn(YaadTransaction(
        amount: amount,
        currency: appState.settings.currency,
        dateTime: _date,
        direction: _isOut ? TxnDirection.out : TxnDirection.incoming,
        rawMerchant: merchant,
        aliasId: aliasId,
        purpose: _purpose,
        note: _noteCtrl.text.trim(),
        receiptPath: r?.imagePath,
        bankReference: r?.reference,
        source: r != null
            ? (r.imagePath != null ? TxnSource.ocr : TxnSource.share)
            : TxnSource.manual,
        status: needsReview ? TxnStatus.needsReview : TxnStatus.confirmed,
      ));
    }
    appState.refresh();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d != null) setState(() => _date = d);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final r = widget.initial;
    final isEdit = widget.editing != null;
    return Scaffold(
      appBar: AppBar(
          title: Text(isEdit ? s.get('edit') : s.get('capture'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (r?.imagePath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(File(r!.imagePath!),
                  height: 160, fit: BoxFit.cover),
            ),
          if (r?.imagePath != null) const SizedBox(height: 12),
          // Amount — big, first, numeric keyboard.
          TextField(
            controller: _amountCtrl,
            autofocus: r?.amount == null && !isEdit,
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _merchantCtrl,
                  decoration: InputDecoration(
                    labelText: s.get('merchant'),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    if (v.trim().length > 2) _loadSuggestion(v);
                  },
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 16),
                  decoration: BoxDecoration(
                      border: Border.all(
                          color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(appState.formatDate(_date)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Direction toggle.
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                  value: true,
                  label: Text(s.get('moneyOut')),
                  icon: const Icon(Icons.arrow_upward)),
              ButtonSegment(
                  value: false,
                  label: Text(s.get('moneyIn')),
                  icon: const Icon(Icons.arrow_downward)),
            ],
            selected: {_isOut},
            onSelectionChanged: (v) =>
                setState(() => _isOut = v.first),
          ),
          const SizedBox(height: 16),
          Text(s.get('purpose'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          PurposeGrid(
            selected: _purpose,
            onSelect: (p) => setState(() => _purpose = p),
            suggested: _suggestedPurpose,
            suggestionReason: _suggestionReason,
          ),
          const SizedBox(height: 12),
          // Alias: your own recognizable name.
          TextField(
            controller: _aliasCtrl,
            decoration: InputDecoration(
              labelText: s.get('aliasFor'),
              hintText: 'e.g. corner grocery near home',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.label_outline),
            ),
          ),
          if (_aliasSuggestion != null) ...[
            const SizedBox(height: 4),
            InkWell(
              onTap: () => setState(() {
                _aliasCtrl.text = _aliasSuggestion!.alias;
                _aliasSuggestion = null;
              }),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                  'Did you mean "${_aliasSuggestion!.alias}"? Tap to use.',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          NoteField(controller: _noteCtrl),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : () => _save(needsReview: false),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52)),
            child: _saving
                ? const CircularProgressIndicator()
                : Text(s.get('save'),
                    style: const TextStyle(fontSize: 18)),
          ),
          const SizedBox(height: 8),
          if (!isEdit)
            TextButton(
              onPressed: _saving ? null : () => _save(needsReview: true),
              child: Text(s.get('saveWithoutNote')),
            ),
        ],
      ),
    );
  }
}
