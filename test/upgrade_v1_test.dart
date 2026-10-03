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

/// The oldest supported install: a v1 database (the original v1.0
/// schema — no `kind` column, no custom_purposes table, no audio
/// columns, no accounts). The upgrade chain from v1 was never covered
/// (only v3 → current was), so a step that misfires for v1 — a missed
/// backfill, a crash on the missing table — would only ever be found
/// by a v1.0 user upgrading, on their phone. This drives a faithful
/// v1 database through the real chain to the current version.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-upgrade-v1-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  /// Faithful v1 schema: transactions WITHOUT kind (v2), custom_purposes
  /// absent (v3), no audioPath/voiceNote (v4), no accountId (v5),
  /// no toAccountId (v6), no isDemo anywhere (v7).
  Future<void> v1Create(Database db) async {
    await db.execute('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY, amount REAL NOT NULL, currency TEXT NOT NULL,
        dateTime INTEGER NOT NULL, direction TEXT NOT NULL,
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
      CREATE TABLE audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
        entity TEXT NOT NULL, entityId TEXT NOT NULL, action TEXT NOT NULL,
        detail TEXT NOT NULL)''');
    final now = DateTime.now().millisecondsSinceEpoch;
    // A v1.0 spend and a v1.0-era lend (purpose 'loan', direction
    // out) — the < 2 step must derive their kinds from purpose +
    // direction.
    await db.insert('transactions', {
      'id': 'v1-spend',
      'amount': 1500.0,
      'currency': 'PKR',
      'dateTime': now,
      'direction': 'out',
      'rawMerchant': 'V1 SHOP',
      'purpose': 'groceries',
      'note': '',
      'tags': '',
      'source': 'manual',
      'status': 'confirmed',
      'createdAt': now,
      'updatedAt': now,
    });
    await db.insert('transactions', {
      'id': 'v1-lend',
      'amount': 2000.0,
      'currency': 'PKR',
      'dateTime': now,
      'direction': 'out',
      'rawMerchant': 'V1 FRIEND',
      'purpose': 'loan',
      'note': '',
      'tags': '',
      'source': 'manual',
      'status': 'confirmed',
      'createdAt': now,
      'updatedAt': now,
    });
    await db.insert('people', {
      'id': 'v1-person',
      'name': 'V1 Friend',
      'note': '',
      'createdAt': now,
    });
  }

  test('v1 -> current upgrade completes; kinds derived, rows survive',
      () async {
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'yaad.db')).delete();
    } catch (_) {}
    final v1 = await databaseFactoryFfi.openDatabase(
        p.join(dir, 'yaad.db'),
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, v) => v1Create(db),
        ));
    await v1.close();

    // The real upgrade chain, v1 → v8.
    final d = await YaadDb.db;
    expect(await d.getVersion(), 8);

    // custom_purposes was created by the < 3 step.
    final tables = await d.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'");
    expect(tables.map((t) => t['name']), contains('custom_purposes'));

    final spend = await YaadDb.txnById('v1-spend');
    expect(spend, isNotNull);
    expect(spend!.kind.name, 'spend');
    expect(spend.accountId, Account.seedMeezan,
        reason: 'the < 5 step backfills the default account');
    expect(spend.isDemo, isFalse);

    final lend = await YaadDb.txnById('v1-lend');
    expect(lend, isNotNull);
    expect(lend!.kind.name, 'lendOut',
        reason: "v1 'loan' + direction 'out' derives lendOut");

    final person = await YaadDb.personById('v1-person');
    expect(person, isNotNull);
    expect(person!.name, 'V1 Friend');

    // Balances work on the upgraded database: spend −1500, and the
    // lendOut leg −2000 (lending moves the account balance; it is
    // only the month sums that exclude it).
    final balances = await YaadDb.accountBalances();
    expect(balances[Account.seedMeezan], -3500);
  });
}
