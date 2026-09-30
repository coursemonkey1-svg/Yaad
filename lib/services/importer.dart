import 'dart:io';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';

import '../data/db.dart';
import '../models/transaction.dart';
import 'ocr.dart';

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

/// Imports bank statements (CSV / Excel / plain text) with duplicate
/// detection. Bank-agnostic: auto-detects columns by header names,
/// with Meezan-style layouts working out of the box.
class StatementImporter {
  Future<ImportReport> importFile(String path) async {
    final lower = path.toLowerCase();
    List<List<String>> rows;
    if (lower.endsWith('.xlsx') || lower.endsWith('.xls')) {
      rows = _readExcel(path);
    } else {
      final text = await File(path).readAsString();
      rows = const CsvToListConverter()
          .convert(text, eol: '\n')
          .map((r) => r.map((c) => c.toString()).toList())
          .toList();
      // Fallback: whitespace/tab separated text statements.
      if (rows.length < 2 || rows.first.length < 2) {
        rows = text
            .split('\n')
            .map((l) => l.trim().split(RegExp(r'\s{2,}|\t')).map((c) => c.trim()).toList())
            .where((r) => r.length >= 2)
            .toList();
      }
    }
    if (rows.isEmpty) {
      return const ImportReport(
          failed: 1, errors: ['Could not read any rows from the file.']);
    }
    return _importRows(rows);
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

  Future<ImportReport> _importRows(List<List<String>> rows) async {
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

    int col(List<String> names) {
      for (final n in names) {
        final i = header.indexWhere((h) => h.contains(n));
        if (i >= 0) return i;
      }
      return -1;
    }

    final dateCol = col(['date', 'txn date', 'transaction date', 'value date']);
    final descCol = col(
        ['description', 'narration', 'details', 'particulars', 'merchant', 'payee']);
    final amountCol = col(['amount']);
    final debitCol = col(['debit', 'withdrawal', 'dr']);
    final creditCol = col(['credit', 'deposit', 'cr']);
    final refCol = col(['reference', 'ref', 'rrn', 'transaction id']);

    if (dateCol < 0 || descCol < 0 || (amountCol < 0 && debitCol < 0 && creditCol < 0)) {
      return const ImportReport(failed: 1, errors: [
        'Could not understand the statement layout. Expected columns like Date, Description and Amount/Debit/Credit.'
      ]);
    }

    int imported = 0, duplicates = 0, failed = 0;
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
        var direction = TxnDirection.out;
        if (amountCol >= 0) {
          amount = _num(cell(amountCol));
        } else {
          final dr = debitCol >= 0 ? _num(cell(debitCol)) : 0.0;
          final cr = creditCol >= 0 ? _num(cell(creditCol)) : 0.0;
          if (cr > 0 && dr == 0) {
            amount = cr;
            direction = TxnDirection.incoming;
          } else {
            amount = dr;
          }
        }
        if (amount <= 0) continue;
        final ref = refCol >= 0 ? cell(refCol) : null;

        final dup = await YaadDb.findDuplicate(
          bankReference: (ref != null && ref.isNotEmpty) ? ref : null,
          amount: amount,
          rawMerchant: merchant,
          date: date,
        );
        if (dup != null) {
          duplicates++;
          continue;
        }
        await YaadDb.insertTxn(YaadTransaction(
          amount: amount,
          dateTime: date,
          direction: direction,
          rawMerchant: merchant,
          bankReference: (ref != null && ref.isNotEmpty) ? ref : null,
          source: TxnSource.statementImport,
          status: TxnStatus.needsReview,
        ));
        imported++;
      } catch (e) {
        failed++;
        if (errors.length < 5) errors.add('Row ${i + 1}: $e');
      }
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
