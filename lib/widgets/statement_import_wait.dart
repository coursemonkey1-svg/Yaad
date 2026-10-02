import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/importer.dart';

/// Outcome of the cancellable, time-bounded statement-parse wait
/// ([runStatementImport]).
enum StatementImportOutcome {
  /// The file parsed; [StatementImportResult.statement] holds the rows.
  ready,

  /// The user pressed Cancel. The progress dialog is already dismissed.
  cancelled,

  /// Parsing took longer than the timeout. The progress dialog is already
  /// dismissed.
  timedOut,

  /// Parsing threw. The progress dialog is already dismissed.
  failed,
}

/// What [runStatementImport] produced. `statement` is non-null only for
/// [StatementImportOutcome.ready].
@immutable
class StatementImportResult {
  final StatementImportOutcome outcome;
  final ParsedStatement? statement;

  const StatementImportResult(this.outcome, [this.statement]);
}

/// Shows the "Reading your statement…" progress dialog with a Cancel
/// button, runs [parse] on [path], and dismisses the dialog when the wait
/// ends for any reason: success, Cancel, timeout, or failure.
///
/// The parse step is injected ([parse]) so tests can pass a mock that hangs,
/// throws, or returns fixture data; production passes
/// `StatementImporter().parseFile`.
///
/// Design notes:
/// - Dart Futures cannot truly be cancelled, so after Cancel the parse may
///   still finish in the background — but the result is simply discarded.
///   The importer never writes to the database before the preview-screen
///   confirmation, so an abandoned parse cannot change user data.
/// - The barrier stays non-dismissible so stray taps can't kill the wait;
///   the explicit Cancel button — and the Android back button, which acts
///   as Cancel — always end it. The dialog is dismissed exactly once no
///   matter which path fires first.
Future<StatementImportResult> runStatementImport(
  BuildContext context, {
  required String path,
  required Strings strings,
  required Future<ParsedStatement> Function(String path) parse,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final cancelCompleter = Completer<StatementImportResult>();
  var dialogOpen = false;

  // Ends the wait early (Cancel button or Android back button). Idempotent.
  void cancelWait() {
    dialogOpen = false;
    if (!cancelCompleter.isCompleted) {
      cancelCompleter.complete(
          const StatementImportResult(StatementImportOutcome.cancelled));
    }
  }

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) cancelWait();
      },
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(strings.get('importReading'))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (!dialogOpen) return;
              cancelWait();
              Navigator.of(dialogContext).pop();
            },
            child: Text(strings.get('cancel')),
          ),
        ],
      ),
    ),
  );
  dialogOpen = true;

  Future<StatementImportResult> parseOnce() async {
    // Timed so that a slow import can be diagnosed from the device log
    // instead of guessed at (elapsed ms + row count on success; elapsed
    // ms on timeout/failure).
    final sw = Stopwatch()..start();
    try {
      final parsed = await parse(path).timeout(timeout);
      sw.stop();
      debugPrint('[import] parse ok: ${sw.elapsedMilliseconds}ms, '
          '${parsed.rows.length} rows');
      return StatementImportResult(
          StatementImportOutcome.ready, parsed);
    } on TimeoutException {
      sw.stop();
      debugPrint(
          '[import] parse timed out after ${sw.elapsedMilliseconds}ms');
      return const StatementImportResult(StatementImportOutcome.timedOut);
    } catch (e) {
      sw.stop();
      debugPrint('[import] parse failed after ${sw.elapsedMilliseconds}ms '
          '(${e.runtimeType})');
      return const StatementImportResult(StatementImportOutcome.failed);
    }
  }

  // Whichever finishes first wins: the parse (success/timeout/failure) or
  // the user's Cancel. The loser is discarded harmlessly.
  final result = await Future.any([parseOnce(), cancelCompleter.future]);

  if (dialogOpen && context.mounted) {
    dialogOpen = false;
    Navigator.of(context).pop();
  }
  return result;
}

/// Plain-language "couldn't read the file" dialog, used for both timeouts
/// and parse failures: nothing was imported, and the user knows what to try
/// next.
Future<void> showImportReadFailedDialog(
    BuildContext context, Strings strings) {
  return showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(strings.get('importReadFailTitle')),
      content: SingleChildScrollView(
        child: Text(strings.get('importReadFailBody')),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.get('gotIt')),
        ),
      ],
    ),
  );
}
