import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/transaction.dart';
import '../models/purposes.dart';
import '../services/txn_display.dart';
import '../theme.dart';
import 'confirm.dart';

/// Human words for where a transaction came from. Public (and static)
/// so widget tests can cover every value in both languages.
String sourceLabel(Strings s, TxnSource source) {
  switch (source) {
    case TxnSource.notification:
      return s.get('sourceBankAlert');
    case TxnSource.share:
      return s.get('sourceShare');
    case TxnSource.ocr:
      return s.get('sourceOcr');
    case TxnSource.statementImport:
      return s.get('sourceImport');
    case TxnSource.sms:
      return s.get('sourceSms');
    case TxnSource.manual:
      return s.get('sourceManual');
  }
}

/// Read-only detail view for one transaction.
///
/// Tapping a transaction card anywhere in the app opens THIS screen, not
/// the editor — accidental edits were the #1 "unprofessional" complaint.
/// The editor ([ConfirmScreen]) is reachable only via the explicit Edit
/// action in the app bar. Sections with no data are hidden entirely:
/// no empty labels, no blank rows.
class TransactionViewScreen extends StatefulWidget {
  final YaadTransaction txn;

  /// Pre-resolved display names. Null (the production path) resolves
  /// them from the database; tests pass them explicitly so widget
  /// tests stay out of sqlite's FakeAsync deadlock.
  final TxnDisplayNames? names;

  const TransactionViewScreen({super.key, required this.txn, this.names});

  @override
  State<TransactionViewScreen> createState() => _TransactionViewScreenState();
}

class _TransactionViewScreenState extends State<TransactionViewScreen> {
  late YaadTransaction _txn;
  AudioPlayer? _player;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _txn = widget.txn;
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<TxnDisplayNames> _loadNames(Strings s) =>
      loadTxnDisplayNames(_txn, s);

