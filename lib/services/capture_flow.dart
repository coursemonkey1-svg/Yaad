import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../main.dart';
import '../services/ocr.dart';
import '../screens/confirm.dart';

/// Runs OCR on an image with visible progress and graceful failure.
/// Never fails silently (§4): on success opens the confirm screen;
/// on failure explains and offers manual entry with the image kept.
Future<void> captureImage(BuildContext context, String path) async {
  final s = Strings(appState.settings.language);
  final navigator = Navigator.of(context);

  // Progress indicator while ML Kit reads the image.
  showDialog(
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

  if (!context.mounted) return;
  navigator.pop(); // dismiss progress

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
