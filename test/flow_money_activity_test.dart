import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/account.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/timeline.dart';
import 'package:yaad/widgets/filter_sheet.dart';

/// Activity search (audit area 2): search matches what the user sees
/// (their own shop names, people, purpose labels), "%" stays a
/// literal character, and the filter sheet can create purposes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    tzdata.initializeTimeZones();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('yaad_flow_activity');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
  });

  setUp(() async {
    final d = await YaadDb.db;
    await d.delete('transactions');
    await d.delete('people');
    await d.delete('aliases');
    await d.delete('custom_purposes');
    await YaadDb.refreshCustomPurposeRegistry();
  });

  Future<void> pumpTimeline(WidgetTester tester) async {
    // All time: these search tests seed fixed past dates; the period
    // filter itself is covered by flow_money_period_test.
    appState.settings = const AppSettings(period: 'allTime');
    await tester.pumpWidget(const MaterialApp(home: TimelineScreen()));
    // FutureBuilder + per-row futures: manual pumps, no pumpAndSettle
    // (the loading spinner never settles).
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> search(WidgetTester tester, String q) async {
    await tester.enterText(find.byType(TextField), q);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('search finds rows by alias, person and purpose label',
      (tester) async {
    final ahmed = await YaadDb.findOrCreatePerson('Ahmed');
    await YaadDb.upsertAlias('XYZ BANK FEE', 'Bank charges');
    await YaadDb.insertTxn(YaadTransaction(
      amount: 250,
      dateTime: DateTime(2026, 9, 10),
      kind: TxnKind.spend,
      rawMerchant: 'XYZ BANK FEE',
      purpose: 'bills',
    ));
    await YaadDb.insertTxn(YaadTransaction(
      amount: 1500,
      dateTime: DateTime(2026, 9, 11),
      kind: TxnKind.lendOut,
      direction: TxnDirection.out,
      rawMerchant: 'CASH WITHDRAWAL',
      purpose: 'uncategorized',
      personId: ahmed.id,
    ));
    await pumpTimeline(tester);
    expect(find.text('Bank charges'), findsWidgets);
    expect(find.text('CASH WITHDRAWAL'), findsWidgets);

    // By the user's own name for the shop (alias), not the bank text.
    await search(tester, 'bank charges');
    expect(find.text('Bank charges'), findsWidgets);
    expect(find.text('CASH WITHDRAWAL'), findsNothing);

    // By person name — the raw merchant says nothing about Ahmed.
    await search(tester, 'ahmed');
    expect(find.text('CASH WITHDRAWAL'), findsWidgets);
    expect(find.text('Bank charges'), findsNothing);

    // By purpose label.
    await search(tester, 'bills');
    expect(find.text('Bank charges'), findsWidgets);
    expect(find.text('CASH WITHDRAWAL'), findsNothing);
  });

  testWidgets('"%" is a literal character, not a match-everything wildcard',
      (tester) async {
    await YaadDb.insertTxn(YaadTransaction(
      amount: 100,
      dateTime: DateTime(2026, 9, 10),
      kind: TxnKind.spend,
      rawMerchant: 'SHOP 50% SALE',
      purpose: 'shopping',
    ));
    await YaadDb.insertTxn(YaadTransaction(
      amount: 200,
      dateTime: DateTime(2026, 9, 11),
      kind: TxnKind.spend,
      rawMerchant: 'PLAIN SHOP',
      purpose: 'shopping',
    ));
    await pumpTimeline(tester);
    await search(tester, '%');
    // Only the row that literally contains % matches.
    expect(find.text('SHOP 50% SALE'), findsWidgets);
    expect(find.text('PLAIN SHOP'), findsNothing);
  });

  testWidgets('garbage query gets the no-match empty state', (tester) async {
    await YaadDb.insertTxn(YaadTransaction(
      amount: 100,
      dateTime: DateTime(2026, 9, 10),
      kind: TxnKind.spend,
      rawMerchant: 'SOME SHOP',
      purpose: 'food',
    ));
    await pumpTimeline(tester);
    await search(tester, 'zzzzqqqq!!!!');
    expect(find.text('No transactions match your filters.'), findsOneWidget);
    expect(find.text('Clear all'), findsOneWidget);
  });

  testWidgets('filter sheet creates a custom purpose and selects it',
      (tester) async {
    FilterSelection? last;
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
            accounts: const [],
            onChanged: (sel) => last = sel,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('New purpose'), findsOneWidget);
    await tester.tap(find.text('New purpose'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Zakat');
    await tester.pump(); // let the dialog enable its Add button
    await tester.tap(find.text('Add'));
    // Settle, don't poll the raw table: the row becomes visible
    // before the sheet's create chain (setState + emit) finishes,
    // so polling the DB races ahead of the UI state.
    await tester.pumpAndSettle();

    // Created in the DB, shown as a chip, and already selected.
    final customs = await YaadDb.customPurposes();
    expect(customs.map((c) => c.label), ['Zakat']);
    expect(find.text('Zakat'), findsOneWidget);
    expect(last, isNotNull);
    expect(last!.purposes, {customs.first.id});

    // Creating the same purpose again is refused with the exists note.
    await tester.tap(find.text('New purpose'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Zakat');
    await tester.pump(); // let the dialog enable its Add button
    await tester.tap(find.text('Add'));
    var existsShown = false;
    for (var i = 0; i < 240 && !existsShown; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await YaadDb.customPurposes(); // yield to real async work
      existsShown =
          find.text('That purpose already exists').evaluate().isNotEmpty;
    }
    expect(existsShown, isTrue);
    expect((await YaadDb.customPurposes()).length, 1);
  });

  testWidgets('filter sheet creates an account and selects it',
      (tester) async {
    FilterSelection? last;
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

    await tester.tap(find.text('Add account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Wallet');
    await tester.tap(find.text('Save'));
    // Settle so the dialog (and its 'Wallet' field text, which
    // find.text also matches) is gone before asserting on the chip.
    await tester.pumpAndSettle();
    final accounts = await YaadDb.accounts();
    final wallet = accounts.firstWhere((a) => a.name == 'Wallet');
    expect(find.text('Wallet'), findsOneWidget);
    expect(last, isNotNull);
    expect(last!.accountIds, {wallet.id});

    // Same name again (any case) → the Accounts screen's refusal.
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'wallet');
    await tester.tap(find.text('Save'));
    // The refusal snackbar queues behind the "added" one — pump
    // until it appears rather than settling past it.
    var existsShown = false;
    for (var i = 0; i < 240 && !existsShown; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await YaadDb.accounts(); // yield to real async work
      existsShown =
          find.text('That account already exists').evaluate().isNotEmpty;
    }
    expect(existsShown, isTrue);
    expect(
        (await YaadDb.accounts())
            .where((a) => a.name.toLowerCase() == 'wallet')
            .length,
        1);
  });
}
