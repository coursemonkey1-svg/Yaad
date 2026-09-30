import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Fields extracted from a receipt image or shared receipt text.
/// Every field carries its confidence implicitly: null = not found,
/// and the UI must ask the user instead of guessing.
/// [confidence] holds per-field scores (0..1) for what WAS found.
class OcrResult {
  final double? amount;
  final DateTime? date;
  final String? merchant;

  /// Legacy compat: mirrors [recipient] (ConfirmScreen prefills it).
  final String? reference;
  final String rawText;
  final String? imagePath;

  // v1.2 generalized receipt reader.
  final String? recipient;
  final String? sender;
  final String? recipientAccount;
  final String? senderAccount;
  final String? transactionType; // normalized: ibft|raast|internal|wallet|bill|other
  final String? transactionTypeRaw; // as printed on the receipt
  final String? bank; // informational bank keyword, e.g. 'meezan'
  final Map<String, double> confidence;

  const OcrResult({
    this.amount,
    this.date,
    this.merchant,
    this.reference,
    this.rawText = '',
    this.imagePath,
    this.recipient,
    this.sender,
    this.recipientAccount,
    this.senderAccount,
    this.transactionType,
    this.transactionTypeRaw,
    this.bank,
    this.confidence = const {},
  });

  /// True when nothing at all was extracted (rawText may still be set).
  bool get isEmpty =>
      amount == null &&
      date == null &&
      merchant == null &&
      reference == null &&
      recipient == null &&
      sender == null &&
      recipientAccount == null &&
      senderAccount == null &&
      transactionType == null &&
      bank == null;

  /// Core fields that came back empty — for "what's missing" UI.
  List<String> get missingFields => [
        if (amount == null) 'amount',
        if (date == null) 'date',
        if (merchant == null) 'merchant',
        if (reference == null) 'reference',
        if (sender == null) 'sender',
        if (recipient == null) 'recipient',
        if (transactionType == null) 'transactionType',
      ];

  OcrResult copyWith({
    double? amount,
    DateTime? date,
    String? merchant,
    String? reference,
    String? rawText,
    String? imagePath,
    String? recipient,
    String? sender,
    String? recipientAccount,
    String? senderAccount,
    String? transactionType,
    String? transactionTypeRaw,
    String? bank,
    Map<String, double>? confidence,
  }) =>
      OcrResult(
        amount: amount ?? this.amount,
        date: date ?? this.date,
        merchant: merchant ?? this.merchant,
        reference: reference ?? this.reference,
        rawText: rawText ?? this.rawText,
        imagePath: imagePath ?? this.imagePath,
        recipient: recipient ?? this.recipient,
        sender: sender ?? this.sender,
        recipientAccount: recipientAccount ?? this.recipientAccount,
        senderAccount: senderAccount ?? this.senderAccount,
        transactionType: transactionType ?? this.transactionType,
        transactionTypeRaw: transactionTypeRaw ?? this.transactionTypeRaw,
        bank: bank ?? this.bank,
        confidence: confidence ?? this.confidence,
      );
}

/// On-device text recognition + receipt parsing.
/// Nothing leaves the phone. Free forever (no API keys, no cloud).
///
/// Pipeline: normalize → amount → datetime → parties → reference →
/// txn type → bank. Every extractor never throws (returns null on
/// failure); parseText itself never throws — worst case it returns
/// OcrResult(rawText: t).
class OcrService {
  final TextRecognizer _recognizer = TextRecognizer();

  Future<OcrResult> fromImage(String path) async {
    final input = InputImage.fromFilePath(path);
    final recognized = await _recognizer.processImage(input);
    return parseText(recognized.text);
  }

