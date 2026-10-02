import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/lending.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/person_detail.dart';

/// Person-detail history entries (user-reported, build-24):
/// entries were dead ends, the header hid the amount, and rows
/// wrapped mid-amount. Tests: edit amount → outstanding updates,
/// delete repayment → remaining reopens (+ linked txn deleted),
/// delete lend with repayments → cascade, edit borrow date →
/// ordering, header headline, row → detail navigation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    tzdata.initializeTimeZones();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('yaad_flow_history');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
    // Pre-open in the REAL zone: opening the DB from inside a
    // testWidgets body (fake-async zone) never completes.
    await YaadDb.db;
  });

  setUp(() async {
    final d = await YaadDb.db;
    await d.delete('transactions');
    await d.delete('repayments');
    await d.delete('lending');
    await d.delete('people');
  });

  Future<LendingRecord> lend(Person p, double amount,
      {bool owedToMe = true, DateTime? date, String reason = ''}) async {
    await YaadDb.insertLending(LendingRecord(
      personId: p.id,
      originalAmount: amount,
      date: date ?? DateTime(2026, 9, 1),
      reason: reason,
      isOwedToMe: owedToMe,
    ));
    final all = await YaadDb.lendingForPerson(p.id);
    return all.firstWhere((r) =>
        r.originalAmount == amount && r.isOwedToMe == owedToMe);
  }

  Future<LendingRecord> fresh(String id) async =>
      (await YaadDb.allLending()).firstWhere((r) => r.id == id);

  Future<double> remaining(LendingRecord r) async =>
      r.originalAmount - await YaadDb.totalRepaid(r.id);

  group('data-layer journeys', () {
    test('editing a lend amount recomputes remaining and status',
        () async {
      final ahmed = await YaadDb.findOrCreatePerson('Ahmed');
      final loan = await lend(ahmed, 1000);
      await YaadDb.addRepayment(
          Repayment(lendingId: loan.id, amount: 400, date: DateTime.now()));
      expect(await remaining(await fresh(loan.id)), 600);
      expect((await fresh(loan.id)).status, LendingStatus.partial);

      // Raise the amount → more outstanding, still partial.
      await YaadDb.updateLending(
          (await fresh(loan.id)).copyWith(originalAmount: 1500));
      await YaadDb.refreshLendingStatus(loan.id);
      expect(await remaining(await fresh(loan.id)), 1100);
      expect((await fresh(loan.id)).status, LendingStatus.partial);

      // Lower it to exactly what was repaid → settled.
      await YaadDb.updateLending(
          (await fresh(loan.id)).copyWith(originalAmount: 400));
      await YaadDb.refreshLendingStatus(loan.id);
      expect(await remaining(await fresh(loan.id)), 0);
      expect((await fresh(loan.id)).status, LendingStatus.settled);

      // Raise it again → reopens to partial (never stuck settled).
      await YaadDb.updateLending(
          (await fresh(loan.id)).copyWith(originalAmount: 900));
      await YaadDb.refreshLendingStatus(loan.id);
      expect((await fresh(loan.id)).status, LendingStatus.partial);
    });

    test('deleting a repayment reopens the loan and deletes its txn',
        () async {
      final sara = await YaadDb.findOrCreatePerson('Sara');
      final loan = await lend(sara, 500);
      // The "Paid back" transaction RepayScreen records, linked.
      final txn = YaadTransaction(
        amount: 500,
        dateTime: DateTime.now(),
        kind: TxnKind.repayIn,
        direction: TxnDirection.incoming,
        rawMerchant: 'Sara',
        personId: sara.id,
        linkedLendingId: loan.id,
      );
      await YaadDb.insertTxn(txn);
      await YaadDb.addRepayment(Repayment(
          lendingId: loan.id,
          amount: 500,
          date: DateTime.now(),
          transactionId: txn.id));
      expect((await fresh(loan.id)).status, LendingStatus.settled);

      // The repayment detail screen's delete path.
      final reps = await YaadDb.repaymentsFor(loan.id);
      if (reps.single.transactionId != null) {
        await YaadDb.deleteTxn(reps.single.transactionId!);
      }
      await YaadDb.deleteRepayment(reps.single.id);

      expect((await fresh(loan.id)).status, LendingStatus.open);
      expect(await remaining(await fresh(loan.id)), 500);
      expect(await YaadDb.txnById(txn.id), isNull,
          reason: 'the linked Paid back transaction must go too');
    });

    test('deleting a lend with repayments cascades, person survives',
        () async {
      final bilal = await YaadDb.findOrCreatePerson('Bilal');
      final loan = await lend(bilal, 1000);
      final txn = YaadTransaction(
        amount: 300,
        dateTime: DateTime.now(),
        kind: TxnKind.repayIn,
        direction: TxnDirection.incoming,
        rawMerchant: 'Bilal',
        personId: bilal.id,
        linkedLendingId: loan.id,
      );
      await YaadDb.insertTxn(txn);
      await YaadDb.addRepayment(Repayment(
          lendingId: loan.id,
          amount: 300,
          date: DateTime.now(),
          transactionId: txn.id));

      await YaadDb.deleteLending(loan.id);

      expect(await YaadDb.allLending(), isEmpty);
      expect(await YaadDb.repaymentsFor(loan.id), isEmpty);
      expect(await YaadDb.txnById(txn.id), isNull,
          reason: 'no orphan Paid back transaction may remain');
      expect(await YaadDb.personById(bilal.id), isNotNull,
          reason: 'the person survives the cascade');
    });

    test('editing a borrow date keeps ordering and figures correct',
        () async {
      final omar = await YaadDb.findOrCreatePerson('Omar');
      final older = await lend(omar, 800,
          owedToMe: false, date: DateTime(2026, 9, 1));
      final newer = await lend(omar, 600,
          owedToMe: false, date: DateTime(2026, 9, 10));
      var records = await YaadDb.lendingForPerson(omar.id);
      expect(records.map((r) => r.id), [newer.id, older.id]);

      // Move the older borrow past the newer one.
      await YaadDb.updateLending(
          older.copyWith(date: DateTime(2026, 9, 20)));
      records = await YaadDb.lendingForPerson(omar.id);
      expect(records.map((r) => r.id), [older.id, newer.id]);
      // Figures untouched by a date edit.
      expect(records.map((r) => r.originalAmount), [800, 600]);
    });
  });

  group('PersonDetailScreen', () {
    Future<void> pumpDetail(WidgetTester tester, Person p) async {
      // A phone-tall surface: at the default 800x600 the header +
      // action grid fill the ListView's build window and the
      // history rows below are never built (lazy ListView).
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      appState.settings = const AppSettings();
      await tester.pumpWidget(
          MaterialApp(home: PersonDetailScreen(person: p)));
      await tester.pumpAndSettle();
    }

    Future<void> pumpManual(WidgetTester tester,
        [int times = 30]) async {
      for (var i = 0; i < times; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('header shows the outstanding amount as the headline',
        (tester) async {
      final ahmed = await YaadDb.findOrCreatePerson('Ahmed');
      await lend(ahmed, 500);
      await pumpDetail(tester, ahmed);
      expect(find.text('Ahmed owes you PKR 500'), findsOneWidget);
    });

    testWidgets('settled header is calm — no figure', (tester) async {
      final ahmed = await YaadDb.findOrCreatePerson('Ahmed');
      final loan = await lend(ahmed, 500);
      await YaadDb.addRepayment(
          Repayment(lendingId: loan.id, amount: 500, date: DateTime.now()));
      await pumpDetail(tester, ahmed);
      expect(find.text('All settled'), findsOneWidget);
      expect(find.textContaining('PKR 500'), findsWidgets); // rows only
    });

    testWidgets('history row opens the entry detail; delete removes it',
        (tester) async {
      final ahmed = await YaadDb.findOrCreatePerson('Ahmed');
      await lend(ahmed, 1000, reason: 'lunch');
      await pumpDetail(tester, ahmed);

      await tester.tap(find.textContaining('I lent'));
      await pumpManual(tester);
      // Detail view: amount, edit + delete actions present.
      expect(find.text('PKR 1,000'), findsWidgets);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await pumpManual(tester);
      expect(find.text('Delete this entry?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await pumpManual(tester);

      expect(await YaadDb.allLending(), isEmpty);
      expect(find.text('All settled'), findsOneWidget);
    });

    testWidgets('deleting a repayment from its detail reopens the balance',
        (tester) async {
      final sara = await YaadDb.findOrCreatePerson('Sara');
      final loan = await lend(sara, 500);
      await YaadDb.addRepayment(
          Repayment(lendingId: loan.id, amount: 500, date: DateTime.now()));
      await pumpDetail(tester, sara);
      expect(find.text('All settled'), findsOneWidget);

      // The repayment is its own history row now.
      await tester.tap(find.text('Paid back'));
      await pumpManual(tester);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      await tester.tap(find.byIcon(Icons.delete_outline));
      await pumpManual(tester);
      expect(find.text('Remove repayment?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await pumpManual(tester);

      expect(find.text('Sara owes you PKR 500'), findsOneWidget);
      expect((await fresh(loan.id)).status, LendingStatus.open);
    });

    testWidgets('editing an amount in the detail updates the header',
        (tester) async {
      final omar = await YaadDb.findOrCreatePerson('Omar');
      await lend(omar, 1000, owedToMe: false);
      await pumpDetail(tester, omar);
      expect(find.text('You owe Omar PKR 1,000'), findsOneWidget);

      await tester.tap(find.textContaining('I borrowed'));
      await pumpManual(tester);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await pumpManual(tester);
      await tester.enterText(find.byType(TextField).first, '1250');
      await tester.tap(find.text('Save'));
      await pumpManual(tester);
      // Back on the ( reloaded ) detail view with the new amount…
      expect(find.text('PKR 1,250'), findsWidgets);
      // …and the person behind it agrees.
      await tester.pageBack();
      await pumpManual(tester);
      expect(find.text('You owe Omar PKR 1,250'), findsOneWidget);
    });
  });
}
