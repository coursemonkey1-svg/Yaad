import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../models/account.dart';
import '../models/custom_purpose.dart';
import '../models/settings.dart';
import '../models/transaction.dart';
import '../models/person.dart';
import '../models/lending.dart';
import '../models/alias.dart';
import 'app_state.dart';
import 'demo_data.dart';

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
      'custom_purposes',
    ]) {
      data[t] = await db.query(t);
    }
    // Settings live in SharedPreferences, not SQLite — include them
    // so a restore really is a round trip (language, currency,
    // accounts default, toggles). Older backups without this key
    // restore fine; the import side treats it as optional.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppState.prefsKey);
      if (raw != null) {
        data['settings'] = Map<String, Object?>.from(jsonDecode(raw));
      }
      // The demo-openings snapshot rides along too: demo removal
      // restores the user's own openings FROM it, and a backup taken
      // while demo data was on would otherwise strand the demo
      // openings on the new phone forever (phantom money with zero
      // transactions behind it).
      final demoSnap = await DemoData.snapshotRaw();
      if (demoSnap != null) data['demoOpenings'] = demoSnap;
    } catch (_) {
      // A backup without settings is still a backup.
    }
    data['exportedAt'] = DateTime.now().toIso8601String();
    data['app'] = 'yaad';
    data['formatVersion'] = 1;
    final dir = await getApplicationDocumentsDirectory();
    final path =
        p.join(dir.path, 'yaad-backup-${DateTime.now().millisecondsSinceEpoch}.json');
    await File(path).writeAsString(jsonEncode(data));
    // Retention: every backup is a FULL financial history file.
    // Keeping every one ever made is storage and privacy debt —
    // only the newest survives (older ones were already shared by
    // the user wherever they wanted them). Sync listing on purpose:
    // this runs inside Settings handlers, and an awaited directory
    // stream can stall a UI flow that is waiting on it.
    try {
      for (final f in dir.listSync()) {
        if (f is File &&
            f.path != path &&
            p.basename(f.path).startsWith('yaad-backup-') &&
            f.path.endsWith('.json')) {
          await f.delete();
        }
      }
    } catch (_) {
      // Retention is best-effort; the backup itself succeeded.
    }
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
    final all =
        await YaadDb.txns(limit: 100000, fromMs: fromMs, toMs: toMs);
    // 'excluded' rows never count anywhere in the app (every sum and
    // balance ignores them) — the CSV must not quietly re-include
    // money the user excluded, e.g. when sharing it with an
    // accountant.
    final txns = all.where((t) => t.status != TxnStatus.excluded).toList();

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
        // One bad row must never abort the whole restore (it did:
        // an alias whose rawName already existed on this phone —
        // under a different random id — hit the rawName UNIQUE
        // constraint and the exception killed every table restored
        // after aliases: accounts, transactions, Udhaar, all gone).
        try {
          await db.insert(table, conv(m));
          added++;
        } catch (_) {
          skipped++;
        }
      }
    }

    await restore('people', (m) => Person.fromMap(m).toMap());
    // Aliases: the same rawName taught on two devices has two
    // different ids, so the by-id check above is not enough — match
    // by rawName as well (upsertAlias semantics) or the insert dies
    // on the UNIQUE constraint.
    final aliasRows = (data['aliases'] as List?) ?? [];
    for (final r in aliasRows) {
      final m = Map<String, Object?>.from(r as Map);
      final alias = MerchantAlias.fromMap(m);
      final byId = await db.query('aliases',
          where: 'id = ?', whereArgs: [alias.id], limit: 1);
      final byName = await db.query('aliases',
          where: 'rawName = ?', whereArgs: [alias.rawName], limit: 1);
      if (byId.isNotEmpty || byName.isNotEmpty) {
        skipped++;
        continue;
      }
      try {
        await db.insert('aliases', alias.toMap());
        added++;
      } catch (_) {
        skipped++;
      }
    }
    // Accounts match by id. The SEEDED accounts (Meezan / Savings /
    // Cash) exist on every install, so skipping them would silently
    // lose a seed's rename and its opening balance on every
    // fresh-install restore — they are updated in place instead.
    // Existing CUSTOM accounts get the same treatment: re-importing
    // a newer backup onto the same phone must not silently keep the
    // old name/opening for them either.
    final accountRows = (data['accounts'] as List?) ?? [];
    for (final r in accountRows) {
      final m = Map<String, Object?>.from(r as Map);
      final acc = Account.fromMap(m);
      final existing = await db.query('accounts',
          where: 'id = ?', whereArgs: [acc.id], limit: 1);
      if (existing.isEmpty) {
        await db.insert('accounts', acc.toMap());
        added++;
      } else {
        await db.update(
            'accounts',
            {
              'name': acc.name,
              'customName': acc.customName ? 1 : 0,
              'openingBalance': acc.openingBalance,
            },
            where: 'id = ?',
            whereArgs: [acc.id]);
      }
    }
    // Pre-accounts backups (v1.3 and older) have no accountId on their
    // rows — those land on the default account, exactly like the
    // v4→v5 migration does for on-device rows.
    final defaultAccountId = await _defaultAccountId();
    await restore('transactions', (m) {
      final map = YaadTransaction.fromMap(m).toMap();
      map['accountId'] ??= defaultAccountId;
      // Attachments travel as paths, not bytes: on a different phone
      // those absolute paths point at nothing. Drop a path whose file
      // is not here, so the entry honestly shows no recording/receipt
      // instead of a dead player and a missing-image gap.
      for (final key in ['audioPath', 'receiptPath']) {
        final v = map[key] as String?;
        if (v != null && v.isNotEmpty && !File(v).existsSync()) {
          map[key] = null;
        }
      }
      return map;
    });
    await restore('lending', (m) => LendingRecord.fromMap(m).toMap());
    await restore('repayments', (m) => Repayment.fromMap(m).toMap());
    // Custom purposes: the db.dart contract always said these are
    // part of backup/restore, but the table was never exported —
    // restoring an old phone silently lost every user-created
    // purpose (its transactions fell back to "Other" labels).
    await restore('custom_purposes',
        (m) => CustomPurpose.fromMap(m).toMap());
    await YaadDb.refreshCustomPurposeRegistry();
    // Settings (when the backup carries them): write them back to
    // SharedPreferences; the caller reloads AppState afterwards.
    // The transient opt-in flow flags are NOT preferences — a backup
    // captured mid-trip to system settings must not resurrect a
    // half-finished opt-in on this phone (the completion pass could
    // turn capture on here without the user ever flipping it here).
    final settingsRaw = data['settings'];
    if (settingsRaw is Map) {
      final restored = AppSettings.fromMap(
              Map<String, Object?>.from(settingsRaw))
          .copyWith(
              notifOptInPending: false,
              smsOptInPending: false,
              notifOptInMissed: false,
              smsOptInMissed: false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppState.prefsKey, jsonEncode(restored.toMap()));
    }
    // The demo-openings snapshot, when the backup carries one, so
    // "Remove demo data" on THIS phone can restore the user's own
    // openings exactly as it would have on the source phone.
    final demoSnap = data['demoOpenings'];
    if (demoSnap is String) {
      await DemoData.restoreSnapshotRaw(demoSnap);
    }
    return ImportSummary(added: added, skipped: skipped);
  }

  /// Deletes the app-owned files a factory wipe must not leave
  /// behind: every voice-note recording, every saved receipt image,
  /// and every exported backup/CSV (each a complete financial
  /// history). The database wipe alone left all of these on disk —
  /// "deleted" data that was not, in fact, deleted.
  static Future<void> deleteWipeLeftovers() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final sub in ['voice_notes', 'receipts']) {
        final d = Directory(p.join(dir.path, sub));
        if (await d.exists()) await d.delete(recursive: true);
      }
      // Sync listing on purpose: the wipe handler awaits this before
      // confirming "all data deleted" to the user, and an awaited
      // directory STREAM can stall that confirmation indefinitely
      // (its events ride the platform event loop, which a locked or
      // backgrounding phone may not service promptly). The app
      // documents dir holds a handful of files — one sync pass is
      // instant and deterministic.
      for (final f in dir.listSync()) {
        if (f is File &&
            (p.basename(f.path).startsWith('yaad-backup-') ||
                p.basename(f.path).startsWith('yaad-transactions-'))) {
          await f.delete();
        }
      }
    } catch (_) {
      // Best effort: the database/settings wipe already happened.
    }
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