  /// Parses shared receipt *text* (e.g. from Meezan's Share button)
  /// as well as OCR output. Never throws.
  ///
  /// [now] anchors relative dates ("today"/"yesterday"); defaults to
  /// DateTime.now(). Exposed for tests.
  OcrResult parseText(String text, {DateTime? now}) {
    final t = text.trim();
    if (t.isEmpty) return const OcrResult();
    try {
      final norm = _normalize(t);
      final refNow = now ?? DateTime.now();
      final conf = <String, double>{};
      final amount = _extractAmount(norm, conf);
      final dateTime = _extractDateTime(norm, refNow, conf);
      final parties = _extractParties(norm, conf);
      final reference = _extractReference(norm, amount, dateTime, conf);
      final txnType = _extractTxnType(norm, conf);
      final bank = _detectBank(norm, conf);
      final recipient = parties.recipient;
      if (recipient != null && conf.containsKey('recipient')) {
        conf['merchant'] = conf['recipient']!;
      }
      return OcrResult(
        amount: amount,
        date: dateTime,
        merchant: recipient, // ConfirmScreen compat
        recipient: recipient,
        sender: parties.sender,
        recipientAccount: parties.recipientAccount,
        senderAccount: parties.senderAccount,
        reference: reference,
        transactionType: txnType?.type,
        transactionTypeRaw: txnType?.raw,
        bank: bank,
        confidence: conf,
        rawText: t,
      );
    } catch (_) {
      return OcrResult(rawText: t);
    }
  }

  /// Public date finder for statement import. Date-only (no time).
  DateTime? findDate(String t) {
    try {
      final dt = _extractDateTime(
          _normalize(t.trim()), DateTime.now(), <String, double>{});
      if (dt == null) return null;
      return DateTime(dt.year, dt.month, dt.day);
    } catch (_) {
      return null;
    }
  }

  void dispose() => _recognizer.close();

  // ----------------------------------------------------------------
  // normalize
  // ----------------------------------------------------------------

  /// NBSP/dash/quote cleanup + OCR noise fixes. Letter-context is never
  /// rewritten inside names — digit-context fixes only fire between
  /// digits (O→0, l/I→1, ';'→':'), plus word-guarded label repairs.
  String _normalize(String t) {
    var s = t;
    s = s.replaceAll(' ', ' '); // NBSP
    s = s.replaceAll(RegExp(r'[‐‑‒–—―]'), '-');
    s = s.replaceAll(RegExp(r'[‘’‚‛]'), "'");
    s = s.replaceAll(RegExp(r'[“”„‟]'), '"');
    // Label repairs (word-boundary guarded).
    s = s.replaceAllMapped(RegExp(r'\bP[KB]R\b'), (_) => 'PKR');
    s = s.replaceAllMapped(RegExp(r'\bR[s5]\b'), (_) => 'Rs');
    // Digit-context noise fixes. The space merge intentionally does NOT
    // cross newlines ([^\S\n]): merging "8,000\n5ep" into "8,0005ep"
    // would glue two lines into one fake number.
    s = s.replaceAllMapped(
        RegExp(r'(?<=\d)[^\S\n]+(?=\d)'), (_) => ''); // "8 000"
    s = s.replaceAllMapped(RegExp(r'(?<=\d)[Oo](?=\d)'), (_) => '0'); // "8,0O0"
    s = s.replaceAllMapped(RegExp(r'(?<=\d)[lI](?=\d)'), (_) => '1'); // "53494l5"
    // Trailing variants: l/I/O at the end of a token ("53494l") fire
    // only when NOT followed by a letter/digit, so real words survive.
    s = s.replaceAllMapped(
        RegExp(r'(?<=\d)[Oo](?![A-Za-z0-9])'), (_) => '0'); // "8,00O"
    s = s.replaceAllMapped(
        RegExp(r'(?<=\d)[lI](?![A-Za-z0-9])'), (_) => '1'); // "53494l"
    s = s.replaceAllMapped(RegExp(r'(?<=\d);(?=\d)'), (_) => ':'); // "5;07 PM"
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s;
  }

  // ----------------------------------------------------------------
  // amount — ordered: labeled (0.95) → hero line (0.90) →
  // currency-prefixed (0.80) → narrative (0.65) → fallback (0.40).
  // First hit wins. Fee/balance/tax/limit and masked-account lines
  // are skipped everywhere; 11-digit mobiles are rejected.
  // ----------------------------------------------------------------

  static const _moneyToken = r'(?:\d[\d\s,]*\d|\d)(?:\.\d{1,2})?';

