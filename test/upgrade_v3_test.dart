import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/models/account.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Regression test for the v8 upgrade trap (found independently by
/// two v1.5 audit workers): upgrading an install on DB <= v4 runs the
/// < 5 step, which seeds accounts via Account.toMap() — a map that
/// (since v1.5) carries openingBalance. If the column doesn't exist
/// yet at seeding time, onUpgrade throws and the app can NEVER open
/// its database again. This test drives a faithful v3 database all
/// the way to v8 and proves the rows survive.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-upgrade-v3-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  /// Faithful v3 schema: transactions WITH kind (v2) and
  /// custom_purposes (v3), WITHOUT audioPath/voiceNote (v4),
  /// accountId (v5), toAccountId (v6), isDemo (v7), openingBalance (v8).
  Future<void> _v3Create(Database db) async {
    await db.execute('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY, amount REAL NOT NULL, currency TEXT NOT NULL,
        dateTime INTEGER NOT NULL, direction TEXT NOT NULL, kind TEXT,
        rawMerchant TEXT NOT NULL, aliasId TEXT, purpose TEXT NOT NULL,
        note TEXT NOT NULL, tags TEXT NOT NULL, receiptPath TEXT,
        bankReference TEXT, source TEXT NOT NULL, status TEXT NOT NULL,
        personId TEXT, linkedLendingId TEXT,
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
        id TEXT PRIMARY KEY, label TEXT NOT NULL, createdAt INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
        entity TEXT NOT NULL, entityId TEXT NOT NULL, action TEXT NOT NULL,
        detail TEXT NOT NULL)''');
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('transactions', {
      'id': 'v3-keep',
      'amount': 4321.0,
      'currency': 'PKR',
      'dateTime': now,
      'direction': 'out',
      'kind': 'spend',
      'rawMerchant': 'ANCIENT SHOP',
      'purpose': 'groceries',
      'note': 'from the v1.2 days',
      'tags': '',
      'source': 'manual',
      'status': 'confirmed',
      'createdAt': now,
      'updatedAt': now,
    });
  }

  test('v3 -> v8 upgrade completes; seeds, columns and rows survive',
      () async {
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'yaad.db')).delete();
    } catch (_) {}
    final v3 = await databaseFactoryFfi.openDatabase(
        p.join(dir, 'yaad.db'),
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, v) => _v3Create(db),
        ));
    await v3.close();

    // The real upgrade chain — this is the call that used to throw
    // "table accounts has no column named openingBalance".
    final d = await YaadDb.db;

    final acctCols = await d.rawQuery('PRAGMA table_info(accounts)');
    expect(acctCols.any((c) => c['name'] == 'openingBalance'), isTrue);
    final txnCols = await d.rawQuery('PRAGMA table_info(transactions)');
    for (final col in [
      'audioPath',
      'voiceNote',
      'accountId',
      'toAccountId',
      'isDemo',
    ]) {
      expect(txnCols.any((c) => c['name'] == col), isTrue, reason: col);
    }
    // Accounts were seeded by the < 5 step despite the new column.
    final accounts = await YaadDb.accounts();
    expect(accounts.map((a) => a.id),
        containsAll([Account.seedMeezan, Account.seedSavings, Account.seedCash]));
    expect(accounts.every((a) => a.openingBalance == 0), isTrue);
    // The old row survived, backfilled onto the default account.
    final kept = await YaadDb.txnById('v3-keep');
    expect(kept, isNotNull);
    expect(kept!.amount, 4321);
    expect(kept.accountId, Account.seedMeezan);
    expect(kept.isDemo, isFalse);
    // And balances work on the upgraded database.
    expect((await YaadDb.accountBalances())[Account.seedMeezan], -4321);
  });
}
