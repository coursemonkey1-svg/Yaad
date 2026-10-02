import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/account.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/accounts.dart';

/// Account balances on the Accounts screen (user feature, v1.5):
/// opening balances at create, editing them later, per-account
/// balances matching YaadDb.accountBalances() on a seeded mix, and
/// the screen total.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('yaad_flow_balances');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
    await YaadDb.db; // create + seed
  });

  setUp(() async {
    final d = await YaadDb.db;
    await d.delete('transactions');
    // Remove user accounts, zero the seeds' openings.
    for (final a in await YaadDb.accounts()) {
      if (a.id != Account.seedMeezan &&
          a.id != Account.seedSavings &&
          a.id != Account.seedCash) {
        await YaadDb.deleteAccount(a.id, reassignTo: Account.seedMeezan);
      }
      await YaadDb.setOpeningBalance(a.id, 0);
    }
  });

  Future<void> txn(double amount, TxnKind kind, String accountId,
          {String? toAccountId,
          TxnStatus status = TxnStatus.confirmed}) =>
      YaadDb.insertTxn(YaadTransaction(
        amount: amount,
        dateTime: DateTime.now(),
        kind: kind,
        rawMerchant: 'SEEDED',
        accountId: accountId,
        toAccountId: toAccountId,
        status: status,
      ));

  group('accountBalances math', () {
    test('seeded mix: opening + every leg, excluded ignored', () async {
      await YaadDb.setOpeningBalance(Account.seedMeezan, 10000);
      await txn(5000, TxnKind.receive, Account.seedMeezan);
      await txn(1500, TxnKind.spend, Account.seedMeezan);
      await txn(2000, TxnKind.transfer, Account.seedMeezan,
          toAccountId: Account.seedSavings);
      await txn(700, TxnKind.lendOut, Account.seedMeezan);
      await txn(300, TxnKind.borrowIn, Account.seedCash);
      await txn(999, TxnKind.spend, Account.seedMeezan,
          status: TxnStatus.excluded); // never counts

      final balances = await YaadDb.accountBalances();
      expect(balances[Account.seedMeezan], 10800);
      expect(balances[Account.seedSavings], 2000);
      expect(balances[Account.seedCash], 300);
      expect(await YaadDb.totalBalance(), 13100);
    });

    test('opening balance set at create shows in the balance',
        () async {
      final jar = await YaadDb.insertAccount('Jar', openingBalance: 250);
      expect(jar.openingBalance, 250);
      expect((await YaadDb.accountBalances())[jar.id], 250);
    });

    test('editing the opening balance moves the total', () async {
      final jar = await YaadDb.insertAccount('Jar', openingBalance: 250);
      final before = await YaadDb.totalBalance();
      await YaadDb.setOpeningBalance(jar.id, 900);
      expect((await YaadDb.accountBalances())[jar.id], 900);
      expect(await YaadDb.totalBalance(), before + 650);
      // Negative openings are legal (overdrawn account).
      await YaadDb.setOpeningBalance(jar.id, -100);
      expect((await YaadDb.accountBalances())[jar.id], -100);
    });
  });

  group('AccountsScreen', () {
    Future<void> pumpAccounts(WidgetTester tester) async {
      appState.settings = const AppSettings();
      await tester.pumpWidget(
          const MaterialApp(home: AccountsScreen()));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('rows show balances and the header shows the total',
        (tester) async {
      await YaadDb.setOpeningBalance(Account.seedMeezan, 10000);
      await YaadDb.setOpeningBalance(Account.seedCash, 200);
      await txn(1500, TxnKind.spend, Account.seedMeezan);
      await pumpAccounts(tester);
      expect(find.text('PKR 8,500'), findsOneWidget); // Meezan row
      expect(find.text('PKR 200'), findsOneWidget); // Cash row
      expect(find.text('Total balance'), findsOneWidget);
      expect(find.text('PKR 8,700'), findsOneWidget); // header total
    });

    testWidgets('create with an opening balance shows it immediately',
        (tester) async {
      await pumpAccounts(tester);
      await tester.tap(find.text('Add account'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Trip fund');
      await tester.enterText(find.byType(TextField).last, '2500');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final created = (await YaadDb.accounts())
          .firstWhere((a) => a.name == 'Trip fund');
      expect(created.openingBalance, 2500);
      // The new row's balance AND the header total both show it.
      expect(find.text('PKR 2,500'), findsNWidgets(2));
    });

    testWidgets('editing the opening balance updates row and total',
        (tester) async {
      await YaadDb.setOpeningBalance(Account.seedMeezan, 1000);
      await pumpAccounts(tester);
      expect(find.text('PKR 1,000'), findsWidgets);

      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();
      // Opening field is prefilled with the current opening.
      final openingField = tester.widget<TextField>(
          find.byType(TextField).last);
      expect(openingField.controller!.text, '1000');
      await tester.enterText(find.byType(TextField).last, '4000');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final meezan = await YaadDb.accountById(Account.seedMeezan);
      expect(meezan!.openingBalance, 4000);
      expect(find.text('PKR 4,000'), findsWidgets);
    });

    testWidgets('garbage opening balance is refused, nothing saved',
        (tester) async {
      await pumpAccounts(tester);
      final before = (await YaadDb.accounts()).length;
      await tester.tap(find.text('Add account'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Jar');
      await tester.enterText(find.byType(TextField).last, '12-34');
      await tester.tap(find.text('Save'));
      // "12-34" is not a number → refused gracefully (formatter lets
      // it through as text; the parse is the guard).
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect((await YaadDb.accounts()).length, before);
    });
  });
}
