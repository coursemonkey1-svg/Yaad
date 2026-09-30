import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/db.dart';
import '../models/transaction.dart';
import '../models/person.dart';
import '../models/lending.dart';
import '../models/alias.dart';

/// Backup & export. Everything is a file the user owns —
/// no account, no cloud upload. Free forever.
class BackupService {
  /// Full backup as JSON. Returns the file path.
  Future<String> exportJson() async {
    final db = await YaadDb.db;
    final data = <String, Object?>{};
    for (final t in [
      'transactions',
      'people',
      'lending',
      'repayments',
      'aliases',
      'audit'
    ]) {
      data[t] = await db.query(t);
    }
    data['exportedAt'] = DateTime.now().toIso8601String();
    data['app'] = 'yaad';
    data['formatVersion'] = 1;
    final dir = await getApplicationDocumentsDirectory();
    final path =
        p.join(dir.path, 'yaad-backup-${DateTime.now().millisecondsSinceEpoch}.json');
    await File(path).writeAsString(jsonEncode(data));
    return path;
  }

  /// Transactions as CSV (opens in Excel / Google Sheets).
  Future<String> exportCsv() async {
    final txns = await YaadDb.txns(limit: 100000);
    final buf = StringBuffer(
        'date,amount,currency,direction,merchant,purpose,note,tags,reference,status\n');
    for (final t in txns) {
      String esc(String s) => '"${s.replaceAll('"', '""')}"';
      buf.writeln([
        DateTime.fromMillisecondsSinceEpoch(
                t.dateTime.millisecondsSinceEpoch)
            .toIso8601String(),
        t.amount,
        t.currency,
        t.direction.name,
        esc(t.rawMerchant),
        esc(t.purpose),
        esc(t.note),
        esc(t.tags.join(';')),
        esc(t.bankReference ?? ''),
        t.status.name,
      ].join(','));
    }
    final dir = await getApplicationDocumentsDirectory();
    final path =
        p.join(dir.path, 'yaad-transactions-${DateTime.now().millisecondsSinceEpoch}.csv');
    await File(path).writeAsString(buf.toString());
    return path;
  }

  /// Restores from a JSON backup file. Skips records that already exist.
  Future<ImportSummary> importJson(String path) async {
    final raw = await File(path).readAsString();
    final data = Map<String, Object?>.from(jsonDecode(raw));
    if (data['app'] != 'yaad') {
      throw const FormatException('Not a Yaad backup file.');
    }
    int added = 0, skipped = 0;
    final db = await YaadDb.db;

    Future<void> restore(
        String table, Map<String, Object?> Function(Map<String, Object?>) conv) async {
      final rows = (data[table] as List?) ?? [];
      for (final r in rows) {
        final m = Map<String, Object?>.from(r as Map);
        final existing = await db.query(table,
            where: 'id = ?', whereArgs: [m['id']], limit: 1);
        if (existing.isNotEmpty) {
          skipped++;
          continue;
        }
        await db.insert(table, conv(m));
        added++;
      }
    }

    await restore('people', (m) => Person.fromMap(m).toMap());
    await restore('aliases', (m) => MerchantAlias.fromMap(m).toMap());
    await restore('transactions', (m) => YaadTransaction.fromMap(m).toMap());
    await restore('lending', (m) => LendingRecord.fromMap(m).toMap());
    await restore('repayments', (m) => Repayment.fromMap(m).toMap());
    return ImportSummary(added: added, skipped: skipped);
  }

  Future<void> shareFile(String path, {String subject = 'Yaad export'}) async {
    await Share.shareXFiles([XFile(path)], subject: subject);
  }
}

class ImportSummary {
  final int added;
  final int skipped;
  const ImportSummary({required this.added, required this.skipped});
}
