import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/lending.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/repay.dart';

/// Udhaar journeys (audit area 3) + month-boundary math (area 1):
/// lend → partial repay → settle, delete-repayment recompute,
/// a person on both sides, and the RepayScreen guards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('yaad_flow_udhaar');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
  });

  setUp(() async {
    final d = await YaadDb.db;
    await d.delete('transactions');
    await d.delete('repayments');
    await d.delete('lending');
    await d.delete('people');
  });

  Future<Person> person(String name) => YaadDb.findOrCreatePerson(name);

  Future<LendingRecord> lend(Person p, double amount,
          {bool owedToMe = true}) async =>
      YaadDb.insertLending(LendingRecord(
        personId: p.id,
        originalAmount: amount,
        date: DateTime(2026, 9, 1),
        isOwedToMe: owedToMe,
      )).then((_) async {
        final all = await YaadDb.lendingForPerson(p.id);
        return all.firstWhere((r) => r.originalAmount == amount && r.isOwedToMe == owedToMe);
      });

  Future<LendingRecord?> record(String id) async {
    for (final r in await YaadDb.allLending()) {
      if (r.id == id) return r;
    }
    return null;
  }

  group('lend → partial repay → settle journey', () {
    test('status and remaining track every step', () async {
      final ahmed = await person('Ahmed');
      final loan = await lend(ahmed, 1000);
      expect((await record(loan.id))!.status, LendingStatus.open);

      var remaining = await YaadDb.addRepayment(
          Repayment(lendingId: loan.id, amount: 400, date: DateTime.now()));
      expect(remaining, 600);
      expect((await record(loan.id))!.status, LendingStatus.partial);
      expect(await YaadDb.totalRepaid(loan.id), 400);

      remaining = await YaadDb.addRepayment(
          Repayment(lendingId: loan.id, amount: 600, date: DateTime.now()));
      expect(remaining, 0);
      expect((await record(loan.id))!.status, LendingStatus.settled);
    });

    test('deleting a repayment recomputes the status', () async {
      final sara = await person('Sara');
      final loan = await lend(sara, 1000);
      await YaadDb.addRepayment(
          Repayment(lendingId: loan.id, amount: 400, date: DateTime.now()));
      await YaadDb.addRepayment(
          Repayment(lendingId: loan.id, amount: 600, date: DateTime.now()));
      expect((await record(loan.id))!.status, LendingStatus.settled);

      final reps = await YaadDb.repaymentsFor(loan.id);
      expect(reps.length, 2);
      // Remove the final repayment → back to partial, 600 remaining.
      await YaadDb.deleteRepayment(reps.last.id);
      expect((await record(loan.id))!.status, LendingStatus.partial);
      expect(await YaadDb.totalRepaid(loan.id), 400);

      // Remove the first repayment too → fully open again.
      await YaadDb.deleteRepayment(reps.first.id);
      expect((await record(loan.id))!.status, LendingStatus.open);
      expect(await YaadDb.totalRepaid(loan.id), 0);
    });

    test('borrow side is symmetric', () async {
      final bilal = await person('Bilal');
      final loan = await lend(bilal, 800, owedToMe: false);
      final remaining = await YaadDb.addRepayment(
          Repayment(lendingId: loan.id, amount: 300, date: DateTime.now()));
      expect(remaining, 500);
      expect((await record(loan.id))!.status, LendingStatus.partial);
      expect((await record(loan.id))!.isOwedToMe, isFalse);
    });

    test('a person with both lent and borrowed records nets correctly',
        () async {
      final omar = await person('Omar');
      final lent = await lend(omar, 2000);
      final borrowed = await lend(omar, 500, owedToMe: false);
      await YaadDb.addRepayment(
          Repayment(lendingId: lent.id, amount: 500, date: DateTime.now()));
      await YaadDb.addRepayment(Repayment(
          lendingId: borrowed.id, amount: 100, date: DateTime.now()));

      double owedToMe = 0, iOwe = 0;
      for (final r in await YaadDb.lendingForPerson(omar.id)) {
        if (r.status == LendingStatus.settled) continue;
        final rem = r.originalAmount - await YaadDb.totalRepaid(r.id);
        if (rem <= 0.005) continue;
        if (r.isOwedToMe) {
          owedToMe += rem;
        } else {
          iOwe += rem;
        }
      }
      expect(owedToMe, 1500);
      expect(iOwe, 400);
      expect(owedToMe - iOwe, 1100); // the net line both screens show
    });

    test('lending never counts as spending or receiving', () async {
      final p = await person('Noor');
      final now = DateTime.now();
      final from = DateTime(now.year, now.month, 1).millisecondsSinceEpoch;
      final to = now.millisecondsSinceEpoch;
      await YaadDb.insertTxn(YaadTransaction(
        amount: 5000,
        dateTime: now,
        kind: TxnKind.lendOut,
        direction: TxnDirection.out,
        rawMerchant: 'Noor',
        personId: p.id,
      ));
      await YaadDb.insertTxn(YaadTransaction(
        amount: 3000,
        dateTime: now,
        kind: TxnKind.borrowIn,
        direction: TxnDirection.incoming,
        rawMerchant: 'Noor',
        personId: p.id,
      ));
      await YaadDb.insertTxn(YaadTransaction(
        amount: 1000,
        dateTime: now,
        kind: TxnKind.repayIn,
        direction: TxnDirection.incoming,
        rawMerchant: 'Noor',
        personId: p.id,
      ));
      expect(await YaadDb.sumSpent(from, to), 0);
      expect(await YaadDb.sumReceived(from, to), 0);
    });
  });

  group('month boundaries', () {
    test('23:59 last day counts, 00:00 first day of next month does not',
        () async {
      final from = DateTime(2026, 9, 1).millisecondsSinceEpoch;
      final to = DateTime(2026, 9, 30, 23, 59, 59, 999)
          .millisecondsSinceEpoch;
      Future<void> spendAt(int ms, double amount) =>
          YaadDb.insertTxn(YaadTransaction(
            amount: amount,
            dateTime: DateTime.fromMillisecondsSinceEpoch(ms),
            kind: TxnKind.spend,
            rawMerchant: 'BOUNDARY',
          ));
      await spendAt(DateTime(2026, 8, 31, 23, 59, 59, 999)
          .millisecondsSinceEpoch, 111); // just before — out
      await spendAt(from, 222); // first instant — in
      await spendAt(to, 333); // last instant — in
      await spendAt(DateTime(2026, 10, 1).millisecondsSinceEpoch,
          444); // next month — out
      expect(await YaadDb.sumSpent(from, to), 555);

      // An excluded row inside the window never counts.
      await YaadDb.insertTxn(YaadTransaction(
        amount: 9999,
        dateTime: DateTime(2026, 9, 15),
        kind: TxnKind.spend,
        status: TxnStatus.excluded,
        rawMerchant: 'EXCLUDED',
      ));
      expect(await YaadDb.sumSpent(from, to), 555);
    });
  });

  group('RepayScreen guards', () {
    Future<void> pumpRepay(WidgetTester tester, Widget screen) async {
      appState.settings = const AppSettings();
      await tester.pumpWidget(MaterialApp(home: screen));
      // The screen loads from the DB behind a spinner — manual pumps,
      // never pumpAndSettle while it is up.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byType(TextField).evaluate().isNotEmpty &&
            find.text('500').evaluate().isEmpty) break;
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('over-repayment is blocked with an explanation',
        (tester) async {
      final ahmed = await person('Ahmed');
      final loan = await lend(ahmed, 500);
      await pumpRepay(
          tester, RepayScreen(person: ahmed, theyPaidMe: true));

      // The amount field is prefilled with the full remaining 500.
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '600');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'They paid me'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.textContaining("more than what's left"), findsOneWidget);
      // Nothing was recorded and the screen is still open.
      expect(await YaadDb.totalRepaid(loan.id), 0);
      expect(find.byType(RepayScreen), findsOneWidget);

      // A valid partial repayment goes through and closes the screen.
      await tester.enterText(find.byType(TextField), '200');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'They paid me'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(await YaadDb.totalRepaid(loan.id), 200);
      expect((await record(loan.id))!.status, LendingStatus.partial);
      // …and a "Paid back" transaction was recorded for Activity.
      final txns = await YaadDb.txns(personId: ahmed.id);
      expect(txns.where((t) => t.kind == TxnKind.repayIn).length, 1);
      expect(txns.first.linkedLendingId, loan.id);
    });

    testWidgets('a settled preselected record does not crash the screen',
        (tester) async {
      final sara = await person('Sara');
      final settled = await lend(sara, 700);
      await YaadDb.addRepayment(Repayment(
          lendingId: settled.id, amount: 700, date: DateTime.now()));
      expect((await record(settled.id))!.status, LendingStatus.settled);
      final open = await lend(sara, 900);

      await pumpRepay(
          tester,
          RepayScreen(
              person: sara, theyPaidMe: true, preselected: settled));
      expect(tester.takeException(), isNull);
      // It fell back to the open record: amount prefilled with 900.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '900');
      expect(open.originalAmount, 900);
    });

    testWidgets('with nothing open, save is disabled (no orphan txn)',
        (tester) async {
      final omar = await person('Omar');
      await pumpRepay(
          tester, RepayScreen(person: omar, theyPaidMe: true));
      expect(find.text('No open loans — nothing to collect.'),
          findsOneWidget);
      final button =
          tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect((await YaadDb.txns(personId: omar.id)), isEmpty);
    });
  });
}
