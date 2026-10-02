import 'dart:io';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';
import '../models/account.dart';
import '../models/transaction.dart';
import 'meezan_parser.dart';
import 'ocr.dart';
import 'pdf_text.dart';

/// Result of importing a statement file.
class ImportReport {
  final int imported;
  final int duplicates;
  final int failed;
  final List<String> errors;
  const ImportReport({
    this.imported = 0,
    this.duplicates = 0,
    this.failed = 0,
    this.errors = const [],
  });
}

/// One parsed statement row, awaiting user confirmation in the preview.
class ParsedRow {
  final DateTime date;
  final String merchant;
  final double amount;
  TxnKind kind; // spend / receive / transfer (user-adjustable)
  final String? reference;
  final bool isDuplicate;
  bool selected;
  bool suggestedTransfer;
  /// Purpose the statement parser suggested (e.g. Meezan keyword map).
  /// Null means "no opinion" — commitRows falls back to the default.
  final String? suggestedPurpose;

  ParsedRow({
    required this.date,
    required this.merchant,
    required this.amount,
    required this.kind,
    this.reference,
    this.isDuplicate = false,
    this.selected = true,
    this.suggestedTransfer = false,
    this.suggestedPurpose,
  });
}

/// A parsed statement file: rows + problems, no DB writes yet.
class ParsedStatement {
  final List<ParsedRow> rows;
  final List<String> errors;
  final String fileName;
  final bool pdfNoText;
  final String mappingSignature;
  final Map<String, int>? mapping;

  const ParsedStatement({
    this.rows = const [],
    this.errors = const [],
    this.fileName = '',
    this.pdfNoText = false,
    this.mappingSignature = '',
    this.mapping,
  });
}

/// Remembers which columns meant what, per statement layout.
/// The next file with the same header row imports with zero setup.
class ColumnMappingMemory {
  static const _key = 'yaad_column_mappings';

  static Future<Map<String, int>?> recall(String signature) async {
    if (signature.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_key::$signature');
    if (raw == null) return null;
    final out = <String, int>{};
    for (final part in raw.split(',')) {
      final kv = part.split('=');
      if (kv.length == 2) {
        final v = int.tryParse(kv[1]);
        if (v != null) out[kv[0]] = v;
      }
    }
    return out.isEmpty ? null : out;
  }

  static Future<void> remember(
      String signature, Map<String, int> mapping) async {
    if (signature.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        '$_key::$signature',
        mapping.entries.map((e) => '${e.key}=${e.value}').join(','));
  }
}

/// Imports bank statements (CSV / Excel / PDF / plain text) with
/// duplicate detection. Bank-agnostic: auto-detects columns by header
/// names, remembers the mapping per layout, and flags likely
/// self-transfers for the preview screen.
class StatementImporter {
  /// Parses a file without writing anything. PDF statements go through
  /// the on-device text extractor; scanned/image PDFs yield
  /// [ParsedStatement.pdfNoText] so the UI can show guidance.
  Future<ParsedStatement> parseFile(String path) async {
    final lower = path.toLowerCase();
    final fileName = path.split(Platform.pathSeparator).last;
    List<List<String>> rows;
    if (lower.endsWith('.xlsx') || lower.endsWith('.xls')) {
      rows = _readExcel(path);
    } else if (lower.endsWith('.pdf')) {
      final text = await extractPdfText(path);
      if (text.trim().isEmpty) {
        return ParsedStatement(fileName: fileName, pdfNoText: true);
      }
      if (MeezanParser.looksLike(text)) {
        return _parseMeezan(text, fileName);
      }
      rows = _rowsFromText(text);
    } else {
      final text = await File(path).readAsString();
      rows = const CsvToListConverter()
          .convert(text, eol: '\n')
          .map((r) => r.map((c) => c.toString()).toList())
          .toList();
      if (rows.length < 2 || rows.first.length < 2) {
        rows = _rowsFromText(text);
      }
    }
    if (rows.isEmpty) {
      return ParsedStatement(
          fileName: fileName,
          errors: ['Could not read any rows from the file.']);
    }
    return _parseRows(rows, fileName);
  }

  List<List<String>> _rowsFromText(String text) {
    // Whitespace/tab separated text statements (and PDF text).
    return text
        .split('\n')
        .map((l) =>
            l.trim().split(RegExp(r'\s{2,}|\t')).map((c) => c.trim()).toList())
        .where((r) => r.length >= 2)
        .toList();
  }

