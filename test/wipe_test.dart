import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/account.dart';
import 'package:yaad/models/lending.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/settings.dart';
import 'package:yaad/services/capture_inbox.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Build-27: "Delete all my data" was not a factory reset. It emptied
/// the transaction tables but never touched the accounts table, so
/// the v1.5 opening balances survived — after a successful wipe the
/// Home Balance card still showed the user's money (PKR 21,050 of
/// openings) while everything else read zero. The wipe now resets
/// the accounts to the three seeds at zero, and the settings handler
/// also resets settings, native capture, the capture inbox, the
/// demo openings snapshot, and the native queue files.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('yaad/capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-wipe-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
    await YaadDb.db;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    appState.settings = const AppSettings();
    await CaptureInbox.instance.clear();
  });

  /// A rich pre-wipe state: openings everywhere (incl. a custom
  /// account), transactions, a person + lending + repayment, an
  /// alias, a custom purpose.
  Future<String> seedRich() async {
    final d = await YaadDb.db;
    for (final a in Account.seeds()) {
      await d.insert('accounts', a.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    final custom = await YaadDb.insertAccount('Holiday fund',
        openingBalance: 7000);
    await YaadDb.setOpeningBalance(Account.seedMeezan, 15000);
    await YaadDb.setOpeningBalance(Account.seedSavings, 5000);
    await YaadDb.setOpeningBalance(Account.seedCash, 1000);
    final now = DateTime.now();
    await YaadDb.insertTxn(YaadTransaction(
      amount: 900,
      dateTime: now,
      kind: TxnKind.spend,
      rawMerchant: 'SHOP',
      accountId: Account.seedMeezan,
    ));
    await YaadDb.insertTxn(YaadTransaction(
      amount: 2000,
      dateTime: now,
      direction: TxnDirection.ownTransfer,
      kind: TxnKind.transfer,
      purpose: 'savings',
      source: TxnSource.manual,
      accountId: Account.seedMeezan,
      toAccountId: Account.seedSavings,
    ));
    final person = Person(name: 'Ahmed Raza');
    await YaadDb.insertPerson(person);
    final lending = LendingRecord(
        personId: person.id, originalAmount: 3000, date: now);
    await YaadDb.insertLending(lending);
    await YaadDb.addRepayment(
        Repayment(lendingId: lending.id, amount: 1000, date: now));
    await YaadDb.upsertAlias('SHOP', 'Corner shop');
    await YaadDb.insertCustomPurpose('Gym');
    return custom.id;
  }

  test('wipeAll erases openings and custom accounts, reseeds at zero',
      () async {
    await YaadDb.wipeAll(); // clean slate before seeding
    final customId = await seedRich();
    // Sanity: there really is money on the books before the wipe.
    expect(await YaadDb.totalBalance(), isNot(0));
    expect(await YaadDb.accountById(customId), isNotNull);

    await YaadDb.wipeAll();

    expect(await YaadDb.totalBalance(), 0);
    final balances = await YaadDb.accountBalances();
    expect(
        balances.keys.toSet(),
        {Account.seedMeezan, Account.seedSavings, Account.seedCash});
    expect(balances.values.every((v) => v == 0), isTrue);
    // Exactly the three seeds, in seed order, every opening zero,
    // and the custom account is gone.
    final accounts = await YaadDb.accounts();
    expect(accounts.map((a) => a.id).toList(), [
      Account.seedMeezan,
      Account.seedSavings,
      Account.seedCash,
    ]);
    expect(accounts.every((a) => a.openingBalance == 0), isTrue);
    expect(await YaadDb.accountById(customId), isNull);
    // Every user-data table is empty.
    final d = await YaadDb.db;
    for (final t in [
      'transactions',
      'people',
      'lending',
      'repayments',
      'aliases',
      'custom_purposes',
    ]) {
      final rows = await d.rawQuery('SELECT COUNT(*) c FROM $t');
      expect((rows.first['c'] as int?) ?? -1, 0, reason: t);
    }
    expect(await YaadDb.people(), isEmpty);
  });

  testWidgets(
      'Delete all my data also resets settings, capture, inbox and '
      'the demo snapshot', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    // Non-default settings, a stale demo openings snapshot, an
    // inbox entry, and money on the books.
    appState.settings = const AppSettings(
      currency: 'USD',
      defaultAccountId: Account.seedCash,
      smsCapture: true,
      notificationCapture: true,
      period: AppSettings.periodAllTime,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'yaad_demo_opening_balances_v1', '{"meezan": 21050.0}');
    await CaptureInbox.instance.add(
      txnId: 'txn-1',
      merchant: 'MEEZAN BANK',
      amount: 500,
      time: DateTime.now(),
      needsReview: false,
    );
    expect(CaptureInbox.instance.entries, isNotEmpty);
    await tester.runAsync(() async {
      await YaadDb.setOpeningBalance(Account.seedMeezan, 21050);
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SettingsScreen())),
    );
    await settleReal(tester);
    await tester.scrollUntilVisible(
      find.text('Delete all my data'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete all my data'));
    await settleReal(tester);
    expect(find.text('Delete everything?'), findsOneWidget);
    await tester.tap(find.text('Delete everything'));
    await settleReal(tester);

    // Native capture: both flags off, queue files cleared.
    bool? flag(String method) {
      final hits = calls.where((c) => c.method == method);
      return hits.isEmpty ? null : hits.last.arguments['enabled'] as bool?;
    }

    expect(flag('setSmsEnabled'), isFalse);
    expect(flag('setNotificationEnabled'), isFalse);
    expect(calls.any((c) => c.method == 'clearCaptureQueues'), isTrue);
    // Settings are full defaults again.
    expect(appState.settings.currency, 'PKR');
    expect(appState.settings.defaultAccountId, Account.seedMeezan);
    expect(appState.settings.smsCapture, isFalse);
    expect(appState.settings.notificationCapture, isFalse);
    expect(appState.settings.period, AppSettings.periodThisMonth);
    // Inbox emptied, in memory and in prefs; demo snapshot dropped.
    expect(CaptureInbox.instance.entries, isEmpty);
    expect(prefs.getString(CaptureInbox.storageKey), isNull);
    expect(prefs.getString('yaad_demo_opening_balances_v1'), isNull);
    expect(find.text('All data deleted.'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await YaadDb.totalBalance(), 0);
    });
  });
}

/// The ffi isolate's replies only land during runAsync windows, so
/// alternate real time with pumps until the async UI settles.
Future<void> settleReal(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
  }
  // Run out route/snackbar animations: a popped dialog is still
  // "found" by finders until its exit animation finishes, and the
  // fake clock only advances when a pump carries a duration.
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}