  /// The one and only path into the editor: explicit, labeled, on purpose.
  /// After the editor closes, reload the row (it may have changed) — or
  /// pop if the transaction was deleted elsewhere meanwhile.
  Future<void> _openEdit() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ConfirmScreen(editing: _txn)));
    if (!mounted) return;
    final fresh = await YaadDb.txnById(_txn.id);
    if (fresh == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _txn = fresh);
  }

  Future<void> _togglePlay() async {
    final path = _txn.audioPath;
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
            content: Text(
                Strings(appState.settings.language).get('voicePlayFailed'))));
      }
    }
  }

  Color _tint(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (_txn.kind) {
      case TxnKind.spend:
        return cs.error;
      case TxnKind.receive:
        return Colors.green;
      case TxnKind.lendOut:
      case TxnKind.borrowIn:
      case TxnKind.repayOut:
      case TxnKind.repayIn:
        return cs.primary;
      case TxnKind.transfer:
        return cs.onSurfaceVariant;
    }
  }

  /// Signed amount: out-kinds read as −, in-kinds as +. Stored values are
  /// always positive, so the sign is purely presentational.
  String _signedAmount() {
    final out = _txn.kind == TxnKind.spend ||
        _txn.kind == TxnKind.lendOut ||
        _txn.kind == TxnKind.repayOut;
    final incoming = _txn.kind == TxnKind.receive ||
        _txn.kind == TxnKind.borrowIn ||
        _txn.kind == TxnKind.repayIn;
    final prefix = out ? '−' : (incoming ? '+' : '');
    return '$prefix${appState.money(_txn.amount)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final kindName = s.get('kind_${_txn.kind.name}');
    return Scaffold(
      appBar: AppBar(
        title: Text(kindName),
        actions: [
          TextButton.icon(
            key: const Key('txnEditButton'),
            onPressed: _openEdit,
            icon: const Icon(Icons.edit_outlined),
            label: Text(s.get('edit')),
          ),
        ],
      ),
      body: FutureBuilder<TxnDisplayNames>(
        future: widget.names != null
            ? Future<TxnDisplayNames>.value(widget.names!)
            : _loadNames(s),
        builder: (context, snap) {
          final names = snap.data;
          final title = names?.alias ??
              (_txn.rawMerchant.isEmpty ? kindName : _txn.rawMerchant);
          return ListView(
            padding: const EdgeInsets.all(Gap.x2),
            children: [
              _hero(context, s, kindName, title),
              const SizedBox(height: Gap.x2),
              _chips(context, s, names),
              if (_txn.status == TxnStatus.needsReview) ...[
                const SizedBox(height: Gap.x1),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _chip(context, s.get('needsReview'),
                      Theme.of(context).colorScheme.error,
                      icon: Icons.visibility_outlined),
                ),
              ],
              if (names?.personName != null) ...[
                const SizedBox(height: Gap.x2),
                _section(
                  key: const Key('txnPerson'),
                  icon: Icons.person_outline,
                  title: names!.personName!,
                ),
              ],
              if (_txn.note.trim().isNotEmpty) ...[
                const SizedBox(height: Gap.x2),
                _section(
                  key: const Key('txnNote'),
                  icon: Icons.notes_outlined,
                  label: s.get('note'),
                  body: Text(_txn.note.trim(),
                      style: Theme.of(context).textTheme.bodyLarge),
                ),
              ],
              if (_txn.voiceNote?.trim().isNotEmpty == true ||
                  _txn.audioPath != null) ...[
                const SizedBox(height: Gap.x2),
                _voiceCard(context, s),
              ],
              if (_txn.receiptPath != null) ...[
                const SizedBox(height: Gap.x2),
                _section(
                  key: const Key('txnReceipt'),
                  icon: Icons.receipt_long_outlined,
                  body: ClipRRect(
                    borderRadius: BorderRadius.circular(Radius.tile),
                    child: Image.file(
                      File(_txn.receiptPath!),
                      height: 220,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
              if (_txn.bankReference?.trim().isNotEmpty == true) ...[
                const SizedBox(height: Gap.x2),
                _section(
                  key: const Key('txnBankRef'),
                  icon: Icons.tag_outlined,
                  label: s.get('bankRef'),
                  body: SelectableText(
                    _txn.bankReference!.trim(),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ],
              const SizedBox(height: Gap.x3),
            ],
          );
        },
      ),
    );
  }

  /// Big prominent amount, merchant title, date + time.
  Widget _hero(BuildContext context, Strings s, String kindName, String title) {
    final cs = Theme.of(context).colorScheme;
    final tint = _tint(context);
    final timeOfDay = MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(_txn.dateTime));
    return Container(
      key: const Key('txnHero'),
      padding: const EdgeInsets.all(Gap.x3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radius.card),
        border: Border.all(color: tint.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _signedAmount(),
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w800,
              color: tint,
              height: 1.15,
            ),
          ),
          const SizedBox(height: Gap.x1),
          Text(
            title,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, height: 1.3),
          ),
          const SizedBox(height: 4),
          Text(
            '${appState.formatDate(_txn.dateTime)} · $timeOfDay',
            style: TextStyle(
                fontSize: 13.5, color: cs.onSurfaceVariant, height: 1.4),
          ),
        ],
      ),
    );
  }

  /// Kind + purpose + account + source, in one wrapping row.
  Widget _chips(BuildContext context, Strings s, TxnDisplayNames? names) {
    final cs = Theme.of(context).colorScheme;
    final tint = _tint(context);
    final purpose = s.find('purpose_${_txn.purpose}') ??
        purposeLabel(_txn.purpose);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip(context, s.get('kind_${_txn.kind.name}'), tint),
        _chip(context, purpose, cs.onSurfaceVariant),
        _chip(context, names?.accountLabel ?? '', cs.tertiary,
            icon: Icons.account_balance_wallet_outlined),
        _chip(context, sourceLabel(s, _txn.source),
            _txn.source == TxnSource.manual ? cs.onSurfaceVariant : tint,
            icon: _txn.source == TxnSource.manual
                ? Icons.edit_outlined
                : Icons.account_balance_outlined),
      ],
    );
  }

  Widget _chip(BuildContext context, String label, Color tint,
      {IconData? icon}) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(Radius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: tint),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: tint,
                  height: 1.2)),
        ],
      ),
    );
  }

  /// A labeled detail block. Only built when the caller has data —
  /// callers never render empty labels.
  Widget _section(
      {Key? key,
      required IconData icon,
      String? label,
      String? title,
      Widget? body}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: key,
      padding: const EdgeInsets.all(Gap.x2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radius.tile),
        border:
            Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (label != null)
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurfaceVariant,
                          height: 1.3)),
                if (label != null && (title != null || body != null))
                  const SizedBox(height: 4),
                if (title != null)
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 1.35)),
                if (body != null) body,
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Voice note: transcript text + playback of the saved recording.
  /// Shown when either the transcript or the recording exists; the play
  /// button only appears when there is a file to play.
  Widget _voiceCard(BuildContext context, Strings s) {
    final cs = Theme.of(context).colorScheme;
    final transcript = _txn.voiceNote?.trim() ?? '';
    return Container(
      key: const Key('txnVoice'),
      padding: const EdgeInsets.all(Gap.x2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radius.tile),
        border:
            Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_txn.audioPath != null)
            IconButton(
              key: const Key('txnVoicePlay'),
              tooltip: _playing ? s.get('voiceStopPlaying') : s.get('voicePlay'),
              icon: Icon(
                  _playing
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline,
                  size: 32,
                  color: cs.primary),
              onPressed: _togglePlay,
            )
          else
            Icon(Icons.mic_outlined, size: 24, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(s.get('voiceNote'),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant,
                        height: 1.3)),
                const SizedBox(height: 4),
                if (transcript.isNotEmpty)
                  Text(transcript,
                      style: Theme.of(context).textTheme.bodyLarge)
                else
                  Text(s.get('voiceNoTranscript'),
                      style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: cs.secondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
