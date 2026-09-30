/// On-device parsing of Pakistani bank transaction alerts (SMS and
/// bank-app notifications). No network, no SDKs — pure regex (§6).
///
/// Confidence tiers:
/// - high: amount + direction + (merchant or reference) → auto-recorded.
/// - medium: amount + direction only → review queue ("needs your eye").
/// - none: not a parseable money alert → skipped.
library;

enum AlertConfidence { high, medium, none }

class ParsedAlert {
  final double? amount;
  final bool? isOut; // true = money left the account
  final String? merchant;
  final String? reference;
  final String bank; // meezan, hbl, ubl, jazzcash, easypaisa, unknown
  final AlertConfidence confidence;
  final String rawText;

  const ParsedAlert({
    this.amount,
    this.isOut,
    this.merchant,
    this.reference,
    this.bank = 'unknown',
    this.confidence = AlertConfidence.none,
    this.rawText = '',
  });
}

final _amountRe =
    RegExp(r'(?:PKR|Rs\.?)\s*([\d,]+(?:\.\d{1,2})?)', caseSensitive: false);
final _outRe = RegExp(
    r'debit|withdrawn|withdrawal|paid|sent|spent|purchase',
    caseSensitive: false);
final _inRe = RegExp(r'credit|received|deposited|refund',
    caseSensitive: false);
// "at KHAADI LAHORE", "via ATM DHA", "to 03001234567"
final _atRe = RegExp(
    r'\bat\s+([A-Z0-9][A-Z0-9 .,&\-]{2,40}?)(?=\.|,|;|$)',
    caseSensitive: false);
final _toRe =
    RegExp(r'\bto\s+([A-Z0-9][A-Z0-9 .]{2,30})', caseSensitive: false);
final _refRe = RegExp(
    r'(?:REF(?:ERENCE)?(?: NO)?|TXN(?: ID)?|TRX|STAN)[\s:]*([A-Z0-9\-]{4,30})',
    caseSensitive: false);

String _detectBank(String sender, String body) {
  final s = sender.toUpperCase();
  final b = body.toUpperCase();
  if (s.contains('MEEZAN') || b.contains('MEEZAN')) return 'meezan';
  if (s.contains('HBL') || RegExp(r'\bHBL\b').hasMatch(b)) return 'hbl';
  if (s.contains('UBL') || RegExp(r'\bUBL\b').hasMatch(b)) return 'ubl';
  if (s.contains('JAZZ') || b.contains('JAZZCASH')) return 'jazzcash';
  if (s.contains('EASYPAISA') ||
      s.contains('EASY') ||
      b.contains('EASYPAISA')) return 'easypaisa';
  return 'unknown';
}

double? _parseAmount(String text) {
  final m = _amountRe.firstMatch(text);
  if (m == null) return null;
  return double.tryParse(m.group(1)!.replaceAll(',', ''));
}

bool? _parseDirection(String text) {
  final out = _outRe.hasMatch(text);
  final inn = _inRe.hasMatch(text);
  if (out && !inn) return true;
  if (inn && !out) return false;
  return null; // ambiguous
}

String? _parseMerchant(String text) {
  var m = _atRe.firstMatch(text);
  if (m != null) return m.group(1)!.trim();
  m = _toRe.firstMatch(text);
  if (m != null) return m.group(1)!.trim();
  return null;
}

String? _parseReference(String text) {
  final m = _refRe.firstMatch(text);
  return m?.group(1)?.trim();
}

/// Parses one SMS body or notification text.
ParsedAlert parseAlert(String sender, String body) {
  final text = body.trim();
  if (text.isEmpty) {
    return const ParsedAlert(confidence: AlertConfidence.none);
  }
  final amount = _parseAmount(text);
  final isOut = _parseDirection(text);
  if (amount == null || isOut == null) {
    return ParsedAlert(rawText: text, confidence: AlertConfidence.none);
  }
  final merchant = _parseMerchant(text);
  final reference = _parseReference(text);
  final bank = _detectBank(sender, text);
  final confidence =
      (merchant != null || reference != null)
          ? AlertConfidence.high
          : AlertConfidence.medium;
  return ParsedAlert(
    amount: amount,
    isOut: isOut,
    merchant: merchant,
    reference: reference,
    bank: bank,
    confidence: confidence,
    rawText: text,
  );
}