  static final _amountSkipLine = RegExp(
      r'\b(fee|fees|charges?|balance|tax|gst|vat|limit|discount|commission|available)\b',
      caseSensitive: false);
  static final _maskedLine =
      RegExp(r'\d[\d ]{0,8}[xX*]{2,}|\b\d+\*+\d*\b');

  static final _a1Labeled = RegExp(
      r'\b(?:amount|transaction\s+amount|total(?:\s+amount)?|grand\s+total|payable|sum)\b\s*:?\s*(?:(?:PKR|Rs\.?|₨)\s*)?(' +
          _moneyToken +
          r')',
      caseSensitive: false);
  static final _a2Hero = RegExp(
      r'^\s*(?:PKR|Rs\.?|₨)\s*(' + _moneyToken + r')\s*$',
      caseSensitive: false,
      multiLine: true);
  static final _a3Currency = RegExp(
      r'(?:PKR|Rs\.?|₨)\s*(' + _moneyToken + r')',
      caseSensitive: false);
  static final _a4Narrative = RegExp(
      r'\b(?:sent|paid|received|transferred|credited|debited)\b[^.\n]{0,80}?(?:(?:PKR|Rs\.?|₨)\s*)?(' +
          _moneyToken +
          r')',
      caseSensitive: false);
  static final _a5Fallback =
      RegExp('(' + _moneyToken + r')', caseSensitive: false);
  static final _successLine = RegExp(
      r'\b(success|successful|completed|approved|confirmed)\b',
      caseSensitive: false);
  static final _dateLine = RegExp(
      r'\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b|\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b|\b\d{4}-\d{1,2}-\d{1,2}\b',
      caseSensitive: false);
  static final _refLabelLine = RegExp(
      r'\b(?:ref(?:erence)?(?:\s*no)?\.?|rrn|stan|tid|trx?\s*id|trace\s*(?:no|id)|approval\s+code)\b',
      caseSensitive: false);

  double? _toAmount(String token) {
    final digits = token.replaceAll(RegExp(r'[\s,]'), '');
    // Reject 11-digit Pakistani mobiles masquerading as amounts.
    final onlyDigits = digits.replaceAll(RegExp(r'\D'), '');
    if (onlyDigits.length == 11 && onlyDigits.startsWith('0')) return null;
    final v = double.tryParse(digits);
    if (v == null || v <= 0 || v >= 100000000) return null;
    return v;
  }

