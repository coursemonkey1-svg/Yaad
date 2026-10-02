import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/models/account.dart';
import 'package:yaad/models/lending.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/services/backup.dart';
import 'package:yaad/services/demo_data.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Demo data (v1.5): the isDemo marker migration (v6 → v7), add /
/// remove exactness, idempotency, and backup round-trip. Runs on the
/// real SQLite engine via ffi.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-demo-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  Future<String> dbDir() async => getDatabasesPath();

  /// Faithful replica of the v6 schema: every table, transactions
  /// WITH accountId + toAccountId, but NO isDemo anywhere.
  Future<void> _v6Create(Database db) async {
    await db.execute('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY, amount REAL NOT NULL, currency TEXT NOT NULL,
        dateTime INTEGER NOT NULL, direction TEXT NOT NULL, kind TEXT,
        rawMerchant TEXT NOT NULL, aliasId TEXT, purpose TEXT NOT NULL,
        note TEXT NOT NULL, tags TEXT NOT NULL, receiptPath TEXT,
        audioPath TEXT, voiceNote TEXT, bankReference TEXT,
        source TEXT NOT NULL, status TEXT NOT NULL, personId TEXT,
        linkedLendingId TEXT, accountId TEXT, toAccountId TEXT,
        createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE people(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, phone TEXT,
        note TEXT NOT NULL, createdAt INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE lending(
        id TEXT PRIMARY KEY, personId TEXT NOT NULL, type TEXT NOT NULL,
        originalAmount REAL NOT NULL, currency TEXT NOT NULL,
        date INTEGER NOT NULL, reason TEXT NOT NULL, dueDate INTEGER,
        note TEXT NOT NULL, receiptPath TEXT, isOwedToMe INTEGER NOT NULL,
        status TEXT NOT NULL, createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE repayments(
        id TEXT PRIMARY KEY, lendingId TEXT NOT NULL, amount REAL NOT NULL,
        date INTEGER NOT NULL, note TEXT NOT NULL, transactionId TEXT)''');
    await db.execute('''
      CREATE TABLE aliases(
        id TEXT PRIMARY KEY, rawName TEXT NOT NULL UNIQUE,
        alias TEXT NOT NULL, usageCount INTEGER NOT NULL,
        lastUsed INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE custom_purposes(
        id TEXT PRIMARY KEY, label TEXT NOT NULL,
        createdAt INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE accounts(
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        customName INTEGER NOT NULL DEFAULT 0, createdAt INTEGER NOT NULL)''');
    // A real v6 install HAS the three seed accounts (seeded when the
    // table was created in the v5 era) — the replica must too, or it
    // leaves the shared test DB with an empty accounts table and
    // poisons every later suite (no upgrade step ever re-seeds).
    final seedNow = DateTime.now().millisecondsSinceEpoch;
    for (final (id, name) in [
      ('meezan', 'Meezan'),
      ('savings', 'Savings'),
      ('cash', 'Cash'),
    ]) {
      await db.insert('accounts',
          {'id': id, 'name': name, 'customName': 0, 'createdAt': seedNow});
    }
    await db.execute('''
      CREATE TABLE audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
        entity TEXT NOT NULL, entityId TEXT NOT NULL, action TEXT NOT NULL,
        detail TEXT NOT NULL)''');
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('transactions', {
      'id': 'v6-keep',
      'amount': 2500.0,
      'currency': 'PKR',
      'dateTime': now,
      'direction': 'out',
      'kind': 'spend',
      'rawMerchant': 'OLD SHOP',
      'purpose': 'groceries',
      'note': '',
      'tags': '',
      'source': 'manual',
      'status': 'confirmed',
      'accountId': 'meezan',
      'createdAt': now,
      'updatedAt': now,
    });
  }

  // NOTE: no global setUp clearing the DB — the migration test owns
  // the database file before YaadDb ever opens it (same pattern as
  // savings_test). Later tests clear tables explicitly.
  Future<void> _clearAll() async {
    final d = await YaadDb.db;
    for (final t in [
      'transactions',
      'people',
      'lending',
      'repayments',
      'custom_purposes',
    ]) {
      await d.delete(t);
    }
    await YaadDb.refreshCustomPurposeRegistry();
  }

  test('v6 -> v7 migration adds isDemo and preserves rows', () async {
    final dir = await dbDir();
    try {
      await File(p.join(dir, 'yaad.db')).delete();
    } catch (_) {}
    final v6 = await databaseFactoryFfi.openDatabase(
        p.join(dir, 'yaad.db'),
        options: OpenDatabaseOptions(
          version: 6,
          onCreate: (db, v) => _v6Create(db),
        ));
    await v6.close();

    final d = await YaadDb.db; // triggers the real onUpgrade
    for (final t in ['transactions', 'people', 'lending', 'custom_purposes']) {
      final cols = await d.rawQuery('PRAGMA table_info($t)');
      expect(cols.any((c) => c['name'] == 'isDemo'), isTrue,
          reason: '$t must gain isDemo');
    }
    final kept = await YaadDb.txnById('v6-keep');
    expect(kept, isNotNull);
    expect(kept!.amount, 2500);
    expect(kept.isDemo, isFalse);
  });

  test('add demo fills every surface with meaningful figures', () async {
    await _clearAll();
    expect(await DemoData.hasDemo(), isFalse);
    expect(await DemoData.addDemo(), isTrue);
    expect(await DemoData.hasDemo(), isTrue);

    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final lastMonthStart =
        DateTime(now.year, now.month - 1, 1).millisecondsSinceEpoch;
    final monthStart = DateTime(now.year, now.month, 1).millisecondsSinceEpoch;

    // Two months of salary, exact across the whole window.
    expect(await YaadDb.sumReceived(lastMonthStart, nowMs), 370000);
    // Two months of spending, exact across the whole window.
    expect(await YaadDb.sumSpent(lastMonthStart, nowMs), 128259);
    // This month is non-trivial too (Home hero + Left inputs).
    expect(await YaadDb.sumSpent(monthStart, nowMs), greaterThan(0));
    expect(await YaadDb.sumReceived(monthStart, nowMs), greaterThan(0));

    // Savings: 25k + 10k + 15k in, 5k back out = 45,000 parked.
    expect(await YaadDb.savingsTotal(), 45000);

    // Udhaar: Ahmed owes 20,000, repaid 8,000 -> 12,000 outstanding,
    // status partial. Usman: I owe 6,000, untouched.
    final lending = await YaadDb.allLending();
    expect(lending.length, 2);
    final ahmedLoan = lending.firstWhere((l) => l.isOwedToMe);
    expect(ahmedLoan.originalAmount, 20000);
    expect(ahmedLoan.status, LendingStatus.partial);
    expect(await YaadDb.totalRepaid(ahmedLoan.id), 8000);
    expect(ahmedLoan.originalAmount - await YaadDb.totalRepaid(ahmedLoan.id),
        12000);
    final usmanLoan = lending.firstWhere((l) => !l.isOwedToMe);
    expect(usmanLoan.originalAmount, 6000);
    expect(usmanLoan.status, LendingStatus.open);

    // A custom purpose came with it, and a demo spend uses it.
    final customs = await YaadDb.customPurposes();
    expect(customs.any((c) => c.label == 'Gym' && c.isDemo), isTrue);
    final all = await YaadDb.txns(limit: 500);
    expect(all.where((t) => t.purpose.startsWith('custom_')).length, 1);
    // Demo rows span both accounts and both months.
    expect(all.any((t) => t.accountId == Account.seedCash), isTrue);
    expect(all.any((t) => t.accountId == Account.seedSavings), isTrue);
    expect(all.every((t) => t.isDemo), isTrue);
  });

  test('add demo is a no-op when demo data is already present', () async {
    await _clearAll();
    expect(await DemoData.addDemo(), isTrue);
    final countBefore = (await YaadDb.txns(limit: 500)).length;
    expect(await DemoData.addDemo(), isFalse);
    expect((await YaadDb.txns(limit: 500)).length, countBefore);
    expect(await YaadDb.savingsTotal(), 45000);
  });

  test('remove demo restores the exact prior state; real rows survive',
      () async {
    await _clearAll();
    // Real state first: one spend, one person, one open loan.
    final realPerson = Person(name: 'Real Friend');
    await YaadDb.insertPerson(realPerson);
    await YaadDb.insertTxn(YaadTransaction(
      id: 'real-1',
      amount: 1234,
      dateTime: DateTime.now(),
      kind: TxnKind.spend,
      rawMerchant: 'REAL SHOP',
      purpose: 'groceries',
      accountId: Account.seedMeezan,
    ));
    await YaadDb.insertLending(LendingRecord(
      id: 'real-loan',
      personId: realPerson.id,
      originalAmount: 3000,
      date: DateTime.now(),
      isOwedToMe: true,
    ));
    final beforeSpent = await YaadDb.sumSpent(0, 9999999999999);
    final beforeTxns = (await YaadDb.txns(limit: 500)).length;

    await DemoData.addDemo();
    // A real transaction that USES the demo custom purpose: removal
    // must keep the transaction and reassign it, never delete it.
    final customs = await YaadDb.customPurposes();
    final gym = customs.firstWhere((c) => c.isDemo);
    await YaadDb.insertTxn(YaadTransaction(
      id: 'real-uses-gym',
      amount: 2000,
      dateTime: DateTime.now(),
      kind: TxnKind.spend,
      rawMerchant: 'MY GYM',
      purpose: gym.id,
      accountId: Account.seedMeezan,
    ));

    await DemoData.removeDemo();
    expect(await DemoData.hasDemo(), isFalse);

    // Sums and counts are exactly the pre-demo state (+ the one real
    // gym transaction added in between).
    expect(await YaadDb.sumSpent(0, 9999999999999), beforeSpent + 2000);
    expect((await YaadDb.txns(limit: 500)).length, beforeTxns + 1);
    expect(await YaadDb.savingsTotal(), 0);
    // Real rows untouched.
    final real1 = await YaadDb.txnById('real-1');
    expect(real1, isNotNull);
    expect(real1!.isDemo, isFalse);
    final gymTxn = await YaadDb.txnById('real-uses-gym');
    expect(gymTxn, isNotNull);
    expect(gymTxn!.purpose, 'uncategorized');
    // Demo people and purposes gone; real ones stay.
    final people = await YaadDb.people();
    expect(people.map((e) => e.name), contains('Real Friend'));
    expect(people.any((e) => e.isDemo), isFalse);
    expect(await YaadDb.customPurposes(), isEmpty);
    final lending = await YaadDb.allLending();
    expect(lending.length, 1);
    expect(lending.single.id, 'real-loan');
  });

  test('demo rows behave like real rows: viewable and editable', () async {
    await _clearAll();
    await DemoData.addDemo();
    final all = await YaadDb.txns(limit: 500);
    final one = all.firstWhere((t) => t.kind == TxnKind.spend);
    // Edit it the way the edit screen does (copyWith + updateTxn).
    final edited = one.copyWith(amount: one.amount + 100, note: 'edited');
    await YaadDb.updateTxn(edited);
    final back = await YaadDb.txnById(one.id);
    expect(back!.amount, one.amount + 100);
    expect(back.note, 'edited');
    expect(back.isDemo, isTrue,
        reason: 'editing a demo row must not strip its demo marker, '
            'or Remove would leave it behind');
  });

  test('backup round trip keeps demo rows flagged and purposes intact',
      () async {
    await _clearAll();
    await DemoData.addDemo();
    final path = await BackupService().exportJson();
    await _clearAll();
    expect(await DemoData.hasDemo(), isFalse);
    final summary = await BackupService().importJson(path);
    expect(summary.added, greaterThan(0));
    expect(await DemoData.hasDemo(), isTrue);
    expect(await YaadDb.savingsTotal(), 45000);
    expect(
        (await YaadDb.customPurposes()).any((c) => c.label == 'Gym'),
        isTrue);
    // And removal still works on restored demo rows.
    await DemoData.removeDemo();
    expect((await YaadDb.txns(limit: 500)), isEmpty);
  });
}
