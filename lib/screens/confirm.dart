import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/account.dart';
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
  final _recorder = AudioRecorder();
  AudioPlayer? _player;

  String _purpose = 'uncategorized';
  String? _suggestedPurpose;
  String? _suggestionReason;
  MerchantAlias? _aliasSuggestion;
  List<CustomPurpose> _customs = [];
  late TxnKind _kind;
  DateTime _date = DateTime.now();
  // Money account: prefilled with the default, one tap to switch.
  List<Account> _accounts = [];
  String? _accountId;
  bool _saving = false;
  // Voice note state: recording + speech-to-text run in parallel.
  // `_voiceText` (transcript) is a dedicated field — NEVER mixed into
  // the typed note (`_noteCtrl`).
  bool _recording = false;
  Timer? _recTimer;
  int _recSecs = 0;
  String _voiceText = '';
  String _partial = '';
  String? _savedAudioPath; // recording that belongs to the edited txn
  String? _pendingAudioPath; // recording made in this session, not yet saved
  bool _playing = false;
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
      _voiceText = e.voiceNote ?? '';
      _savedAudioPath = e.audioPath;
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
      // Note prefill: ONLY a genuine description printed on the
      // receipt. The reference goes to the bank-reference field (see
      // _save) and the sender/rail labels ("1LINK IBFT") go nowhere —
      // the note is the user's own "what was this for", and starting
      // it with bank furniture ("Ref 534946 · 1LINK IBFT") pollutes
      // the one field that is purely his.
      if (_noteCtrl.text.isEmpty &&
          r.description != null &&
          r.description!.isNotEmpty) {
        _noteCtrl.text = r.description!;
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
    _accountId = e?.accountId ?? appState.settings.defaultAccountId;
    _loadAccounts();
  }

  /// The picker list: always real accounts; the preferred id (the edited
  /// transaction's, or the default) wins when it still exists.
  Future<void> _loadAccounts() async {
    final accounts = await YaadDb.accounts();
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _accountId = resolveDefaultAccountId(
          accounts, _accountId ?? appState.settings.defaultAccountId);
    });
  }

  Future<void> _loadCustoms() async {
    final customs = await YaadDb.customPurposes();
    if (!mounted) return;
    setState(() => _customs = customs);
  }

  /// Creates a money account from right here in the picker — the user
  /// must never have to abandon a half-filled entry (or a scanned
  /// receipt) to detour through Settings → Accounts. On success the
  /// new account is selected for this entry; every other field is
  /// untouched. Same rules as the Accounts screen: blank name →
  /// 'emptyAccountName' message; duplicate (case-insensitive) →
  /// YaadDb.insertAccount throws StateError, we show the same
  /// 'accountExists' message AND select the existing account, since
  /// that is the account the user means for this entry.
  Future<void> _addAccount() async {
    final s = Strings(appState.settings.language);
    // The dialog owns its controllers (see _AddAccountDialog):
    // disposing them here, the moment showDialog's future resolves,
    // races the dialog's exit animation — its fields rebuild once
    // more with dead controllers ("used after being disposed").
    final result = await showDialog<({String name, double balance})>(
      context: context,
      builder: (_) => _AddAccountDialog(strings: s),
    );
    if (result == null || !mounted) return;
    final name = result.name;
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('emptyAccountName'))));
      return;
    }
    try {
      final a = await YaadDb.insertAccount(name,
          openingBalance: result.balance);
      if (!mounted) return;
      await _loadAccounts();
      if (!mounted) return;
      setState(() => _accountId = a.id);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s
              .get('accountAdded')
              .replaceFirst('{name}', a.displayName(s)))));
    } on StateError {
      if (!mounted) return;
      await _loadAccounts();
      if (!mounted) return;
      final needle = name.toLowerCase();
      for (final a in _accounts) {
        if (a.name.toLowerCase() == needle) {
          setState(() => _accountId = a.id);
          break;
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('accountExists'))));
    }
  }

  /// Creates a custom purpose from the "+ New" tile and selects it.
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
    _recTimer?.cancel();
    _speech.cancel();
    _player?.dispose();
    if (_recording) {
      // Left mid-recording: stop it and throw the file away.
      final path = _pendingAudioPath;
      unawaited(_recorder
          .stop()
          .then((_) => _deleteFile(path))
          .catchError((_) => null));
    } else {
      // An unsaved recording never leaves junk behind.
      final pending = _pendingAudioPath;
      if (pending != null && pending != _savedAudioPath) {
        unawaited(_deleteFile(pending));
      }
    }
    _recorder.dispose();
    super.dispose();
  }

  /// Voice note: two taps — mic to start, stop to finish. Records real
  /// audio (.m4a saved in the app folder) AND transcribes in parallel.
  /// The transcript lands in its own dedicated field, never in the
  /// typed note. If transcription fails, the recording is still kept.
  Future<void> _toggleMic() async {
    final s = Strings(appState.settings.language);
    if (_recording) {
      await _stopRecording();
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
    String path;
    try {
      final dir =
          Directory('${(await getApplicationDocumentsDirectory()).path}/voice_notes');
      if (!await dir.exists()) await dir.create(recursive: true);
      path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.get('micDenied'))));
      }
      return;
    }

    // The recorder is rolling — only NOW swap out any earlier
    // in-session take and its transcript. Doing this before start
    // meant a failed start destroyed a recording the user had
    // already made in this session.
    final oldPending = _pendingAudioPath;
    _pendingAudioPath = path;
    _voiceText = '';
    _partial = '';
    if (oldPending != null && oldPending != path) {
      await _deleteFile(oldPending);
    }

    // Transcription runs in parallel with recording. When the speech
    // engine can't start (no network, unsupported device), the
    // recording is still kept — the field says so plainly.
    try {
      final available = await _speech.initialize();
      if (available && mounted) {
        await _speech.listen(
          onResult: (res) {
            if (!mounted || !_recording) return;
            setState(() {
              if (res.finalResult) {
                final words = res.recognizedWords.trim();
                if (words.isNotEmpty) {
                  _voiceText =
                      _voiceText.isEmpty ? words : '$_voiceText $words';
                }
                _partial = '';
              } else {
                _partial = res.recognizedWords;
              }
            });
          },
          listenOptions: stt.SpeechListenOptions(
            localeId:
                appState.settings.language == 'ur' ? 'ur_PK' : 'en_PK',
          ),
        );
      }
    } catch (_) {
      // Transcription unavailable — the recording is still kept.
    }

    if (!mounted) {
      await _recorder.stop().catchError((_) => null);
      await _deleteFile(path);
      return;
    }
    setState(() {
      _recording = true;
      _recSecs = 0;
      _pendingAudioPath = path;
    });
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _recording) setState(() => _recSecs++);
    });
  }

  /// Deletes a local file, quietly ignoring a missing one.
  Future<void> _deleteFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<void> _stopRecording() async {
    _recTimer?.cancel();
    _recTimer = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      await _speech.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _recording = false;
      _partial = '';
    });
  }

  /// The recording currently attached to this transaction (saved or new).
  String? get _activeAudioPath => _pendingAudioPath ?? _savedAudioPath;

  /// Plays / stops the attached recording.
  Future<void> _togglePlay() async {
    final path = _activeAudioPath;
    if (path == null) return;
    final player = _player ??= AudioPlayer();
    if (_playing) {
      await player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    player.onPlayerComplete.first.then((_) {
      if (mounted) setState(() => _playing = false);
    });
    try {
      await player.play(DeviceFileSource(path));
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(Strings(appState.settings.language)
                .get('voicePlayFailed'))));
      }
    }
  }

  /// Removes the attached recording (and its transcript) from this
  /// form. An in-session recording's file is deleted right away; a
  /// previously SAVED recording's file is only deleted when the edit
  /// is saved (see [_save]) — deleting it here would orphan the file
  /// path still stored on the transaction if the user backs out of
  /// the editor without saving.
  Future<void> _discardVoice() async {
    if (_playing) {
      await _player?.stop();
      _playing = false;
    }
    await _deleteFile(_pendingAudioPath);
    if (mounted) {
      setState(() {
        _pendingAudioPath = null;
        _savedAudioPath = null;
        _voiceText = '';
        _partial = '';
      });
    }
  }

  String _fmtSecs(int v) =>
      '${(v ~/ 60).toString().padLeft(2, '0')}:${(v % 60).toString().padLeft(2, '0')}';

  /// Recording in progress: red indicator, live timer, live transcript
  /// preview, Stop button.
  Widget _buildRecordingCard(Strings s) {
    final live =
        '${_voiceText}${_partial.isEmpty ? '' : ' $_partial'}'.trim();
    return Container(
      padding: const EdgeInsets.all(Gap.x1 + 4),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.error),
        borderRadius: BorderRadius.circular(Radius.chip),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.fiber_manual_record,
                  color: Colors.red, size: 14),
              const SizedBox(width: 8),
              Text(_fmtSecs(_recSecs),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.red)),
              const SizedBox(width: 8),
              Text(s.get('voiceNote'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              FilledButton.tonal(
                onPressed: _toggleMic,
                child: Text(s.get('voiceStop')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            live.isEmpty ? s.get('voiceRecordingHint') : live,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  /// Voice note attached: read-only transcript + playback + remove.
  Widget _buildVoiceCard(Strings s) {
    return Container(
      padding: const EdgeInsets.all(Gap.x1 + 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radius.chip),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(s.get('voiceNote'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_activeAudioPath != null)
                IconButton(
                  tooltip:
                      _playing ? s.get('voiceStopPlaying') : s.get('voicePlay'),
                  icon: Icon(_playing
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline),
                  onPressed: _togglePlay,
                ),
              IconButton(
                tooltip: s.get('voiceDiscard'),
                icon: const Icon(Icons.delete_outline),
                onPressed: _discardVoice,
              ),
            ],
          ),
          if (_voiceText.isNotEmpty)
            Text(_voiceText,
                style: Theme.of(context).textTheme.bodyMedium)
          else
            Text(s.get('voiceNoTranscript'),
                style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.secondary)),
        ],
      ),
    );
  }

  Future<void> _save({required bool needsReview}) async {
    if (_saving) return;
    // Saving mid-recording would store a half-written audio file —
    // stop first so the recording is complete on disk.
    if (_recording) await _stopRecording();
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Strings(appState.settings.language).get('enterAmount'))));
      return;
    }
    // A pasted or fat-fingered string of digits parses to an absurd
    // (or infinite) double — never store it as a real transaction.
    if (!amount.isFinite || amount >= 100000000) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Strings(appState.settings.language).get('amountTooBig'))));
      return;
    }
    setState(() => _saving = true);
    String? audioPath;
    try {
    final merchant = _merchantCtrl.text.trim();
    final aliasText = _aliasCtrl.text.trim();
    String? aliasId;
    if (merchant.isNotEmpty && aliasText.isNotEmpty) {
      await YaadDb.upsertAlias(merchant, aliasText);
      aliasId = (await YaadDb.aliasFor(merchant))?.id;
    }

    // Voice note: keep the new recording, drop the replaced one.
    // Transcript and typed note stay in their own separate fields.
    final e = widget.editing;
    audioPath = _pendingAudioPath ?? _savedAudioPath;
    if (e != null && e.audioPath != null && e.audioPath != audioPath) {
      // The saved recording was replaced or removed in this edit.
      // Its file is deleted only now — at save time — so backing out
      // of the editor never leaves the stored row pointing at a
      // deleted file.
      await _deleteFile(e.audioPath);
    }
    if (audioPath != null && !await File(audioPath).exists()) {
      audioPath = null;
    }
    final voiceNote =
        _voiceText.trim().isEmpty ? null : _voiceText.trim();

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
        audioPath: audioPath,
        voiceNote: voiceNote,
        accountId: _accountId,
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
        audioPath: audioPath,
        voiceNote: voiceNote,
        accountId: _accountId,
        receiptPath: r?.imagePath,
        bankReference: r?.reference,
        source: r != null
            ? (r.imagePath != null ? TxnSource.ocr : TxnSource.share)
            : TxnSource.manual,
        status: needsReview ? TxnStatus.needsReview : TxnStatus.confirmed,
      ));
    }
    } catch (_) {
      // A failed save must never wedge the screen on the spinner with
      // both buttons dead — re-enable and tell the user, keeping
      // everything they typed.
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(Strings(appState.settings.language).get('saveFailed'))));
      }
      return;
    }
    // The recording is now saved with the transaction — it is no longer
    // "pending", so dispose() must not delete it as unsaved junk. (Bug:
    // without this, closing the screen deleted the just-saved recording
    // and playback in the view screen pointed at a missing file.)
    _savedAudioPath = audioPath;
    _pendingAudioPath = null;
    appState.refresh();
    if (mounted) {
      // If the saved date falls outside the period Home is currently
      // showing, Home's figures will not move and the save looks lost
      // (user-reported: a September entry "did nothing" to October's
      // totals). Say where it went — the month of the saved date.
      // Saves inside the displayed period get no extra message.
      final (fromMs, toMs) = appState.periodRangeMs();
      final dateMs = _date.millisecondsSinceEpoch;
      if (dateMs < fromMs || dateMs > toMs) {
        final s = Strings(appState.settings.language);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(s
                .get('savedInMonth')
                .replaceFirst('{month}', s.monthFull(_date.month)))));
      }
      Navigator.of(context).pop();
    }
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
        // Extra bottom clearance: the last actions (Save / Save
        // without note) are in-flow at the end of this list, and at
        // max scroll they must sit well clear of the screen's bottom
        // edge (and the keyboard, which shrinks this viewport) —
        // never kissing the edge the way Home's last card sat under
        // the floating Add button.
        padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x2, Gap.x2, Gap.x4),
        children: [
          if (r?.imagePath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(Radius.tile),
              child: Image.file(File(r!.imagePath!),
                  height: 160,
                  fit: BoxFit.cover,
                  // The file can be gone (share-sheet temp cleaned up):
                  // collapse quietly instead of a broken-image box.
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
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
          // Account picker: which money this is. Prefilled with the
          // default — one tap to switch, then Save as usual (≤ 2 taps).
          Text(s.get('account'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: Gap.x1),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in _accounts)
                ChoiceChip(
                  label: Text(a.displayName(s)),
                  selected: _accountId == a.id,
                  onSelected: (_) =>
                      setState(() => _accountId = a.id),
                ),
              // Create an account without leaving this entry.
              ActionChip(
                key: const Key('addAccountChip'),
                avatar: const Icon(Icons.add, size: 18),
                label: Text(s.get('addAccount')),
                onPressed: _addAccount,
              ),
            ],
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
            newTileLabel: s.get('newPurpose'),
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
              tooltip: _recording ? s.get('voiceStop') : s.get('voiceRecord'),
              icon: Icon(_recording ? Icons.mic : Icons.mic_none_outlined,
                  color: _recording
                      ? Theme.of(context).colorScheme.error
                      : null),
              onPressed: _toggleMic,
            ),
          ),
          // Voice note: its own read-only field, separate from the typed
          // note above. Appears while recording or when a recording is
          // attached (new or from the edited transaction).
          if (_recording) ...[
            const SizedBox(height: Gap.x1),
            _buildRecordingCard(s),
          ] else if (_activeAudioPath != null || _voiceText.isNotEmpty) ...[
            const SizedBox(height: Gap.x1),
            _buildVoiceCard(s),
          ],
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

