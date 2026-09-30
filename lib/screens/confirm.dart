import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/alias.dart';
import '../models/custom_purpose.dart';
import '../models/purposes.dart';
import '../models/transaction.dart';
import '../services/ocr.dart';
import '../services/suggest.dart';
import '../theme.dart';
import '../widgets/note_field.dart';
import '../widgets/purpose_dialogs.dart';
import '../widgets/purpose_grid.dart';

/// The confirmation card: amount / merchant / date prefilled from the
/// receipt, one-tap purpose, optional note + voice, Save.
/// Used for: shared receipts, OCR images, manual entry, and editing.
/// Kind-aware (§2): "I spent" / "I received" select which bucket the
/// money lands in — never just +/−.
class ConfirmScreen extends StatefulWidget {
  final OcrResult? initial;
  final YaadTransaction? editing;
  final TxnKind initialKind;

  const ConfirmScreen(
      {super.key, this.initial, this.editing, this.initialKind = TxnKind.spend});

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  final _amountCtrl = TextEditingController();
  final _merchantCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _aliasCtrl = TextEditingController();
  final _suggest = SuggestionService();
  final _speech = stt.SpeechToText();

  String _purpose = 'uncategorized';
  String? _suggestedPurpose;
  String? _suggestionReason;
  MerchantAlias? _aliasSuggestion;
  List<CustomPurpose> _customs = [];
  late TxnKind _kind;
  DateTime _date = DateTime.now();
  bool _saving = false;
  bool _listening = false;
  // Receipt fields the parser wasn't sure about (< 0.7 confidence).
  List<String> _checkFields = [];

  bool get _isSpend => _kind == TxnKind.spend;

  /// Picker list: the fixed bucket plus the user's own purposes on the
  /// spend side. Custom purposes are spend-only.
  List<Purpose> get _pickerPurposes {
    final base = _isSpend ? kSpendPurposes : kReceiveSources;
    if (!_isSpend) return base;
    return [...base, for (final c in _customs) c.asPurpose];
  }

