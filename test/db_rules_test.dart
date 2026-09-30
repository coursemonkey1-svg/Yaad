import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/services/importer.dart';

/// DB-backed rules: the v1 -> v2 migration, money-model totals, and the
/// statement importer. Runs on the real SQLite engine via ffi.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  Future<String> freshDbPath() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'yaad.db');
    try {
      await File(path).delete();
    } catch (_) {}
    return path;
  }

  /// Faithful replica of the v1 schema (from git, pre-migration).
  /// A real v1 install has ALL these tables; the v1->v2 upgrade only
  /// adds the `kind` column to transactions.
  Future<void> _v1Create(Database db) async {
    await db.execute('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        dateTime INTEGER NOT NULL,
        direction TEXT NOT NULL,
        rawMerchant TEXT NOT NULL,
        aliasId TEXT,
        purpose TEXT NOT NULL,
        note TEXT NOT NULL,
        tags TEXT NOT NULL,
        receiptPath TEXT,
        bankReference TEXT,
        source TEXT NOT NULL,
        status TEXT NOT NULL,
        personId TEXT,
        linkedLendingId TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE people(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        note TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE lending(
        id TEXT PRIMARY KEY,
        personId TEXT NOT NULL,
        type TEXT NOT NULL,
        originalAmount REAL NOT NULL,
        currency TEXT NOT NULL,
        date INTEGER NOT NULL,
        reason TEXT NOT NULL,
        dueDate INTEGER,
        note TEXT NOT NULL,
        receiptPath TEXT,
        isOwedToMe INTEGER NOT NULL,
        status TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE repayments(
        id TEXT PRIMARY KEY,
        lendingId TEXT NOT NULL,
        amount REAL NOT NULL,
        date INTEGER NOT NULL,
        note TEXT NOT NULL,
        transactionId TEXT
      )''');
    await db.execute('''
      CREATE TABLE aliases(
        id TEXT PRIMARY KEY,
        rawName TEXT NOT NULL UNIQUE,
        alias TEXT NOT NULL,
        usageCount INTEGER NOT NULL,
        lastUsed INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at INTEGER NOT NULL,
        entity TEXT NOT NULL,
        entityId TEXT NOT NULL,
        action TEXT NOT NULL,
        detail TEXT NOT NULL
      )''');
  }

  Future<void> createV1(String path) async {
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, v) => _v1Create(db),
        ));
    int id = 0;
    Future<void> v1row(
        {required double amount,
        required String direction,
        required String purpose,
        required String merchant}) async {
      final now = DateTime(2026, 9, 15).millisecondsSinceEpoch;
      await db.insert('transactions', {
        'id': 'v1-${id++}',
        'amount': amount,
        'currency': 'PKR',
        'dateTime': now,
        'direction': direction,
        'rawMerchant': merchant,
        'purpose': purpose,
        'note': '',
        'tags': '[]',
        'source': 'manual',
        'status': 'recorded',
        'createdAt': now,
        'updatedAt': now,
      });
    }

    await v1row(
        amount: 5000, direction: 'out', purpose: 'loan', merchant: 'LENT ALI');
    await v1row(
        amount: 3000,
        direction: 'incoming',
        purpose: 'loan',
        merchant: 'BORROWED SARA');
    await v1row(
        amount: 1000,
        direction: 'out',
        purpose: 'repaymentIn',
        merchant: 'REPAID ALI');
    await v1row(
        amount: 2450,
        direction: 'out',
        purpose: 'groceries',
        merchant: 'KHAADI');
    await v1row(
        amount: 50000,
        direction: 'incoming',
        purpose: 'salary',
        merchant: 'SALARY');
    await v1row(
        amount: 10000,
        direction: 'ownTransfer',
        purpose: 'transfer',
        merchant: 'OWN ACCT');
    await db.close();
  }

  test('v1 -> v2 migration backfills kind; lending never becomes spending',
      () async {
    await freshDbPath();
    // Placeholder so the file exists at YaadDb's path before YaadDb opens it.
    final dir = await getDatabasesPath();
    await createV1(p.join(dir, 'yaad.db'));

    final d = await YaadDb.db; // triggers the real onUpgrade
    final rows = await d.query('transactions');
    final kinds = {
      for (final r in rows) r['rawMerchant'] as String: r['kind'] as String?
    };
    expect(kinds['LENT ALI'], 'lendOut');
    expect(kinds['BORROWED SARA'], 'borrowIn');
    expect(kinds['REPAID ALI'], 'repayOut');
    expect(kinds['KHAADI'], 'spend');
    expect(kinds['SALARY'], 'receive');
    expect(kinds['OWN ACCT'], 'transfer');
  });

  test('sumSpent counts only kind=spend', () async {
    final from = DateTime(2026, 9, 1).millisecondsSinceEpoch;
    final to = DateTime(2026, 9, 30, 23, 59, 59).millisecondsSinceEpoch;
    final spent = await YaadDb.sumSpent(from, to);
    // Only the KHAADI groceries row (2450) is spend; the 5000 lent out,
    // 1000 repaid and 10000 own-transfer must NOT count.
    expect(spent, 2450);
    final received = await YaadDb.sumReceived(from, to);
    // 50000 salary only; the 3000 borrowed is not "received".
    expect(received, 50000);
    final lent = await YaadDb.sumByKind(TxnKind.lendOut, from, to);
    expect(lent, 5000);
    final transferred =
        await YaadDb.sumByKind(TxnKind.transfer, from, to);
    expect(transferred, 10000);
  });

  test('importer: parse -> commit -> re-parse flags duplicates', () async {
    // Clean slate: the migration test's rows are still in this DB.
    final d = await YaadDb.db;
    await d.delete('transactions');

    final dir = Directory.systemTemp.createTempSync('yaad_import');
    final csv = File(p.join(dir.path, 'stmt.csv'));
    await csv.writeAsString(
        'Date,Description,Amount\n'
        '2026-09-10,KHAADI LAHORE,-2450\n'
        '2026-09-11,SALARY CREDIT,50000\n'
        '2026-09-12,Transfer to own account,-10000\n'
        '2026-09-13,Transfer from own account,10000\n');

    final importer = StatementImporter();
    final first = await importer.parseFile(csv.path);
    expect(first.pdfNoText, isFalse);
    expect(first.errors, isEmpty);
    expect(first.rows.length, 4);
    // Transfer pair flagged but NOT auto-applied.
    final flagged =
        first.rows.where((r) => r.suggestedTransfer).toList();
    expect(flagged.length, 2);
    expect(first.rows.every((r) => r.kind != TxnKind.transfer), isTrue);

    final report = await importer.commitRows(
        first.rows.where((r) => r.selected).toList(),
        first.mappingSignature,
        mapping: first.mapping);
    expect(report.imported, 4);
    expect(report.duplicates, 0);

    // Importing the same file again: every row is a duplicate.
    final second = await importer.parseFile(csv.path);
    expect(second.rows.every((r) => r.isDuplicate), isTrue);
    final report2 = await importer.commitRows(
        second.rows.where((r) => r.selected).toList(),
        second.mappingSignature,
        mapping: second.mapping);
    expect(report2.imported, 0);
    expect(report2.duplicates, 0); // none selected -> none re-checked

    dir.deleteSync(recursive: true);
  });
}