  List<List<String>> _readExcel(String path) {
    final bytes = File(path).readAsBytesSync();
    final excel = Excel.decodeBytes(bytes);
    final out = <List<String>>[];
    for (final table in excel.tables.values) {
      for (final row in table.rows) {
        out.add(row.map((c) => c?.value?.toString() ?? '').toList());
      }
      if (out.isNotEmpty) break; // first non-empty sheet wins
    }
    return out;
  }

  /// Meezan (Apache FOP) statements have their own glued layout, which
  /// the generic column-based _parseRows can't read. Goes straight to
  /// the preview like everything else — nothing is written before the
  /// user confirms.
  Future<ParsedStatement> _parseMeezan(String text, String fileName) async {
    final stmt = MeezanParser.parse(text);
    final parsed = <ParsedRow>[];
    for (final r in stmt.rows) {
      final dup = await YaadDb.findDuplicate(
        bankReference: r.reference,
        amount: r.amount,
        rawMerchant: r.description,
        date: r.date,
      );
      parsed.add(ParsedRow(
        date: r.date,
        merchant: r.description,
        amount: r.amount,
        kind: r.kind,
        reference: r.reference,
        isDuplicate: dup != null,
        selected: dup == null,
        suggestedPurpose: r.suggestedPurpose,
      ));
    }
    _flagTransferPairs(parsed);
    return ParsedStatement(
      rows: parsed,
      errors: stmt.warnings,
      fileName: fileName,
      mappingSignature: 'meezan-fop-v1',
      mapping: null,
    );
  }

  Future<ParsedStatement> _parseRows(
      List<List<String>> rows, String fileName) async {
    // Find header row: the first row mentioning date + (amount|debit|credit).
    int headerIdx = 0;
    for (int i = 0; i < rows.length && i < 10; i++) {
      final joined = rows[i].join(' ').toLowerCase();
      if (joined.contains('date') &&
          (joined.contains('amount') ||
              joined.contains('debit') ||
              joined.contains('credit') ||
              joined.contains('withdraw'))) {
        headerIdx = i;
        break;
      }
    }
    final header =
        rows[headerIdx].map((h) => h.toLowerCase().trim()).toList();
    final signature = header.join('|');

    int col(List<String> names) {
      for (final n in names) {
        final i = header.indexWhere((h) => h.contains(n));
        if (i >= 0) return i;
      }
      return -1;
    }

    var dateCol = col(['date', 'txn date', 'transaction date', 'value date']);
    var descCol = col([
      'description',
      'narration',
      'details',
      'particulars',
      'merchant',
      'payee'
    ]);
    var amountCol = col(['amount']);
    var debitCol = col(['debit', 'withdrawal', 'dr']);
    var creditCol = col(['credit', 'deposit', 'cr']);
    var refCol = col(['reference', 'ref', 'rrn', 'transaction id']);

    // Column-mapping memory: same layout as last time → reuse it.
    final remembered = await ColumnMappingMemory.recall(signature);
    if (remembered != null) {
      dateCol = remembered['date'] ?? dateCol;
      descCol = remembered['desc'] ?? descCol;
      amountCol = remembered['amount'] ?? amountCol;
      debitCol = remembered['debit'] ?? debitCol;
      creditCol = remembered['credit'] ?? creditCol;
      refCol = remembered['ref'] ?? refCol;
    }

    if (dateCol < 0 ||
        descCol < 0 ||
        (amountCol < 0 && debitCol < 0 && creditCol < 0)) {
      return ParsedStatement(fileName: fileName, errors: [
        'Could not understand the statement layout. Expected columns like Date, Description and Amount/Debit/Credit.'
      ]);
    }

    final mapping = {
      'date': dateCol,
      'desc': descCol,
      'amount': amountCol,
      'debit': debitCol,
      'credit': creditCol,
      'ref': refCol,
    };

    final parsed = <ParsedRow>[];
    final errors = <String>[];
    final ocr = OcrService();

    for (int i = headerIdx + 1; i < rows.length; i++) {
      final r = rows[i];
      try {
        String cell(int c) => c >= 0 && c < r.length ? r[c].trim() : '';
        final date = ocr.findDate(cell(dateCol)) ?? DateTime.now();
        final merchant = cell(descCol);
        if (merchant.isEmpty) continue;

        double amount = 0;
        var isOut = true;
        if (amountCol >= 0) {
          // Single amount column: sign decides direction.
          final raw = _num(cell(amountCol));
          if (raw < 0) {
            amount = -raw;
            isOut = true;
          } else {
            amount = raw;
            isOut = false;
          }
        } else {
          final dr = debitCol >= 0 ? _num(cell(debitCol)) : 0.0;
          final cr = creditCol >= 0 ? _num(cell(creditCol)) : 0.0;
          if (cr > 0 && dr == 0) {
            amount = cr;
            isOut = false;
          } else {
            amount = dr;
          }
        }
        if (amount <= 0) continue;
        final ref = refCol >= 0 ? cell(refCol) : '';
        final reference = ref.isNotEmpty ? ref : null;

        final dup = await YaadDb.findDuplicate(
          bankReference: reference,
          amount: amount,
          rawMerchant: merchant,
          date: date,
        );
        parsed.add(ParsedRow(
          date: date,
          merchant: merchant,
          amount: amount,
          kind: isOut ? TxnKind.spend : TxnKind.receive,
          reference: reference,
          isDuplicate: dup != null,
          selected: dup == null,
        ));
      } catch (e) {
        if (errors.length < 5) errors.add('Row ${i + 1}: $e');
      }
    }

    _flagTransferPairs(parsed);
    return ParsedStatement(
      rows: parsed,
      errors: errors,
      fileName: fileName,
      mappingSignature: signature,
      mapping: mapping,
    );
  }