  Set<String> get _customIds => {for (final c in _customs) c.id};

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    final r = widget.initial;
    _kind = e?.kind ?? widget.initialKind;
    // Lending kinds are recorded on the Udhaar screens, not here.
    if (_kind != TxnKind.spend && _kind != TxnKind.receive) {
      _kind = TxnKind.spend;
    }
    if (e != null) {
      _amountCtrl.text = e.amount.toStringAsFixed(
          e.amount.truncateToDouble() == e.amount ? 0 : 2);
      _merchantCtrl.text = e.rawMerchant;
      _noteCtrl.text = e.note;
      _purpose = e.purpose;
      _date = e.dateTime;
      _loadAlias(e.rawMerchant);
    } else if (r != null) {
      final who = r.recipient ?? r.merchant;
      if (r.amount != null) {
        _amountCtrl.text = r.amount!.toStringAsFixed(
            r.amount!.truncateToDouble() == r.amount! ? 0 : 2);
      }
      if (who != null && who.isNotEmpty) {
        _merchantCtrl.text = who;
        _loadAlias(who);
        _loadSuggestion(who);
      }
      if (r.date != null) _date = r.date!;
      // Receipt context note: sender / reference / channel — only when
      // the note is still empty, so a kept shared-text note is never
      // overwritten.
      if (_noteCtrl.text.isEmpty) {
        final bits = <String>[
          if (r.sender != null && r.sender!.isNotEmpty)
            'From ${r.sender}',
          if (r.reference != null && r.reference!.isNotEmpty)
            'Ref ${r.reference}',
          if (r.transactionTypeRaw != null &&
              r.transactionTypeRaw!.isNotEmpty)
            r.transactionTypeRaw!,
        ];
        if (bits.isNotEmpty) _noteCtrl.text = bits.join(' · ');
      }
      // Never-silent share: nothing parsed → keep the shared text as
      // the note so nothing is lost (§1).
      if (r.amount == null &&
          (who == null || who.isEmpty) &&
          _noteCtrl.text.isEmpty &&
          r.rawText.isNotEmpty) {
        _noteCtrl.text = r.rawText;
      }
      // Subtle "check this" hint for low-confidence fields.
      final conf = r.confidence;
      _checkFields = [
        if (r.amount != null && (conf['amount'] ?? 1) < 0.7) 'amount',
        if (who != null && who.isNotEmpty && (conf['merchant'] ?? 1) < 0.7)
          'merchant',
        if (r.date != null && (conf['date'] ?? 1) < 0.7) 'date',
      ];
    }
    _loadCustoms();
  }

  Future<void> _loadCustoms() async {
    final customs = await YaadDb.customPurposes();
    if (!mounted) return;
    setState(() => _customs = customs);
  }

  /// Creates a custom purpose from the "＋ New" tile and selects it.
  Future<void> _addCustomPurpose() async {
    final s = Strings(appState.settings.language);
    final name = await promptCustomPurposeName(context, s);
    if (name == null || name.isEmpty || !mounted) return;
    if (await YaadDb.purposeLabelExists(name)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('purposeExists'))));
      return;
    }
    final cp = await YaadDb.insertCustomPurpose(name);
    if (!mounted) return;
    setState(() {
      _customs.add(cp);
      _purpose = cp.id;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(s.get('purposeAdded').replaceFirst('{name}', cp.label))));
  }

  /// Deletes a custom purpose (long-press). Its transactions move to
  /// "Other" — never orphaned.
  Future<void> _deleteCustomPurpose(String id) async {
    final s = Strings(appState.settings.language);
    String? label;
    for (final c in _customs) {
      if (c.id == id) {
        label = c.label;
        break;
      }
    }
    if (label == null || !mounted) return;
    final ok = await confirmDeleteCustomPurpose(context, s, label);
    if (!ok || !mounted) return;
    await YaadDb.deleteCustomPurpose(id);
    if (!mounted) return;
    setState(() {
      _customs.removeWhere((c) => c.id == id);
      if (_purpose == id) _purpose = 'uncategorized';
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            s.get('purposeDeleted').replaceFirst('{name}', label))));
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

  /// Voice note: one-line explanation, request at tap-time, guide to
  /// settings on denial (§4 mic fix — manifest already declares it).
  Future<void> _toggleMic() async {
    final s = Strings(appState.settings.language);
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (!status.isGranted) {
      if (status.isPermanentlyDenied) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(s.get('micTitle')),
            content: Text(s.get('micSettingsBody')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(s.get('cancel'))),
              FilledButton(
                  onPressed: () {
                    openAppSettings();
                    Navigator.of(context).pop();
                  },
                  child: Text(s.get('openSettings'))),
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.get('micDenied'))));
      }
      return;
    }
    final available = await _speech.initialize();
    if (!available || !mounted) return;
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (res) {
        _noteCtrl.text = (_noteCtrl.text.isEmpty ? '' : '${_noteCtrl.text} ') +
            res.recognizedWords;
      },
      listenOptions: stt.SpeechListenOptions(
        localeId: appState.settings.language == 'ur' ? 'ur_PK' : 'en_PK',
      ),
    );
    if (mounted) setState(() => _listening = false);
  }

  Future<void> _save({required bool needsReview}) async {
    if (_saving) return;
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Strings(appState.settings.language).get('enterAmount'))));
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
        kind: _kind,
        direction:
            _isSpend ? TxnDirection.out : TxnDirection.incoming,
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
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(Strings(appState.settings.language).get('alreadyRecorded'))));
          setState(() => _saving = false);
          Navigator.of(context).pop();
          return;
        }
      }
      await YaadDb.insertTxn(YaadTransaction(
        amount: amount,
        currency: appState.settings.currency,
        dateTime: _date,
        kind: _kind,
        direction:
            _isSpend ? TxnDirection.out : TxnDirection.incoming,
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

  void _setKind(TxnKind kind) {
    setState(() {
      _kind = kind;
      // Reset to the neutral default of the new bucket.
      _purpose = kind == TxnKind.spend ? 'uncategorized' : 'other_in';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final r = widget.initial;
    final isEdit = widget.editing != null;
    return Scaffold(
      appBar:
          AppBar(title: Text(isEdit ? s.get('edit') : s.get('capture'))),
      body: ListView(
        padding: const EdgeInsets.all(Gap.x2),
        children: [
          if (r?.imagePath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(Radius.tile),
              child: Image.file(File(r!.imagePath!),
                  height: 160, fit: BoxFit.cover),
            ),
          if (r?.imagePath != null) const SizedBox(height: Gap.x1 + 4),
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
          const SizedBox(height: Gap.x1 + 4),
          // Kind selector: which bucket this lands in.
          SegmentedButton<TxnKind>(
            segments: [
              ButtonSegment(
                  value: TxnKind.spend,
                  label: Text(s.get('iSpent')),
                  icon: const Icon(Icons.north_east)),
              ButtonSegment(
                  value: TxnKind.receive,
                  label: Text(s.get('iReceived')),
                  icon: const Icon(Icons.south_west)),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => _setKind(v.first),
          ),
          const SizedBox(height: Gap.x1 + 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _merchantCtrl,
                  decoration: InputDecoration(
                    labelText: _isSpend ? s.get('merchant') : s.get('from'),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    if (v.trim().length > 2) _loadSuggestion(v);
                  },
                ),
              ),
              const SizedBox(width: Gap.x1),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(Radius.chip),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 16),
                  decoration: BoxDecoration(
                      border: Border.all(
                          color: Theme.of(context).dividerColor),
                      borderRadius:
                          BorderRadius.circular(Radius.chip)),
                  child: Text(appState.formatDate(_date)),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.x1),
          // Subtle "check this" hint for low-confidence receipt fields.
          if (_checkFields.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 14,
                      color: Theme.of(context).colorScheme.secondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${s.get('doubleCheck')}: '
                      '${_checkFields.map((f) => s.get(f)).join(', ')}',
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              Theme.of(context).colorScheme.secondary),
                    ),
                  ),
                ],
              ),
            ),
          Text(_isSpend ? s.get('purpose') : s.get('source'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: Gap.x1),
          PurposeGrid(
            purposes: _pickerPurposes,
            selected: _purpose,
            onSelect: (p) => setState(() => _purpose = p),
            suggested: _suggestedPurpose,
            suggestionReason: _suggestionReason,
            customIds: _customIds,
            onAddCustom: _isSpend ? _addCustomPurpose : null,
            newTileLabel: '＋ ${s.get('newPurpose')}',
            onDeleteCustom: _deleteCustomPurpose,
          ),
          // Discoverability: long-press to delete is otherwise invisible.
          if (_isSpend && _customs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(s.get('longPressHint'),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: Gap.x1 + 4),
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
          const SizedBox(height: Gap.x1 + 4),
          NoteField(
            controller: _noteCtrl,
            micButton: IconButton(
              tooltip: s.get('micTitle'),
              icon: Icon(_listening ? Icons.mic : Icons.mic_none_outlined,
                  color: _listening
                      ? Theme.of(context).colorScheme.error
                      : null),
              onPressed: _toggleMic,
            ),
          ),
          const SizedBox(height: Gap.x3),
          FilledButton(
            onPressed: _saving ? null : () => _save(needsReview: false),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52)),
            child: _saving
                ? const CircularProgressIndicator()
                : Text(s.get('save'),
                    style: const TextStyle(fontSize: 18)),
          ),
          const SizedBox(height: Gap.x1),
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
