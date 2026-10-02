import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../models/account.dart';
import '../models/settings.dart';
import '../models/transaction.dart';
import '../models/person.dart';
import '../models/lending.dart';
import '../models/alias.dart';
import 'app_state.dart';

/// Backup & export. Everything is a file the user owns —
/// no account, no cloud upload. Free forever.
class BackupService {
  /// Full backup as JSON. Returns the file path.
  ///
  /// Covers every user-data table. The internal `audit` table is
  /// deliberately excluded: it is a device-local debug trail, not user
  /// data, and it bloats the file and the restore. [importJson] never
  /// reads it, so older backups that still contain `audit` restore fine.
  Future<String> exportJson() async {
    final db = await YaadDb.db;
    final data = <String, Object?>{};
    for (final t in [
      'transactions',
      'people',
      'lending',
      'repayments',
      'aliases',
      'accounts',
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
  ///
  /// [from]/[to] bound the range (inclusive, whole days); null means
  /// unbounded ("All time"). [fileLabel] names the file, e.g.
  /// `yaad-transactions-2026-09.csv`. [language] localises the
  /// human-readable label columns.
  Future<CsvExport> exportCsv({
    DateTime? from,
    DateTime? to,
    String fileLabel = 'all',
    String language = 'en',
  }) async {
    final s = Strings(language);
    int? fromMs, toMs;
    if (from != null) {
      fromMs =
          DateTime(from.year, from.month, from.day).millisecondsSinceEpoch;
    }
    if (to != null) {
      toMs = DateTime(to.year, to.month, to.day, 23, 59, 59, 999)
          .millisecondsSinceEpoch;
    }
    final txns =
        await YaadDb.txns(limit: 100000, fromMs: fromMs, toMs: toMs);

    // Friendly merchant names the user has taught the app.
    final db = await YaadDb.db;
    final aliasRows = await db.query('aliases', columns: ['id', 'alias']);
    final aliases = {
      for (final r in aliasRows)
        (r['id'] as String): (r['alias'] as String? ?? ''),
    };

    // Label columns read in the user's language; the machine columns
    // (type, purpose) stay stable for filters and pivot tables.
    String label(String key, String fallback) => s.find(key) ?? fallback;
    String esc(String v) => '"${v.replaceAll('"', '""')}"';

    final buf = StringBuffer(
        'date,amount,currency,type,type_label,merchant,merchant_name,'
        'purpose,purpose_label,note,tags,reference,status\n');
    for (final t in txns) {
      buf.writeln([
        t.dateTime.toIso8601String(),
        t.amount,
        t.currency,
        t.kind.name,
        esc(label('kind_${t.kind.name}', t.kind.name)),
        esc(t.rawMerchant),
        esc(t.aliasId == null ? '' : (aliases[t.aliasId] ?? '')),
        t.purpose,
        esc(label('purpose_${t.purpose}', t.purpose)),
        esc(t.note),
        esc(t.tags.join(';')),
        esc(t.bankReference ?? ''),
        t.status.name,
      ].join(','));
    }
    final dir = await getApplicationDocumentsDirectory();
    final safeLabel = fileLabel.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '');
    final path = p.join(dir.path, 'yaad-transactions-$safeLabel.csv');
    await File(path).writeAsString(buf.toString());
    return CsvExport(path: path, count: txns.length);
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
    // Accounts match by id — the seeded Meezan / Savings / Cash rows
    // already exist, so they are skipped, never duplicated.
    await restore('accounts', (m) => Account.fromMap(m).toMap());
    // Pre-accounts backups (v1.3 and older) have no accountId on their
    // rows — those land on the default account, exactly like the
    // v4→v5 migration does for on-device rows.
    final defaultAccountId = await _defaultAccountId();
    await restore('transactions', (m) {
      final map = YaadTransaction.fromMap(m).toMap();
      map['accountId'] ??= defaultAccountId;
      return map;
    });
    await restore('lending', (m) => LendingRecord.fromMap(m).toMap());
    await restore('repayments', (m) => Repayment.fromMap(m).toMap());
    return ImportSummary(added: added, skipped: skipped);
  }

  /// The default account id from settings. Falls back to the Meezan
  /// seed when settings were never saved (e.g. a fresh install
  /// restoring an old backup).
  Future<String> _defaultAccountId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppState.prefsKey);
      if (raw != null) {
        return AppSettings.fromMap(
                Map<String, Object?>.from(jsonDecode(raw)))
            .defaultAccountId;
      }
    } catch (_) {}
    return Account.seedMeezan;
  }

  Future<void> shareFile(String path, {String subject = 'Yaad export'}) async {
    await Share.shareXFiles([XFile(path)], subject: subject);
  }
}

/// Result of a CSV export: where the file landed, and how many rows it holds.
class CsvExport {
  final String path;
  final int count;
  const CsvExport({required this.path, required this.count});
}

class ImportSummary {
  final int added;
  final int skipped;
  const ImportSummary({required this.added, required this.skipped});
}
