import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
import 'package:yaad/services/backup.dart';
import 'package:yaad/widgets/filter_sheet.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Account tags (v1.4 foundation): migration backfill, CRUD with safe
/// delete, the Activity account filter, and backup/restore round-trip.
/// Runs on the real SQLite engine via ffi.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-accounts-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  Future<String> dbDir() async => getDatabasesPath();

  /// Faithful replica of the v4 schema: transactions WITHOUT the
  /// accountId column, and no accounts table at all.
  Future<void> _v4Create(Database db) async {
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
      CREATE TABLE custom_purposes(
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        createdAt INTEGER NOT NULL
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

  Future<void> createV4(String path, {int txnCount = 3}) async {
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, v) => _v4Create(db),
        ));
    final now = DateTime(2026, 9, 15).millisecondsSinceEpoch;
    for (var i = 0; i < txnCount; i++) {
      await db.insert('transactions', {
        'id': 'v4-$i',
        'amount': 1000.0 + i,
        'currency': 'PKR',
        'dateTime': now,
        'direction': 'out',
        'kind': 'spend',
        'rawMerchant': 'OLD SHOP $i',
        'purpose': 'groceries',
        'note': '',
        'tags': '[]',
        'source': 'manual',
        'status': 'confirmed',
        'createdAt': now,
        'updatedAt': now,
      });
    }
    await db.close();
  }

  test('v4 -> v5 migration seeds accounts and backfills every row',
      () async {
    final dir = await dbDir();
    try {
      await File(p.join(dir, 'yaad.db')).delete();
    } catch (_) {}
    await createV4(p.join(dir, 'yaad.db'));

    await YaadDb.db; // triggers the real onUpgrade

    final accounts = await YaadDb.accounts();
    expect(
        accounts.map((a) => a.id).toSet(),
        {'meezan', 'savings', 'cash'});

    // Every pre-existing row lands on the default account — none NULL.
    final d = await YaadDb.db;
    final nulls = await d.rawQuery(
        'SELECT COUNT(*) c FROM transactions WHERE accountId IS NULL');
    expect(nulls.first['c'], 0);
    final txns = await YaadDb.txns(limit: 100);
    expect(txns, hasLength(3));
    expect(txns.every((t) => t.accountId == 'meezan'), isTrue);
  });

  test('account CRUD: add, rename, duplicate guard', () async {
    final a = await YaadDb.insertAccount('Holiday fund');
    expect(a.name, 'Holiday fund');

    var accounts = await YaadDb.accounts();
    expect(accounts.any((x) => x.id == a.id), isTrue);

    await YaadDb.renameAccount(a.id, 'Holiday 2026');
    final renamed = await YaadDb.accountById(a.id);
    expect(renamed!.name, 'Holiday 2026');
    // A renamed seed keeps its id; a renamed custom account shows
    // the user's own label verbatim in both languages.
    expect(renamed.displayName(const Strings('en')), 'Holiday 2026');
    expect(renamed.displayName(const Strings('ur')), 'Holiday 2026');

    expect(() => YaadDb.insertAccount('holiday 2026'),
        throwsA(isA<StateError>()));
    expect(() => YaadDb.renameAccount('savings', 'Holiday 2026'),
        throwsA(isA<StateError>()));
    expect(await YaadDb.accountNameExists('HOLIDAY 2026'), isTrue);

    // Seeded accounts show localised labels until renamed.
    final meezan = await YaadDb.accountById('meezan');
    expect(meezan!.displayName(const Strings('en')), 'Meezan');
    expect(meezan.displayName(const Strings('ur')), 'میزان');
    accounts = await YaadDb.accounts();
    expect(accounts.map((x) => x.id),
        containsAll(['meezan', 'savings', 'cash']));
  });

  test('deleting an account reassigns its transactions, never deletes',
      () async {
    final d = await YaadDb.db;
    final now = DateTime(2026, 9, 15).millisecondsSinceEpoch;
    final acct = await YaadDb.insertAccount('Temp pot');
    await d.insert(
        'transactions',
        YaadTransaction(
          amount: 500,
          dateTime: DateTime.fromMillisecondsSinceEpoch(now),
          kind: TxnKind.spend,
          rawMerchant: 'TEMP SHOP',
          accountId: acct.id,
        ).toMap());

    await YaadDb.deleteAccount(acct.id, reassignTo: 'meezan');

    expect(await YaadDb.accountById(acct.id), isNull);
    // The transaction survived and moved to the default account.
    final moved = await YaadDb.txns(
        query: 'TEMP SHOP', accountIds: {'meezan'});
    expect(moved, hasLength(1));
    expect(moved.first.accountId, 'meezan');
    final orphaned = await d.rawQuery(
        'SELECT COUNT(*) c FROM transactions WHERE accountId = ?',
        [acct.id]);
    expect(orphaned.first['c'], 0);
  });

  test('resolveDefaultAccountId falls back when the id is gone', () async {
    final accounts = await YaadDb.accounts();
    expect(
        resolveDefaultAccountId(accounts, 'meezan'), 'meezan');
    expect(
        resolveDefaultAccountId(accounts, 'deleted-id'), 'meezan');
    // Seeds are oldest-first, so the fallback is the Meezan seed.
    expect(accounts.first.id, 'meezan');
  });

  test('txns accountIds filter + per-account sums', () async {
    final d = await YaadDb.db;
    final now = DateTime(2026, 9, 15).millisecondsSinceEpoch;
    Future<void> row(String id, String accountId, double amount) =>
        d.insert(
            'transactions',
            YaadTransaction(
              id: id,
              amount: amount,
              dateTime: DateTime.fromMillisecondsSinceEpoch(now),
              kind: TxnKind.spend,
              rawMerchant: 'FILTER $id',
              accountId: accountId,
            ).toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);

    await row('flt-s1', 'savings', 100);
    await row('flt-s2', 'savings', 200);
    await row('flt-c1', 'cash', 400);

    final savingsOnly =
        await YaadDb.txns(query: 'FILTER', accountIds: {'savings'});
    expect(savingsOnly.map((t) => t.id).toSet(), {'flt-s1', 'flt-s2'});

    final both = await YaadDb.txns(
        query: 'FILTER', accountIds: {'savings', 'cash'});
    expect(both, hasLength(3));

    final from = DateTime(2026, 9, 1).millisecondsSinceEpoch;
    final to = DateTime(2026, 9, 30, 23, 59, 59).millisecondsSinceEpoch;
    expect(await YaadDb.sumSpent(from, to, accountIds: {'savings'}),
        300);
    expect(await YaadDb.sumSpent(from, to, accountIds: {'cash'}), 400);
    expect(await YaadDb.sumSpent(from, to), greaterThanOrEqualTo(700));
  });

  test('txnCountsByAccount counts BOTH legs of a transfer', () async {
    // Fresh accounts, so no other test's rows can pollute the counts.
    final a = await YaadDb.insertAccount('Counts A');
    final b = await YaadDb.insertAccount('Counts B');
    final now = DateTime(2026, 10, 3);

    // Park A -> B (the build-25/26 bug: B showed "0 transactions"
    // after exactly this move, because only the from-leg was counted).
    await YaadDb.insertTxn(YaadTransaction(
      amount: 5000,
      dateTime: now,
      direction: TxnDirection.ownTransfer,
      kind: TxnKind.transfer,
      purpose: 'savings',
      accountId: a.id,
      toAccountId: b.id,
    ));
    // Take part of it back, B -> A.
    await YaadDb.insertTxn(YaadTransaction(
      amount: 2000,
      dateTime: now,
      direction: TxnDirection.ownTransfer,
      kind: TxnKind.transfer,
      purpose: 'savings',
      accountId: b.id,
      toAccountId: a.id,
    ));
    // A plain spend counts once, for its own account only.
    await YaadDb.insertTxn(YaadTransaction(
      amount: 300,
      dateTime: now,
      kind: TxnKind.spend,
      rawMerchant: 'COUNTS SHOP',
      accountId: a.id,
    ));

    final counts = await YaadDb.txnCountsByAccount();
    // A: the park out + the take-back in + the spend = 3.
    expect(counts[a.id], 3);
    // B: the park in + the take-back out = 2.
    expect(counts[b.id], 2);
  });

  test('backup export includes accounts; restore never duplicates seeds',
      () async {
    final path = await BackupService().exportJson();
    final data =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect(data.containsKey('accounts'), isTrue);
    final ids = (data['accounts'] as List)
        .map((r) => (r as Map)['id'] as String)
        .toSet();
    expect(ids, containsAll(['meezan', 'savings', 'cash']));

    final before = (await YaadDb.accounts()).length;
    final summary = await BackupService().importJson(path);
    final after = (await YaadDb.accounts()).length;
    expect(after, before); // seeds matched by id, skipped — not duplicated
    expect(summary.skipped, greaterThanOrEqualTo(before));

    // Re-importing is fully idempotent for accounts too.
    final again = await BackupService().importJson(path);
    expect((await YaadDb.accounts()).length, before);
    expect(again.added, 0);
  });

  test('legacy (pre-accounts) backup restores rows onto the default account',
      () async {
    final txn = YaadTransaction(
        id: 'legacy-1',
        amount: 900,
        dateTime: DateTime(2026, 8, 1),
        kind: TxnKind.receive,
        purpose: 'salary');
    // A v1.3-era backup: no accounts table, no accountId on the row.
    final legacy = {
      'app': 'yaad',
      'formatVersion': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'transactions': [
        {...txn.toMap()}..remove('accountId')
      ],
      'people': [],
      'lending': [],
      'repayments': [],
      'aliases': [],
    };
    final dir = await Directory.systemTemp.createTemp('yaad-legacy-acct');
    final path = '${dir.path}/legacy.json';
    await File(path).writeAsString(jsonEncode(legacy));

    final summary = await BackupService().importJson(path);
    expect(summary.added, 1);
    final restored = await YaadDb.txnById('legacy-1');
    expect(restored, isNotNull);
    expect(restored!.accountId, 'meezan');
  });

  testWidgets('Activity filter sheet: account chips multi-select',
      (tester) async {
    FilterSelection? last;
    // The sheet is taller than the default 800x600 test viewport;
    // give it room so every chip is tappable.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ActivityFilterSheet(
            s: const Strings('en'),
            initialPurposes: const {},
            initialDirection: null,
            initialAccounts: const {},
            customs: const [],
            accounts: Account.seeds(),
            onChanged: (sel) => last = sel,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Savings'), findsOneWidget);
    await tester.tap(find.text('Savings'));
    await tester.pump();
    expect(last, isNotNull);
    expect(last!.accountIds, {'savings'});
    expect(last!.activeCount, 1);

    await tester.tap(find.text('Cash'));
    await tester.pump();
    expect(last!.accountIds, {'savings', 'cash'});

    // Toggling off again clears it.
    await tester.tap(find.text('Savings'));
    await tester.pump();
    expect(last!.accountIds, {'cash'});
  });
}