  double? _extractAmount(String t, Map<String, double> conf) {
    try {
      String lineAt(int pos) {
        final ls = t.lastIndexOf('\n', pos - 1);
        var le = t.indexOf('\n', pos);
        if (le < 0) le = t.length;
        return t.substring(ls < 0 ? 0 : ls + 1, le);
      }

      int lineIndex(int pos) =>
          RegExp(r'\n').allMatches(t.substring(0, pos)).length;

      // Reject a candidate whose ~20 preceding chars name it as a
      // fee/balance/tax/limit figure ("Fee Rs. 10", "balance is Rs. 9,000").
      // Window-based (not whole-line): one SMS line can hold the real
      // amount AND the fee/balance in separate clauses.
      bool skippedCtx(int start) {
        final from = start - 20 < 0 ? 0 : start - 20;
        return _amountSkipLine.hasMatch(t.substring(from, start));
      }

      bool okAt(int start) =>
          !_maskedLine.hasMatch(lineAt(start)) && !skippedCtx(start);

      double? firstOf(RegExp re, double c) {
        for (final m in re.allMatches(t)) {
          final g = m.group(1);
          if (g == null) continue;
          if (!okAt(t.indexOf(g, m.start))) continue;
          final v = _toAmount(g);
          if (v != null) {
            conf['amount'] = c;
            return v;
          }
        }
        return null;
      }

      // A1 — labeled amount.
      var v = firstOf(_a1Labeled, 0.95);
      if (v != null) return v;
      // A2 — hero standalone currency line ("PKR 8,000").
      v = firstOf(_a2Hero, 0.90);
      if (v != null) return v;
      // A3 — first currency-prefixed amount; ties broken by proximity
      // to a success-keyword line.
      final successIdx = <int>{};
      final lines = t.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (_successLine.hasMatch(lines[i])) successIdx.add(i);
      }
      final cands = <({int line, double value})>[];
      for (final m in _a3Currency.allMatches(t)) {
        final tokenStart = t.indexOf(m.group(1)!, m.start);
        if (!okAt(tokenStart)) continue;
        final val = _toAmount(m.group(1)!);
        if (val != null) cands.add((line: lineIndex(m.start), value: val));
      }
      if (cands.isNotEmpty) {
        int dist(int l) => successIdx.isEmpty
            ? 0
            : successIdx
                .map((s) => (s - l).abs())
                .reduce((x, y) => x < y ? x : y);
        cands.sort((a, b) => dist(a.line).compareTo(dist(b.line)));
        conf['amount'] = 0.80;
        return cands.first.value;
      }
      // A4 — narrative ("sent Rs 500 to …").
      v = firstOf(_a4Narrative, 0.65);
      if (v != null) return v;
      // A5 — fallback: first bare money token (never on date or
      // reference-labeled lines).
      for (final m in _a5Fallback.allMatches(t)) {
        final tokenStart = t.indexOf(m.group(1)!, m.start);
        if (!okAt(tokenStart)) continue;
        final line = lineAt(m.start);
        if (_dateLine.hasMatch(line)) continue;
        if (_refLabelLine.hasMatch(line)) continue;
        final val = _toAmount(m.group(1)!);
        if (val != null) {
          conf['amount'] = 0.40;
          return val;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------------
  // datetime — labeled 0.95, unlabeled 0.85. Pattern order: ISO,
  // month-first ("Sep 28, 2026"), day-month-year flexible, numeric,
  // relative. Numeric ambiguity: a>12→d/m/y, b>12→m/d/y, else
  // Pakistan-default d/m/y. Time merged from the date's line first.
  // ----------------------------------------------------------------

  static const _monthAbbr = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec'
  ];

  static const _labeledPrefix =
      r'(?:date|dated|transaction\s+date|txn\s+date|on)\b\s*:?\s*';

  static final _timeMeridiem = RegExp(
      r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AP])\.?\s*M\.?',
      caseSensitive: false);
  static final _time24 = RegExp(r'\b(\d{1,2}):(\d{2})\b');

  /// Month lookup with OCR tolerance: exact 3-letter prefix, then
  /// digit→letter repair ("5ep"→"sep"), then 1-char fuzzy match.
  int? _monthFromToken(String tok) {
    final key0 =
        tok.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final key = key0.length >= 3 ? key0.substring(0, 3) : key0;
    var idx = _monthAbbr.indexOf(key);
    if (idx >= 0) return idx + 1;
    const repair = {
      '5': 's',
      '0': 'o',
      '1': 'i',
      '8': 'b',
      '6': 'g',
      '2': 'z'
    };
    final repaired =
        key.split('').map((c) => repair[c] ?? c).join();
    idx = _monthAbbr.indexOf(repaired);
    if (idx >= 0) return idx + 1;
    for (var i = 0; i < _monthAbbr.length; i++) {
      if (_levenshtein(key, _monthAbbr[i]) <= 1) return i + 1;
    }
    return null;
  }

  int _levenshtein(String a, String b) {
    final m = a.length, n = b.length;
    var prev = List<int>.generate(n + 1, (j) => j);
    for (var i = 1; i <= m; i++) {
      var curr = [i, ...List<int>.filled(n, 0)];
      for (var j = 1; j <= n; j++) {
        curr[j] = a[i - 1] == b[j - 1]
            ? prev[j - 1]
            : 1 +
                [prev[j], curr[j - 1], prev[j - 1]]
                    .reduce((x, y) => x < y ? x : y);
      }
      prev = curr;
    }
    return prev[n];
  }

  DateTime? _validDate(int y, int m, int d) {
    if (y < 1900 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) {
      return null;
    }
    final dt = DateTime(y, m, d);
    if (dt.year != y || dt.month != m || dt.day != d) return null;
    return dt;
  }

  bool _isFuture(DateTime d, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return d.isAfter(today.add(const Duration(days: 1)));
  }

