import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/models/account.dart';
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

/// Account balances (v1.5): opening balance + all transaction legs,
/// the v7 → v8 migration, and backup preservation. Real SQLite (ffi).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-balances-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  Future<String> dbDir() async => getDatabasesPath();

  /// Faithful v7 schema replica: everything current EXCEPT accounts
  /// has no openingBalance column.
  Future<void> _v7Create(Database db) async {
    await db.execute('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY, amount REAL NOT NULL, currency TEXT NOT NULL,
        dateTime INTEGER NOT NULL, direction TEXT NOT NULL, kind TEXT,
        rawMerchant TEXT NOT NULL, aliasId TEXT, purpose TEXT NOT NULL,
        note TEXT NOT NULL, tags TEXT NOT NULL, receiptPath TEXT,
        audioPath TEXT, voiceNote TEXT, bankReference TEXT,
        source TEXT NOT NULL, status TEXT NOT NULL, personId TEXT,
        linkedLendingId TEXT, accountId TEXT, toAccountId TEXT,
        isDemo INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE people(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, phone TEXT,
        note TEXT NOT NULL, isDemo INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE lending(
        id TEXT PRIMARY KEY, personId TEXT NOT NULL, type TEXT NOT NULL,
        originalAmount REAL NOT NULL, currency TEXT NOT NULL,
        date INTEGER NOT NULL, reason TEXT NOT NULL, dueDate INTEGER,
        note TEXT NOT NULL, receiptPath TEXT, isOwedToMe INTEGER NOT NULL,
        status TEXT NOT NULL, isDemo INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL)''');
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
        isDemo INTEGER NOT NULL DEFAULT 0, createdAt INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE accounts(
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        customName INTEGER NOT NULL DEFAULT 0, createdAt INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
        entity TEXT NOT NULL, entityId TEXT NOT NULL, action TEXT NOT NULL,
        detail TEXT NOT NULL)''');
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('accounts', {
      'id': 'meezan',
      'name': 'Meezan',
      'customName': 0,
      'createdAt': now,
    });
  }

  // Migration test owns the file first (same pattern as the other
  // migration suites). Later tests clear rows explicitly.
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
    // Openings back to a known zero state.
    for (final a in await YaadDb.accounts()) {
      await YaadDb.setOpeningBalance(a.id, 0);
    }
  }

  test('v7 -> v8 migration adds openingBalance, accounts survive',
      () async {
    final dir = await dbDir();
    try {
      await File(p.join(dir, 'yaad.db')).delete();
    } catch (_) {}
    final v7 = await databaseFactoryFfi.openDatabase(
        p.join(dir, 'yaad.db'),
        options: OpenDatabaseOptions(
          version: 7,
          onCreate: (db, v) => _v7Create(db),
        ));
    await v7.close();

    final d = await YaadDb.db; // triggers the real onUpgrade
    final cols = await d.rawQuery('PRAGMA table_info(accounts)');
    expect(cols.any((c) => c['name'] == 'openingBalance'), isTrue);
    final meezan = await YaadDb.accountById(Account.seedMeezan);
    expect(meezan, isNotNull);
    expect(meezan!.openingBalance, 0);
    // The other seeds arrived via _create-independent seeding? No —
    // a v7 file only has the accounts its onCreate wrote; upgrade
    // must not invent or drop rows. Only meezan was in the replica.
    expect((await YaadDb.accounts()).length, 1);
  });

  Future<void> _txn(TxnKind kind, double amount, String account,
          {String? to, TxnStatus status = TxnStatus.confirmed}) =>
      YaadDb.insertTxn(YaadTransaction(
        amount: amount,
        dateTime: DateTime.now(),
        kind: kind,
        direction: kind == TxnKind.transfer
            ? TxnDirection.ownTransfer
            : (kind == TxnKind.receive ||
                    kind == TxnKind.borrowIn ||
                    kind == TxnKind.repayIn)
                ? TxnDirection.incoming
                : TxnDirection.out,
        accountId: account,
        toAccountId: to,
        status: status,
      ));

  test('balance math across every kind, transfers both directions',
      () async {
    await _clearAll();
    // The migration replica left only Meezan; re-seed the other two
    // the way _seedAccounts would on a real install.
    final d = await YaadDb.db;
    for (final a in Account.seeds()) {
      await d.insert('accounts', a.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await YaadDb.setOpeningBalance(Account.seedMeezan, 10000);

    await _txn(TxnKind.receive, 5000, Account.seedMeezan);
    await _txn(TxnKind.spend, 1200, Account.seedMeezan);
    await _txn(TxnKind.lendOut, 2000, Account.seedMeezan);
    await _txn(TxnKind.borrowIn, 3000, Account.seedMeezan);
    await _txn(TxnKind.repayOut, 500, Account.seedMeezan);
    await _txn(TxnKind.repayIn, 700, Account.seedMeezan);
    // Park 4,000 in savings, take 1,500 back.
    await _txn(TxnKind.transfer, 4000, Account.seedMeezan,
        to: Account.seedSavings);
    await _txn(TxnKind.transfer, 1500, Account.seedSavings,
        to: Account.seedMeezan);
    // Excluded rows never count.
    await _txn(TxnKind.spend, 999, Account.seedMeezan,
        status: TxnStatus.excluded);
    await _txn(TxnKind.spend, 100, Account.seedCash);

    final b = await YaadDb.accountBalances();
    expect(b[Account.seedMeezan], 12500);
    expect(b[Account.seedSavings], 2500);
    expect(b[Account.seedCash], -100);
    expect(await YaadDb.totalBalance(), 14900);
  });

  test('editing the opening balance updates totals; new accounts too',
      () async {
    await _clearAll();
    await YaadDb.setOpeningBalance(Account.seedCash, 2500);
    expect((await YaadDb.accountBalances())[Account.seedCash], 2500);
    final jazz = await YaadDb.insertAccount('JazzCash',
        openingBalance: 3000);
    expect((await YaadDb.accountBalances())[jazz.id], 3000);
    await YaadDb.setOpeningBalance(jazz.id, 3500);
    expect((await YaadDb.accountBalances())[jazz.id], 3500);
    // Clean up the extra account so later tests see the seed set.
    final d = await YaadDb.db;
    await d.delete('accounts', where: 'id = ?', whereArgs: [jazz.id]);
  });

  test('backup preserves opening balances incl. renamed seeds', () async {
    await _clearAll();
    await YaadDb.setOpeningBalance(Account.seedMeezan, 7777);
    await YaadDb.renameAccount(Account.seedSavings, 'Rainy day');
    await YaadDb.setOpeningBalance(Account.seedSavings, 42000);
    final path = await BackupService().exportJson();

    // Simulate the fresh-install state: openings zeroed, name back.
    await YaadDb.setOpeningBalance(Account.seedMeezan, 0);
    await YaadDb.setOpeningBalance(Account.seedSavings, 0);
    final d = await YaadDb.db;
    await d.update('accounts', {'name': 'Savings', 'customName': 0},
        where: 'id = ?', whereArgs: [Account.seedSavings]);

    await BackupService().importJson(path);
    final meezan = await YaadDb.accountById(Account.seedMeezan);
    final savings = await YaadDb.accountById(Account.seedSavings);
    expect(meezan!.openingBalance, 7777);
    expect(savings!.openingBalance, 42000);
    expect(savings.name, 'Rainy day');
    expect(savings.customName, isTrue);
    // Restore the seed name for other tests.
    await d.update('accounts', {'name': 'Savings', 'customName': 0},
        where: 'id = ?', whereArgs: [Account.seedSavings]);
  });

  test('demo data sets believable openings; removal restores them',
      () async {
    await _clearAll();
    await YaadDb.setOpeningBalance(Account.seedMeezan, 111);
    await DemoData.addDemo();
    var b = await YaadDb.accountBalances();
    // Savings: 20,000 opening + 45,000 net parked.
    expect(b[Account.seedSavings], 65000);
    // Cash: 5,000 opening + 10,000 in − 650 − 400 spent.
    expect(b[Account.seedCash], 13950);
    // Meezan opening was replaced by the demo's 120,000.
    final meezan = await YaadDb.accountById(Account.seedMeezan);
    expect(meezan!.openingBalance, 120000);

    await DemoData.removeDemo();
    b = await YaadDb.accountBalances();
    // Everything back: his own 111 opening, no demo legs left.
    expect(b[Account.seedMeezan], 111);
    expect(b[Account.seedSavings], 0);
    expect(b[Account.seedCash], 0);
  });
}
