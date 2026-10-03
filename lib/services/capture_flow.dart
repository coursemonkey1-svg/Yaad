import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/strings.dart';
import '../main.dart';
import '../services/ocr.dart';
import '../screens/confirm.dart';

/// Copies a picked/shared receipt image into the app's own documents
/// folder and returns the durable path. The picker and the share
/// sheet hand out CACHE paths the OS may delete at any time — saving
/// one of those as the transaction's receiptPath meant the receipt
/// silently vanished days later (the view screen hides the section
/// when the file is gone). A path already inside the app folder is
/// returned unchanged; any failure falls back to the original path
/// (today's behaviour) rather than losing the entry.
Future<String?> persistReceiptImage(String? path) async {
  if (path == null) return null;
  try {
    final src = File(path);
    if (!await src.exists()) return path;
    final docs = await getApplicationDocumentsDirectory();
    if (path.startsWith(docs.path)) return path;
    final dir = Directory('${docs.path}/receipts');
    if (!await dir.exists()) await dir.create(recursive: true);
    final dot = path.lastIndexOf('.');
    final ext = dot > 0 && path.length - dot <= 5
        ? path.substring(dot)
        : '.jpg';
    final dest = '${dir.path}/receipt_${const Uuid().v4()}$ext';
    await src.copy(dest);
    return dest;
  } catch (_) {
    return path;
  }
}

/// Runs OCR on an image with visible progress and graceful failure.
/// Never fails silently (§4): on success opens the confirm screen;
/// on failure explains and offers manual entry with the image kept.
Future<void> captureImage(BuildContext context, String path) async {
  final s = Strings(appState.settings.language);
  final navigator = Navigator.of(context);

  // Progress indicator while ML Kit reads the image.
  //
  // The dialog is a route on the root navigator, so it OUTLIVES the
  // caller's State: the app-lock Gate can dispose the caller mid-OCR
  // (share → background → re-lock) without touching the route. The
  // old dismissal — `if (!context.mounted) return; navigator.pop()` —
  // therefore leaked this non-dismissible dialog forever in exactly
  // that case (spinner on top, no buttons, app soft-bricked until
  // killed), and when the caller survived, the blind pop() closed
  // whatever route happened to be on top, not necessarily this
  // dialog. Keep the route object and remove THAT route.
  final progressRoute = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: Text(s.get('ocrReading'))),
        ],
      ),
    ),
  );
  unawaited(navigator.push(progressRoute));

  OcrResult? result;
  Object? error;
  final ocr = OcrService();
  try {
    result = (await ocr.fromImage(path)).copyWith(imagePath: path);
  } catch (e) {
    error = e;
  } finally {
    ocr.dispose();
  }

  // Dismiss the progress dialog no matter what state the caller is
  // in — the route is ours and removing it is always safe.
  if (progressRoute.isActive) {
    navigator.removeRoute(progressRoute);
  }
  if (!context.mounted) return;

  // Two dead ends, one dialog: the OCR engine failed outright, or it
  // read the photo but found nothing usable in it (blank photo, not a
  // receipt). Both must SAY so and offer manual entry — landing on a
  // blank form with no explanation reads as "the app did nothing".
  if (error != null || result == null) {
    await _offerManual(context, navigator, s,
        bodyKey: 'ocrFailedBody',
        initial: OcrResult(rawText: '', imagePath: path));
    return;
  }
  if (result.isEmpty) {
    // Keep the parsed result: its raw text becomes the note on the
    // confirm screen, so nothing the photo contained is lost.
    await _offerManual(context, navigator, s,
        bodyKey: 'ocrEmptyBody', initial: result);
    return;
  }

  navigator.push(MaterialPageRoute(
    builder: (_) => ConfirmScreen(initial: result),
  ));
  appState.refresh();
}

/// The "couldn't read it" dialog: explains, then offers manual entry
/// with the photo kept (as [initial], or as its image alone).
Future<void> _offerManual(
  BuildContext context,
  NavigatorState navigator,
  Strings s, {
  required String bodyKey,
  required OcrResult initial,
}) async {
  final retry = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(s.get('ocrFailedTitle')),
      content: Text(s.get(bodyKey)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(s.get('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(s.get('enterManually')),
        ),
      ],
    ),
  );
  if (retry == true && context.mounted) {
    navigator.push(MaterialPageRoute(
      builder: (_) => ConfirmScreen(initial: initial),
    ));
  }
}
