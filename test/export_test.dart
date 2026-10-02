import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/models/alias.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/services/backup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Export quality: CSV date ranges + columns, JSON backup without audit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-export-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  setUp(() async {
    await YaadDb.wipeAll();
  });

  Future<YaadTransaction> insertTxn({
    required DateTime date,
    required double amount,
    String purpose = 'groceries',
    String merchant = 'TEST MART',
    TxnKind kind = TxnKind.spend,
    String? aliasId,
    String note = '',
  }) async {
    final t = YaadTransaction(
      amount: amount,
      dateTime: date,
      kind: kind,
      rawMerchant: merchant,
      purpose: purpose,
      aliasId: aliasId,
      note: note,
    );
    final db = await YaadDb.db;
    await db.insert('transactions', t.toMap());
    return t;
  }

  Future<List<String>> dataRows(String path) async {
    final lines =
        const LineSplitter().convert(await File(path).readAsString());
    return lines.skip(1).toList();
  }

  test('CSV with a date range exports only in-range rows', () async {
    await insertTxn(date: DateTime(2026, 8, 28), amount: 500);
    await insertTxn(
        date: DateTime(2026, 9, 5),
        amount: 1500,
        merchant: 'SEPT MART',
        note: 'in range');
    // Boundaries are inclusive whole days.
    await insertTxn(date: DateTime(2026, 9, 30, 23, 59), amount: 100);
    await insertTxn(date: DateTime(2026, 10, 1), amount: 2500);

    final res = await BackupService().exportCsv(
      from: DateTime(2026, 9, 1),
      to: DateTime(2026, 9, 30),
      fileLabel: '2026-09',
    );

    expect(res.path.endsWith('yaad-transactions-2026-09.csv'), isTrue);
    expect(res.count, 2);
    final rows = await dataRows(res.path);
    expect(rows, hasLength(2));
    expect(rows.any((r) => r.contains('SEPT MART')), isTrue);
    expect(rows.any((r) => r.contains('2026-10-01')), isFalse);
    expect(rows.any((r) => r.contains('2026-08-28')), isFalse);
  });

  test('All time exports everything (unchanged behavior)', () async {
    await insertTxn(date: DateTime(2025, 3, 3), amount: 700);
    await insertTxn(date: DateTime(2026, 9, 5), amount: 1500);
    await insertTxn(date: DateTime(2026, 10, 2), amount: 2500);

    final res = await BackupService().exportCsv();

    expect(res.path.endsWith('yaad-transactions-all.csv'), isTrue);
    expect(res.count, 3);
    expect(await dataRows(res.path), hasLength(3));
  });

  test('CSV columns: machine values plus human-readable labels', () async {
    final db = await YaadDb.db;
    final alias =
        MerchantAlias(rawName: 'PSO SHAHRAH-E-FAISAL', alias: 'PSO Petrol Pump');
    await db.insert('aliases', alias.toMap());
    await insertTxn(
      date: DateTime(2026, 9, 5),
      amount: 1200,
      kind: TxnKind.lendOut,
      purpose: 'groceries',
      merchant: 'PSO SHAHRAH-E-FAISAL',
      aliasId: alias.id,
      note: 'lunch "money"',
    );

    final res = await BackupService().exportCsv(language: 'en');
    final lines =
        const LineSplitter().convert(await File(res.path).readAsString());
    expect(
        lines.first,
        'date,amount,currency,type,type_label,merchant,merchant_name,'
        'purpose,purpose_label,note,tags,reference,status');

    final row = lines[1];
    // Machine-readable values for analysis…
    expect(row, contains('lendOut'));
    expect(row, contains('groceries'));
    expect(row, contains('PSO SHAHRAH-E-FAISAL'));
    // …alongside human-readable labels…
    expect(row, contains('Lent'));
    expect(row, contains('Groceries'));
    // …the friendly name the user taught the app, and CSV-escaped quotes.
    expect(row, contains('PSO Petrol Pump'));
    expect(row, contains('"lunch ""money"""'));

    // Urdu labels land in the user's language.
    final ur = await BackupService().exportCsv(language: 'ur');
    final urRow =
        (await dataRows(ur.path)).singleWhere((r) => r.contains('lendOut'));
    expect(urRow, contains('ادھار دیا'));
    expect(urRow, contains('گروسری'));
  });

  test('JSON backup excludes audit and round-trips through importJson',
      () async {
    final db = await YaadDb.db;
    await insertTxn(date: DateTime(2026, 9, 5), amount: 1500);
    await db.insert('people', Person(name: 'Ahmed').toMap());
    await db.insert('audit', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'entity': 'transaction',
      'entityId': 'x',
      'action': 'create',
      'detail': 'debug trail',
    });

    final path = await BackupService().exportJson();
    final data =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect(data.containsKey('audit'), isFalse);
    expect((data['transactions'] as List), hasLength(1));
    expect((data['people'] as List), hasLength(1));

    await YaadDb.wipeAll();
    final summary = await BackupService().importJson(path);
    expect(summary.added, 2);
    // The backup includes the accounts table. The seeded accounts
    // already exist and are matched by id — since v1.5 they are
    // UPDATED in place from the backup (rename + opening balance
    // survive a fresh-install restore), so they count as neither
    // added nor skipped, and are never duplicated. Any NON-seed
    // account another test left in the shared test DB is already
    // present, so it counts as skipped — derive the expectation
    // from the backup instead of assuming an empty accounts table.
    final accountRows = (data['accounts'] as List).cast<Map>();
    const seedIds = {'meezan', 'savings', 'cash'};
    final nonSeedCount =
        accountRows.where((a) => !seedIds.contains(a['id'])).length;
    expect(accountRows.length, greaterThanOrEqualTo(3));
    expect(summary.skipped, nonSeedCount);
    expect(await YaadDb.txns(), hasLength(1));
    final people = await db.query('people');
    expect(people, hasLength(1));
    // Importing again skips everything that already exists (the seed
    // accounts are silently re-updated to the same values).
    final again = await BackupService().importJson(path);
    expect(again.added, 0);
    expect(again.skipped, 2 + nonSeedCount);
  });

  test('legacy backup that still contains audit imports fine', () async {
    final txn = YaadTransaction(
        amount: 900,
        dateTime: DateTime(2026, 8, 1),
        kind: TxnKind.receive,
        purpose: 'salary');
    final legacy = {
      'app': 'yaad',
      'formatVersion': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'transactions': [txn.toMap()],
      'people': [],
      'lending': [],
      'repayments': [],
      'aliases': [],
      'audit': [
        {
          'id': 1,
          'at': 1,
          'entity': 'transaction',
          'entityId': 'x',
          'action': 'create',
          'detail': 'old debug trail'
        }
      ],
    };
    final dir = await Directory.systemTemp.createTemp('yaad-legacy');
    final path = '${dir.path}/legacy.json';
    await File(path).writeAsString(jsonEncode(legacy));

    final summary = await BackupService().importJson(path);
    expect(summary.added, 1);
    expect(await YaadDb.txns(), hasLength(1));
  });

  test('every English string has an Urdu translation', () {
    expect(Strings.urduComplete, isTrue);
  });
}
