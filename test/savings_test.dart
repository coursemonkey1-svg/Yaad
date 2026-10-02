import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/models/account.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/home.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Home "Left" line + the Savings section (v1.4-home).
/// Savings moves are single transfer rows (accountId = from,
/// toAccountId = to); the v5 → v6 migration adds the toAccountId
/// column. Runs on the real SQLite engine via ffi.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-savings-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  Future<String> dbDir() async => getDatabasesPath();

  /// Faithful replica of the v5 schema: transactions WITH accountId
  /// but WITHOUT toAccountId, plus the accounts table.
  Future<void> _v5Create(Database db) async {
    await db.execute('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        dateTime INTEGER NOT NULL,
        direction TEXT NOT NULL,
        kind TEXT,
        rawMerchant TEXT NOT NULL,
        aliasId TEXT,
        purpose TEXT NOT NULL,
        note TEXT NOT NULL,
        tags TEXT NOT NULL,
        receiptPath TEXT,
        audioPath TEXT,
        voiceNote TEXT,
        bankReference TEXT,
        source TEXT NOT NULL,
        status TEXT NOT NULL,
        personId TEXT,
        linkedLendingId TEXT,
        accountId TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE accounts(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        customName INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL
      )''');
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final a in Account.seeds()) {
      await db.insert('accounts', a.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.execute('''
      CREATE TABLE audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at INTEGER NOT NULL,
        entity TEXT NOT NULL,
        entityId TEXT NOT NULL,
        action TEXT NOT NULL,
        detail TEXT NOT NULL
      )''');
    await db.insert('transactions', {
      'id': 'v5-keep',
      'amount': 2500.0,
      'currency': 'PKR',
      'dateTime': now,
      'direction': 'out',
      'kind': 'spend',
      'rawMerchant': 'OLD SHOP',
      'purpose': 'groceries',
      'note': '',
      'tags': '[]',
      'source': 'manual',
      'status': 'confirmed',
      'accountId': 'meezan',
      'createdAt': now,
      'updatedAt': now,
    });
  }

  // NOTE: no global setUp clearing the DB — the migration test below
  // must own the database file before YaadDb ever opens it. Every
  // later test clears transactions explicitly first.
  Future<void> _clearTxns() async {
    final d = await YaadDb.db;
    await d.delete('transactions');
  }

  test('v5 -> v6 migration adds toAccountId and preserves every row',
      () async {
    final dir = await dbDir();
    try {
      await File(p.join(dir, 'yaad.db')).delete();
    } catch (_) {}
    final v5 = await databaseFactoryFfi.openDatabase(
        p.join(dir, 'yaad.db'),
        options: OpenDatabaseOptions(
          version: 5,
          onCreate: (db, v) => _v5Create(db),
        ));
    await v5.close();

    await YaadDb.db; // triggers the real onUpgrade

    final d = await YaadDb.db;
    final cols = await d.rawQuery('PRAGMA table_info(transactions)');
    expect(cols.any((c) => c['name'] == 'toAccountId'), isTrue);
    // The old row survived, untouched, destination unknown.
    final kept = await YaadDb.txnById('v5-keep');
    expect(kept, isNotNull);
    expect(kept!.amount, 2500);
    expect(kept.accountId, 'meezan');
    expect(kept.toAccountId, isNull);
    // New savings transfers round-trip the destination account.
    await YaadDb.insertTxn(YaadTransaction(
      id: 'v6-xfer',
      amount: 1000,
      dateTime: DateTime.now(),
      direction: TxnDirection.ownTransfer,
      kind: TxnKind.transfer,
      purpose: 'savings',
      source: TxnSource.manual,
      accountId: 'meezan',
      toAccountId: 'savings',
    ));
    final back = await YaadDb.txnById('v6-xfer');
    expect(back!.toAccountId, 'savings');
    expect(back.accountId, 'meezan');

    // Heal the shared test DB: the partial v5 schema above lives at the
    // shared test-DB path (every DB test file uses it) and lacks the
    // people/lending/repayments/aliases/custom_purposes tables. Create
    // them here so a leftover partial file can never break another
    // file's tests with "no such table". (Deleting the file instead is
    // NOT safe: tests keep writing through YaadDb's cached connection,
    // and SQLite refuses writes once its file is moved.)
    final dh = await YaadDb.db;
    for (final ddl in [
      '''CREATE TABLE IF NOT EXISTS people(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        note TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS lending(
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
      )''',
      '''CREATE TABLE IF NOT EXISTS repayments(
        id TEXT PRIMARY KEY,
        lendingId TEXT NOT NULL,
        amount REAL NOT NULL,
        date INTEGER NOT NULL,
        note TEXT NOT NULL,
        transactionId TEXT
      )''',
      '''CREATE TABLE IF NOT EXISTS aliases(
        id TEXT PRIMARY KEY,
        rawName TEXT NOT NULL UNIQUE,
        alias TEXT NOT NULL,
        usageCount INTEGER NOT NULL,
        lastUsed INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS custom_purposes(
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )''',
    ]) {
      await dh.execute(ddl);
    }
  });

  /// A savings move, the way the sheet records it: one transfer row.
  Future<void> _move(double amount, bool toSavings, int atMs) =>
      YaadDb.insertTxn(YaadTransaction(
        amount: amount,
        dateTime: DateTime.fromMillisecondsSinceEpoch(atMs),
        direction: TxnDirection.ownTransfer,
        kind: TxnKind.transfer,
        purpose: 'savings',
        source: TxnSource.manual,
        accountId: toSavings ? Account.seedMeezan : Account.seedSavings,
        toAccountId: toSavings ? Account.seedSavings : Account.seedMeezan,
      ));

  Future<void> _spend(double amount, int atMs) =>
      YaadDb.insertTxn(YaadTransaction(
        amount: amount,
        dateTime: DateTime.fromMillisecondsSinceEpoch(atMs),
        kind: TxnKind.spend,
        rawMerchant: 'SHOP',
        accountId: Account.seedMeezan,
      ));

  Future<void> _receive(double amount, int atMs) =>
      YaadDb.insertTxn(YaadTransaction(
        amount: amount,
        dateTime: DateTime.fromMillisecondsSinceEpoch(atMs),
        kind: TxnKind.receive,
        rawMerchant: 'PAY',
        accountId: Account.seedMeezan,
      ));

  test('savings total is in minus out', () async {
    await _clearTxns();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _move(5000, true, now);
    await _move(3000, true, now);
    await _move(2000, false, now);
    expect(await YaadDb.savingsTotal(), 6000);
    expect(await YaadDb.savingsNet(0, now), 6000);
  });

  test('savingsNet respects the month window', () async {
    await _clearTxns();
    final old = DateTime(2026, 1, 5).millisecondsSinceEpoch;
    final n = DateTime.now();
    final now = n.millisecondsSinceEpoch;
    await _move(9000, true, old); // last quarter — not this month
    await _move(4000, true, now);
    expect(await YaadDb.savingsTotal(), 13000);
    final mStart = DateTime(n.year, n.month, 1).millisecondsSinceEpoch;
    expect(await YaadDb.savingsNet(mStart, now), 4000);
  });

  test('excluded transfers do not move the savings total', () async {
    await _clearTxns();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _move(5000, true, now);
    await YaadDb.insertTxn(YaadTransaction(
      amount: 5000,
      dateTime: DateTime.fromMillisecondsSinceEpoch(now),
      direction: TxnDirection.ownTransfer,
      kind: TxnKind.transfer,
      purpose: 'savings',
      source: TxnSource.manual,
      status: TxnStatus.excluded,
      accountId: Account.seedSavings,
      toAccountId: Account.seedMeezan,
    ));
    expect(await YaadDb.savingsTotal(), 5000);
  });

  test('savings moves never touch the month spend/receive totals',
      () async {
    await _clearTxns();
    final n = DateTime.now();
    final mStart = DateTime(n.year, n.month, 1).millisecondsSinceEpoch;
    final now = n.millisecondsSinceEpoch;
    await _spend(1000, now);
    await _receive(5000, now);
    await _move(2000, true, now);
    await _move(700, false, now);
    expect(await YaadDb.sumSpent(mStart, now), 1000);
    expect(await YaadDb.sumReceived(mStart, now), 5000);
  });

  group('monthLeft', () {
    test('positive: received minus spent minus parked', () {
      expect(
          monthLeft(received: 10000, spent: 3000, parked: 2000), 5000);
    });

    test('zero: everything accounted for', () {
      expect(monthLeft(received: 5000, spent: 3000, parked: 2000), 0);
    });

    test('negative: spent more than received — honest number', () {
      expect(monthLeft(received: 2000, spent: 3000, parked: 0), -1000);
    });

    test('negative: parked more than the month brought in', () {
      expect(
          monthLeft(received: 5000, spent: 1000, parked: 6000), -2000);
    });
  });

  test('left falls when money is parked, rises when taken back',
      () async {
    await _clearTxns();
    final n = DateTime.now();
    final mStart = DateTime(n.year, n.month, 1).millisecondsSinceEpoch;
    final now = n.millisecondsSinceEpoch;
    await _receive(10000, now);
    await _spend(1000, now);

    Future<double> left() async {
      final r = await YaadDb.sumReceived(mStart, now);
      final sp = await YaadDb.sumSpent(mStart, now);
      final parked = await YaadDb.savingsNet(mStart, now);
      return monthLeft(received: r, spent: sp, parked: parked);
    }

    expect(await left(), 9000);
    await _move(3000, true, now); // park it
    expect(await left(), 6000);
    await _move(1000, false, now); // take some back
    expect(await left(), 7000);
  });

  test('every new string has an Urdu translation', () {
    expect(Strings.urduComplete, isTrue);
    const en = Strings('en');
    const ur = Strings('ur');
    for (final k in [
      'left',
      'savings',
      'addToSavings',
      'takeBack',
      'move',
      'savingsEmpty',
      'purpose_savings',
    ]) {
      expect(en.get(k), isNot(k));
      expect(ur.get(k), isNot(k));
      expect(ur.get(k), isNot(en.get(k)));
    }
  });
}