  List<_DatePattern> get _datePatterns => [
        _DatePattern(r'(\d{4})-(\d{1,2})-(\d{1,2})', (m, _) {
          final y = int.parse(m.group(1)!);
          final mo = int.parse(m.group(2)!);
          final d = int.parse(m.group(3)!);
          return _validDate(y, mo, d);
        }),
        // Month-first: "Sep 28, 2026" (Meezan's actual receipt format).
        _DatePattern(
            r'\b([A-Za-z0-9][a-zA-Z]{2,9})\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b',
            (m, _) {
          final mo = _monthFromToken(m.group(1)!);
          if (mo == null) return null;
          final d = int.parse(m.group(2)!);
          final y = int.parse(m.group(3)!);
          return _validDate(y, mo, d);
        }),
        // Day-month-year, flexible separators, ordinals: "28 Sep 2026",
        // "28.Sep.2026", "28th Sep 2026".
        _DatePattern(
            r'\b(\d{1,2})(?:st|nd|rd|th)?[\s.\-/]+([A-Za-z0-9][a-zA-Z]{2,9})[\s.\-/]+(\d{2,4})\b',
            (m, _) {
          final d = int.parse(m.group(1)!);
          final mo = _monthFromToken(m.group(2)!);
          if (mo == null) return null;
          var y = int.parse(m.group(3)!);
          if (y < 100) y += 2000;
          return _validDate(y, mo, d);
        }),
        // Numeric: 28/09/2026.
        _DatePattern(r'\b(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})\b', (m, _) {
          final a = int.parse(m.group(1)!);
          final b = int.parse(m.group(2)!);
          var c = int.parse(m.group(3)!);
          if (c < 100) c += 2000;
          // Pakistan default is d/m/y; disambiguate when possible.
          if (a > 12) return _validDate(c, b, a); // d/m/y
          if (b > 12) return _validDate(c, a, b); // m/d/y
          return _validDate(c, b, a); // default d/m/y
        }),
        _DatePattern(r'\b(today|yesterday)\b', (m, now) {
          final day = DateTime(now.year, now.month, now.day);
          return m.group(1)!.toLowerCase() == 'today'
              ? day
              : day.subtract(const Duration(days: 1));
        }),
      ];

  String _lineOf(String t, int offset) {
    final start = t.lastIndexOf('\n', offset - 1);
    var end = t.indexOf('\n', offset);
    if (end < 0) end = t.length;
    return t.substring(start < 0 ? 0 : start + 1, end);
  }

  DateTime _mergeTime(String t, RegExpMatch dm, DateTime date) {
    try {
      final line = _lineOf(t, dm.start);
      RegExpMatch? tm =
          _timeMeridiem.firstMatch(line) ?? _timeMeridiem.firstMatch(t);
      if (tm != null) {
        var h = int.parse(tm.group(1)!);
        final mi = int.parse(tm.group(2)!);
        if (mi > 59) return date;
        final pm = tm.group(4)!.toUpperCase() == 'P';
        if (h < 1 || h > 12) return date;
        h = h % 12 + (pm ? 12 : 0);
        return DateTime(date.year, date.month, date.day, h, mi);
      }
      tm = _time24.firstMatch(line);
      if (tm != null) {
        final h = int.parse(tm.group(1)!);
        final mi = int.parse(tm.group(2)!);
        if (h > 23 || mi > 59) return date;
        return DateTime(date.year, date.month, date.day, h, mi);
      }
      return date;
    } catch (_) {
      return date;
    }
  }