/// The "+ New account" name + opening-balance dialog. Owns its text
/// controllers and disposes them from State.dispose — i.e. only once
/// the dialog route (including its exit animation) is fully gone.
/// Pops with the trimmed name and the parsed balance; garbage in the
/// balance field (unparseable / negative / absurd) parses as 0,
/// exactly like leaving it blank.
class _AddAccountDialog extends StatefulWidget {
  final Strings strings;
  const _AddAccountDialog({required this.strings});

  @override
  State<_AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<_AddAccountDialog> {
  final _nameCtrl = TextEditingController();
  final _balCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _balCtrl.dispose();
    super.dispose();
  }

  double get _balance {
    final v = double.tryParse(_balCtrl.text.replaceAll(',', '')) ?? 0;
    return (v.isFinite && v > 0 && v < 1000000000000) ? v : 0;
  }

  void _submit() => Navigator.of(context)
      .pop((name: _nameCtrl.text.trim(), balance: _balance));

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    return AlertDialog(
      title: Text(s.get('addAccount')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: s.get('account'),
              hintText: s.get('accountNameHint'),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: Gap.x1 + 4),
          TextField(
            controller: _balCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
            ],
            decoration: InputDecoration(
              labelText: s.get('openingBalance'),
              prefixText: '${appState.settings.currency} ',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.get('cancel'))),
        FilledButton(onPressed: _submit, child: Text(s.get('save'))),
      ],
    );
  }
}