  /// Flags likely self-transfers: same amount in/out within 2 days with
  /// transfer-ish wording. The preview screen lets the user confirm —
  /// never auto-applied.
  void _flagTransferPairs(List<ParsedRow> rows) {
    final transferWords =
        RegExp(r'transfer|own account|\bself\b|ibt|interbank|fund transfer',
            caseSensitive: false);
    for (int i = 0; i < rows.length; i++) {
      final a = rows[i];
      if (a.kind != TxnKind.spend) continue;
      for (int j = 0; j < rows.length; j++) {
        if (i == j) continue;
        final b = rows[j];
        if (b.kind != TxnKind.receive) continue;
        if ((a.amount - b.amount).abs() > 0.01) continue;
        if ((a.date.difference(b.date).inDays).abs() > 2) continue;
        if (transferWords.hasMatch(a.merchant) ||
            transferWords.hasMatch(b.merchant)) {
          a.suggestedTransfer = true;
          b.suggestedTransfer = true;
        }
      }
    }
  }

  /// Writes the user's confirmed selection. Remembers the column
  /// mapping so the next identical layout is zero-setup.
  /// [accountId] tags every imported row; when null it falls back to
  /// the default (Meezan) account — imported rows are never account-less.
  Future<ImportReport> commitRows(
      List<ParsedRow> selected, String mappingSignature,
      {Map<String, int>? mapping, String? accountId}) async {
    int imported = 0, duplicates = 0, failed = 0;
    final errors = <String>[];
    for (final row in selected) {
      try {
        final dup = await YaadDb.findDuplicate(
          bankReference: row.reference,
          amount: row.amount,
          rawMerchant: row.merchant,
          date: row.date,
        );
        if (dup != null) {
          duplicates++;
          continue;
        }
        await YaadDb.insertTxn(YaadTransaction(
          amount: row.amount,
          dateTime: row.date,
          kind: row.kind,
          direction: row.kind == TxnKind.spend
              ? TxnDirection.out
              : TxnDirection.incoming,
          rawMerchant: row.merchant,
          purpose: row.suggestedPurpose ??
              (row.kind == TxnKind.spend ? 'uncategorized' : 'other_in'),
          bankReference: row.reference,
          source: TxnSource.statementImport,
          status: TxnStatus.needsReview,
          accountId: accountId ?? Account.seedMeezan,
        ));
        imported++;
      } catch (e) {
        failed++;
        if (errors.length < 5) errors.add('${row.merchant}: $e');
      }
    }
    if (mapping != null) {
      await ColumnMappingMemory.remember(mappingSignature, mapping);
    }
    return ImportReport(
        imported: imported,
        duplicates: duplicates,
        failed: failed,
        errors: errors);
  }

  double _num(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(cleaned) ?? 0;
  }
}
