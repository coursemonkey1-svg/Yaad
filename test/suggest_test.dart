import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/services/suggest.dart';

/// Smart-suggestion ranking: recency-weighted, SQL-only, deterministic
/// via the optional `now` parameter. Runs on the real SQLite engine via
/// ffi, in its own databases directory so parallel test files never
/// share the yaad.db file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final suggest = SuggestionService();
  // Fixed "today" for every test: 2026-09-30.
  final now = DateTime(2026, 9, 30);
  int id = 0;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    // Isolate this file's database from other test files.
    final dir = Directory.systemTemp.createTempSync('yaad_suggest_test');
    await databaseFactoryFfi.setDatabasesPath(dir.path);
  });

  setUp(() async {
    final db = await YaadDb.db;
    await db.delete('transactions');
    await db.delete('aliases');
  });

  Future<void> txn(
      {required String merchant,
      required String purpose,
      required DateTime date,
      String? aliasId}) async {
    final db = await YaadDb.db;
    final ms = date.millisecondsSinceEpoch;
    await db.insert('transactions', {
      'id': 'sug-${id++}',
      'amount': 100.0,
      'currency': 'PKR',
      'dateTime': ms,
      'direction': 'out',
      'rawMerchant': merchant,
      'aliasId': aliasId,
      'purpose': purpose,
      'note': '',
      'tags': '[]',
      'source': 'manual',
      'status': 'recorded',
      'createdAt': ms,
      'updatedAt': ms,
    });
  }

  DateTime daysAgo(int n) => now.subtract(Duration(days: n));

  test('recent use beats ten stale uses of another purpose', () async {
    // 10x "food", all 200 days old (weight 1 each -> score 10).
    for (var i = 0; i < 10; i++) {
      await txn(merchant: 'CORNER STORE', purpose: 'food', date: daysAgo(200));
    }
    // 1x "groceries", yesterday (weight 20 -> score 20).
    await txn(merchant: 'CORNER STORE', purpose: 'groceries', date: daysAgo(1));

    final s = await suggest.suggestPurpose('CORNER STORE', now: now);
    expect(s, isNotNull);
    expect(s!.purpose, 'groceries');
    // The banner shows the purpose's display label, not its raw id.
    expect(s.reason,
        'You chose "Groceries" for this merchant 1 time before');
  });

  test('a dominant old habit still beats a single recent outlier', () async {
    // 50x "food", all 200 days old (score 50).
    for (var i = 0; i < 50; i++) {
      await txn(merchant: 'OLD HABIT', purpose: 'food', date: daysAgo(200));
    }
    // 1x "groceries", yesterday (score 20).
    await txn(merchant: 'OLD HABIT', purpose: 'groceries', date: daysAgo(1));

    final s = await suggest.suggestPurpose('OLD HABIT', now: now);
    expect(s, isNotNull);
    expect(s!.purpose, 'food');
  });

  test('with equal recency, higher frequency wins', () async {
    for (var i = 0; i < 3; i++) {
      await txn(merchant: 'BAKERY', purpose: 'food', date: daysAgo(2));
    }
    await txn(merchant: 'BAKERY', purpose: 'groceries', date: daysAgo(2));

    final s = await suggest.suggestPurpose('BAKERY', now: now);
    expect(s, isNotNull);
    expect(s!.purpose, 'food');
    expect(s.reason, 'You chose "Food" for this merchant 3 times before');
  });

  test('empty history returns null', () async {
    expect(await suggest.suggestPurpose('NEVER SEEN', now: now), isNull);
    expect(await suggest.suggestPurpose('', now: now), isNull);
    expect(await suggest.suggestPurpose('   ', now: now), isNull);
  });

  test('alias fallback still works and is recency-weighted', () async {
    final db = await YaadDb.db;
    await db.insert('aliases', {
      'id': 'alias-1',
      'rawName': 'MY CORNER SHOP',
      'alias': 'corner shop',
      'usageCount': 2,
      'lastUsed': now.millisecondsSinceEpoch,
    });
    // The raw name itself was never used as a merchant, so path 1
    // (exact merchant match) finds nothing and the alias path runs.
    await txn(
        merchant: 'POS 001 LAHORE',
        purpose: 'food',
        date: daysAgo(200),
        aliasId: 'alias-1');
    await txn(
        merchant: 'POS 002 LAHORE',
        purpose: 'groceries',
        date: daysAgo(1),
        aliasId: 'alias-1');

    final s = await suggest.suggestPurpose('MY CORNER SHOP', now: now);
    expect(s, isNotNull);
    expect(s!.purpose, 'groceries');
    expect(s.reason, 'Based on your alias "corner shop"');
  });

  test('topPurposes ranks the recently used purpose first', () async {
    for (var i = 0; i < 10; i++) {
      await txn(merchant: 'M1', purpose: 'transport', date: daysAgo(200));
    }
    await txn(merchant: 'M2', purpose: 'groceries', date: daysAgo(1));

    final top = await suggest.topPurposes(now: now);
    expect(top.first, 'groceries');
    expect(top, contains('transport'));
  });
}