  DateTime? _extractDateTime(
      String t, DateTime now, Map<String, double> conf) {
    try {
      final patterns = _datePatterns;
      // D1 — labeled pass first (0.95), then D2 unlabeled (0.85).
      for (final labeled in [true, false]) {
        for (final p in patterns) {
          final src = labeled ? _labeledPrefix + p.src : p.src;
          final m =
              RegExp(src, caseSensitive: false).firstMatch(t);
          if (m == null) continue;
          final d = p.parse(m, now);
          if (d == null || _isFuture(d, now)) continue;
          final withTime = _mergeTime(t, m, d);
          conf['date'] = labeled ? 0.95 : 0.85;
          return withTime;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------------
  // parties — \b-guarded label sets; multi-line label handling
  // (Meezan From/To blocks); masked accounts kept verbatim;
  // narrative SMS fallback (0.6). Recipient mirrors to [merchant].
  // ----------------------------------------------------------------

  static final _recipientLabels = RegExp(
      r'\b(to\s+account|beneficiary|receiver|paid\s+to|transfer\s+to|sent\s+to|recipient|credited\s+to|payee|merchant|to)\b\s*:?\s*',
      caseSensitive: false);
  static final _senderLabels = RegExp(
      r'\b(from\s+account|debited\s+from|paid\s+by|remitter|sender|from)\b\s*:?\s*',
      caseSensitive: false);

  static const _nameDenylist = {
    'meezan',
    'hbl',
    'ubl',
    'mcb',
    'allied',
    'jazzcash',
    'easypaisa',
    'nayapay',
    'sadapay',
    'faysal',
    'alfalah',
    'askari',
    'soneri',
    'bankislami',
    'standard chartered',
    'scb',
    'js bank',
    '1link',
    'bank',
    'transaction successful',
    'reference number',
    'transaction type',
    'account',
    'number',
  };

  static final _maskedAccount =
      RegExp(r'\b\d[\d ]{0,8}[xX*]{2,}[\d ]*\d\b');
  static final _mobileAccount = RegExp(r'\b0\d{9,10}\b');
  static final _longDigits = RegExp(r'\b\d{10,20}\b');
  // Stop a same-line name at date / reference fragments.
  static final _restStop = RegExp(
      r'\b(?:on|dated?|at)\b\s*(?=\d)|'
      r'\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b|'
      r'\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2},?\s+\d{4}\b|'
      r'\b(?:ref(?:erence)?(?:\s*no)?\.?|rrn|stan|tid|trx?\s*id|trace\s*(?:no|id)|approval\s+code)\b',
      caseSensitive: false);

  static final _narrRecipient = RegExp(
      r'\b(?:sent|paid|transferred)\b[^.\n]{0,60}?\bto\s+([A-Za-z][A-Za-z .]{1,40}|\d{10,11})\b',
      caseSensitive: false);
  static final _narrSender = RegExp(
      r'\b(?:received|got)\b[^.\n]{0,60}?\bfrom\s+([A-Za-z][A-Za-z .]{1,40}|\d{10,11})\b',
      caseSensitive: false);

  bool _validName(String n) {
    if (n.length < 2 || n.length > 60) return false;
    if (!RegExp(r'[A-Za-z]').hasMatch(n)) return false;
    final low = n.toLowerCase();
    for (final d in _nameDenylist) {
      if (low == d || low.contains(d)) return false;
    }
    return true;
  }

  String? _extractAccount(String s) {
    var m = _maskedAccount.firstMatch(s);
    if (m != null) return m.group(0)!.trim();
    m = _mobileAccount.firstMatch(s);
    if (m != null) return m.group(0)!;
    m = _longDigits.firstMatch(s);
    if (m != null) return m.group(0)!;
    return null;
  }

  String _cleanName(String rest) {
    var s = rest;
    final stop = _restStop.firstMatch(s);
    if (stop != null) s = s.substring(0, stop.start);
    s = s.replaceFirst(
        RegExp(r'\s*\b\d[\d ]{0,8}[xX*]{2,}[\d ]*\d\b\s*$'), '');
    s = s.replaceFirst(RegExp(r'\s*\b0?\d{9,}\b\s*$'), '');
    s = s.replaceFirst(
        RegExp(r'^(?:account|a/c)\s*:?\s*', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    s = s.replaceAll(RegExp(r'[:;|]+$'), '').trim();
    return s;
  }

  bool _looksLikeLabel(String line) =>
      _recipientLabels.hasMatch(line) || _senderLabels.hasMatch(line);

  _Parties _extractParties(String t, Map<String, double> conf) {
    try {
      final lines = t.split('\n');
      String? recipient, sender, recipientAccount, senderAccount;

      for (var pass = 0; pass < 2; pass++) {
        final labels = pass == 0 ? _recipientLabels : _senderLabels;
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          final m = labels.firstMatch(line);
          if (m == null) continue;
          String? name;
          String? account;
          final rest = line.substring(m.end).trim();
          if (rest.isNotEmpty) {
            account = _extractAccount(rest);
            final cleaned = _cleanName(rest);
            if (_validName(cleaned)) name = cleaned;
            // Account may sit on a following line instead.
            if (account == null) {
              for (var j = i + 1;
                  j < lines.length && j <= i + 2;
                  j++) {
                final nl = lines[j].trim();
                if (nl.isEmpty) continue;
                account = _extractAccount(nl);
                if (account != null) break;
              }
            }
          } else {
            // Label on line i with empty rest: name on i+1,
            // account on i+2 or the name's own line.
            for (var j = i + 1;
                j < lines.length && j <= i + 2;
                j++) {
              final nl = lines[j].trim();
              if (nl.isEmpty || _looksLikeLabel(nl)) continue;
              account = _extractAccount(nl);
              final cleaned = _cleanName(nl);
              if (_validName(cleaned)) {
                name = cleaned;
                break;
              }
              // A line that is only an account number: keep looking
              // for the name? No — masked account lines follow the
              // name in Meezan's layout, so if this line is just an
              // account, the name was on the previous (already seen)
              // line; stop here.
              if (account != null) break;
            }
            if (name != null && account == null) {
              for (var j = i + 1;
                  j < lines.length && j <= i + 3;
                  j++) {
                final nl = lines[j].trim();
                if (nl.isEmpty) continue;
                account = _extractAccount(nl);
                if (account != null) break;
              }
            }
          }
          if (pass == 0) {
            recipient ??= name;
            recipientAccount ??= account;
          } else {
            sender ??= name;
            senderAccount ??= account;
          }
        }
      }

      // Narrative SMS fallback (Easypaisa/JazzCash style), conf 0.6.
      if (recipient == null && recipientAccount == null) {
        final m = _narrRecipient.firstMatch(t);
        if (m != null) {
          final v = m.group(1)!.trim();
          if (RegExp(r'^\d+$').hasMatch(v)) {
            recipientAccount = v;
          } else if (_validName(v)) {
            recipient = v;
          }
          conf['recipient'] = 0.6;
        }
      }
      if (sender == null && senderAccount == null) {
        final m = _narrSender.firstMatch(t);
        if (m != null) {
          final v = m.group(1)!.trim();
          if (RegExp(r'^\d+$').hasMatch(v)) {
            senderAccount = v;
          } else if (_validName(v)) {
            sender = v;
          }
          conf['sender'] = 0.6;
        }
      }

      if (recipient != null || recipientAccount != null) {
        conf['recipient'] = conf['recipient'] ?? 0.9;
      }
      if (sender != null || senderAccount != null) {
        conf['sender'] = conf['sender'] ?? 0.9;
      }
      return _Parties(
        recipient: recipient,
        sender: sender,
        recipientAccount: recipientAccount,
        senderAccount: senderAccount,
      );
    } catch (_) {
      return const _Parties();
    }
  }

  // ----------------------------------------------------------------
  // reference — R1 labeled (0.95), R2 fallback (0.55). Validated:
  // 4–40 chars, not all zeros, not a date/amount string, denylisted
  // words rejected.
  // ----------------------------------------------------------------

  static final _refR1 = RegExp(
      r'\b(?:reference\s+number(?:\s*\([^)]*\))?|transaction\s+(?:id|no\.?)|tid|trx?\s*id|rrn|stan|ref(?:erence)?(?:\s*no)?\.?|trace\s*(?:no|id)|retrieval\s+reference(?:\s+number)?|approval\s+code)\s*:?\s*#?\s*([A-Za-z0-9][A-Za-z0-9\-/]{3,39})\b',
      caseSensitive: false);
  static final _refR2Token = RegExp(r'\b([A-Za-z0-9]{6,20})\b');
  static const _refDenylist = {
    'reference',
    'number',
    'transaction',
    'successful',
    'completed',
    'approved',
    'confirmed',
    'null',
    'none',
  };

  bool _validReference(
      String v, double? amount, DateTime? dateTime) {
    if (v.length < 4 || v.length > 40) return false;
    if (RegExp(r'^0+$').hasMatch(v)) return false;
    if (_refDenylist.contains(v.toLowerCase())) return false;
    final low = v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (amount != null) {
      final aStrs = {
        amount.toStringAsFixed(0),
        amount.toStringAsFixed(2),
        amount.toString().replaceAll('.', ''),
      };
      if (aStrs.contains(low) || aStrs.contains(v)) return false;
    }
    if (dateTime != null) {
      final d = dateTime;
      final two = (int x) => x.toString().padLeft(2, '0');
      final dStrs = {
        '${d.year}${two(d.month)}${two(d.day)}',
        '${two(d.day)}${two(d.month)}${d.year}',
        '${d.year}-${two(d.month)}-${two(d.day)}',
      };
      if (dStrs.contains(low) || dStrs.contains(v)) return false;
    }
    return true;
  }

  String? _extractReference(String t, double? amount, DateTime? dateTime,
      Map<String, double> conf) {
    try {
      // Digit-context OCR fixes already applied in _normalize
      // ("53494l" → "534941").
      final m = _refR1.firstMatch(t);
      if (m != null) {
        final v = m.group(1)!.trim();
        if (_validReference(v, amount, dateTime)) {
          conf['reference'] = 0.95;
          return v;
        }
      }
      // R2 fallback: a standalone token on a success-keyword line.
      for (final line in t.split('\n')) {
        if (!_successLine.hasMatch(line)) continue;
        for (final tm in _refR2Token.allMatches(line)) {
          final v = tm.group(1)!;
          if (RegExp(r'[xX*]').hasMatch(v)) continue; // masked
          if (!_validReference(v, amount, dateTime)) continue;
          conf['reference'] = 0.55;
          return v;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------------
  // txn type + bank
  // ----------------------------------------------------------------

  static final _typeLabel = RegExp(
      r'\b(transaction\s+type|transfer\s+type|channel|type)\b\s*:?\s*(.+)',
      caseSensitive: false);

  static String _normalizeTxnType(String raw) {
    final l = raw.toLowerCase();
    if (l.contains('1link') || l.contains('ibft')) return 'ibft';
    if (l.contains('raast')) return 'raast';
    if (l.contains('intra') ||
        l.contains('own bank') ||
        l.contains('internal')) {
      return 'internal';
    }
    if (l.contains('jazzcash') ||
        l.contains('easypaisa') ||
        l.contains('wallet') ||
        l.contains('mobile')) {
      return 'wallet';
    }
    if (l.contains('bill') || l.contains('utility')) return 'bill';
    return 'other';
  }

  _TxnType? _extractTxnType(String t, Map<String, double> conf) {
    try {
      for (final line in t.split('\n')) {
        final m = _typeLabel.firstMatch(line);
        if (m == null) continue;
        var raw = m.group(2)!.trim();
        if (raw.length > 40) raw = raw.substring(0, 40);
        if (raw.isEmpty) continue;
        conf['transactionType'] = 0.9;
        return _TxnType(type: _normalizeTxnType(raw), raw: raw);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static const _bankKeywords = [
    'meezan',
    'hbl',
    'ubl',
    'mcb',
    'allied',
    'jazzcash',
    'easypaisa',
    'nayapay',
    'sadapay',
    'faysal',
    'alfalah',
    'askari',
    'soneri',
    'scb',
    'js',
    'bankislami',
  ];

  /// Informational only — which bank's receipt this looks like.
  String? _detectBank(String t, Map<String, double> conf) {
    try {
      String? best;
      var bestAt = 1 << 30;
      for (final kw in _bankKeywords) {
        final m =
            RegExp('\\b' + kw + '\\b', caseSensitive: false)
                .firstMatch(t);
        if (m != null && m.start < bestAt) {
          bestAt = m.start;
          best = kw;
        }
      }
      if (best != null) conf['bank'] = 0.9;
      return best;
    } catch (_) {
      return null;
    }
  }
}

class _DatePattern {
  final String src;
  final DateTime? Function(RegExpMatch m, DateTime now) parse;
  _DatePattern(this.src, this.parse);
}

class _Parties {
  final String? recipient;
  final String? sender;
  final String? recipientAccount;
  final String? senderAccount;
  const _Parties(
      {this.recipient,
      this.sender,
      this.recipientAccount,
      this.senderAccount});
}

class _TxnType {
  final String type;
  final String raw;
  _TxnType({required this.type, required this.raw});
}
