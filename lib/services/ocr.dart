import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Fields extracted from a receipt image or shared receipt text.
/// Every field carries its confidence implicitly: null = not found,
/// and the UI must ask the user instead of guessing.
class OcrResult {
  final double? amount;
  final DateTime? date;
  final String? merchant;
  final String? reference;
  final String rawText;
  final String? imagePath;

  const OcrResult({
    this.amount,
    this.date,
    this.merchant,
    this.reference,
    this.rawText = '',
    this.imagePath,
  });

  OcrResult copyWith({
    double? amount,
    DateTime? date,
    String? merchant,
    String? reference,
    String? rawText,
    String? imagePath,
  }) =>
      OcrResult(
        amount: amount ?? this.amount,
        date: date ?? this.date,
        merchant: merchant ?? this.merchant,
        reference: reference ?? this.reference,
        rawText: rawText ?? this.rawText,
        imagePath: imagePath ?? this.imagePath,
      );
}

/// On-device text recognition + receipt parsing.
/// Nothing leaves the phone. Free forever (no API keys, no cloud).
class OcrService {
  final TextRecognizer _recognizer = TextRecognizer();

  Future<OcrResult> fromImage(String path) async {
    final input = InputImage.fromFilePath(path);
    final recognized = await _recognizer.processImage(input);
    return parseText(recognized.text);
  }

  /// Parses shared receipt *text* (e.g. from Meezan's Share button)
  /// as well as OCR output.
  OcrResult parseText(String text) {
    final t = text.trim();
    if (t.isEmpty) return const OcrResult();
    return OcrResult(
      amount: _findAmount(t),
      date: _findDate(t),
      merchant: _findMerchant(t),
      reference: _findReference(t),
      rawText: t,
    );
  }

  /// Public date finder for statement import.
  DateTime? findDate(String t) => _findDate(t);

  void dispose() => _recognizer.close();

  // ---- heuristics tuned for Pakistani bank receipts (Meezan-first,
  // ---- bank-agnostic: they degrade gracefully on unknown formats) ----

  static final _amountPatterns = [
    RegExp(r'(?:Rs\.?|PKR|PK Rs\.?)\s*([\d,]+(?:\.\d{1,2})?)',
        caseSensitive: false),
    RegExp(r'Amount\s*:?\s*(?:Rs\.?|PKR)?\s*([\d,]+(?:\.\d{1,2})?)',
        caseSensitive: false),
  ];

  double? _findAmount(String t) {
    for (final pat in _amountPatterns) {
      final m = pat.firstMatch(t);
      if (m != null) {
        final v = double.tryParse(m.group(1)!.replaceAll(',', ''));
        if (v != null && v > 0) return v;
      }
    }
    return null;
  }

  static final _datePatterns = [
    // ISO first: 2026-09-30 (must come before the numeric d/m/y pattern,
    // which would otherwise match the tail "26-09-30").
    RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})'),
    // 30/09/2026, 30-09-2026
    RegExp(r'(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})'),
    // 30-Sep-2026
    RegExp(r'(\d{1,2})-(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*-(\d{2,4})',
        caseSensitive: false),
  ];
  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  DateTime? _findDate(String t) {
    for (final pat in _datePatterns) {
      final m = pat.firstMatch(t);
      if (m == null) continue;
      try {
        if (m.group(1)!.length == 4) {
          // ISO yyyy-mm-dd.
          final year = int.parse(m.group(1)!);
          final month = int.parse(m.group(2)!);
          final day = int.parse(m.group(3)!);
          if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
            return DateTime(year, month, day);
          }
          continue;
        }
        if (m.groupCount == 3 && RegExp(r'[A-Za-z]').hasMatch(m.group(2)!)) {
          final day = int.parse(m.group(1)!);
          final month = _months[m.group(2)!.toLowerCase().substring(0, 3)]!;
          var year = int.parse(m.group(3)!);
          if (year < 100) year += 2000;
          return DateTime(year, month, day);
        }
        final a = int.parse(m.group(1)!);
        final b = int.parse(m.group(2)!);
        var c = int.parse(m.group(3)!);
        if (c < 100) c += 2000;
        // Prefer d/m/y (Pakistan default); fall back if invalid.
        if (a <= 31 && b <= 12) return DateTime(c, b, a);
        if (b <= 31 && a <= 12) return DateTime(c, a, b);
      } catch (_) {}
    }
    return null;
  }

  static final _merchantPatterns = [
    RegExp(r'(?:To|Beneficiary|Merchant|Paid to|Transfer to)\s*:?\s*(.+)',
        caseSensitive: false),
  ];

  String? _findMerchant(String t) {
    for (final line in t.split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      for (final pat in _merchantPatterns) {
        final m = pat.firstMatch(l);
        if (m != null) {
          final v = m.group(1)!.trim();
          if (v.isNotEmpty && v.length <= 60) return v;
        }
      }
    }
    return null;
  }

  static final _refPatterns = [
    RegExp(r'(?:Ref(?:erence)?(?: No\.?| #)?|RRN|STAN|Transaction ID)\s*:?\s*([A-Za-z0-9\-/]+)',
        caseSensitive: false),
  ];

  String? _findReference(String t) {
    for (final pat in _refPatterns) {
      final m = pat.firstMatch(t);
      if (m != null) {
        final v = m.group(1)!.trim();
        if (v.length >= 4 && v.length <= 40) return v;
      }
    }
    return null;
  }
}
