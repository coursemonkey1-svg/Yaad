import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/account.dart';
import 'package:yaad/models/lending.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/confirm.dart';
import 'package:yaad/screens/home.dart';
import 'package:yaad/screens/lending_detail.dart';
import 'package:yaad/screens/person_detail.dart';
import 'package:yaad/screens/repay.dart';
import 'package:yaad/screens/transaction_view.dart';
import 'package:yaad/theme.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Wave-2 widget regressions for the build-28 audit: flows driven
/// through the real screens, in the user's real states (Savings as
/// an account with its own opening, transfers edited after the fact,
/// repayments deleted from Activity).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    tzdata.initializeTimeZones();
    // ConfirmScreen constructs an AudioRecorder whose (unawaited)
    // platform 'create' call throws MissingPluginException in tests;
    // the error lands asynchronously and fails the test. Mock the
    // record channel (same pattern as flow_capture_audit_test).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async => null,
    );
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-audit-w2-widget');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  setUp(() async {
    await YaadDb.wipeAll();
    appState.settings = const AppSettings();
  });

  tearDown(() {
    appState.settings = const AppSettings();
  });

  /// The ffi isolate's replies only land during runAsync windows, so
  /// alternate real time with pumps until the async UI settles.
  Future<void> settleReal(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  testWidgets('RepayScreen links the repayment to its transaction',
      (tester) async {
    late Person ahmed;
    late LendingRecord loan;
    await tester.runAsync(() async {
      ahmed = Person(name: 'Ahmed');
      await YaadDb.insertPerson(ahmed);
      loan = LendingRecord(
          personId: ahmed.id,
          originalAmount: 500,
          currency: 'PKR',
          date: DateTime.now(),
          reason: '',
          isOwedToMe: true);
      await YaadDb.insertLending(loan);
    });

    await tester.pumpWidget(MaterialApp(
        theme: YaadTheme.light('teal'),
        home: RepayScreen(person: ahmed, theyPaidMe: true)));
    await settleReal(tester);
    await tester.enterText(find.byType(TextField), '200');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'They paid me'));
    await settleReal(tester);

    await tester.runAsync(() async {
      final reps = await YaadDb.repaymentsFor(loan.id);
      expect(reps.length, 1);
      final txns = await YaadDb.txns(personId: ahmed.id);
      final repayTxns =
          txns.where((t) => t.kind == TxnKind.repayIn).toList();
      expect(repayTxns.length, 1);
      // The link the delete/edit cascades follow:
      expect(reps.single.transactionId, repayTxns.single.id);
    });
  });

  testWidgets('editing a transfer keeps it a transfer — kind, '
      'destination and purpose all survive the save', (tester) async {
    late YaadTransaction move;
    await tester.runAsync(() async {
      move = YaadTransaction(
        amount: 2000,
        dateTime: DateTime.now(),
        direction: TxnDirection.ownTransfer,
        kind: TxnKind.transfer,
        purpose: 'savings',
        rawMerchant: '',
        source: TxnSource.manual,
        accountId: Account.seedMeezan,
        toAccountId: Account.seedSavings,
      );
      await YaadDb.insertTxn(move);
    });

    await tester.pumpWidget(MaterialApp(
        theme: YaadTheme.light('teal'),
        home: TransactionViewScreen(txn: move)));
    await settleReal(tester);
    await tester.tap(find.byKey(const Key('txnEditButton')));
    await settleReal(tester);
    expect(find.byType(ConfirmScreen), findsOneWidget);
    // Locked kind: no Spend/Receive selector is offered for a move.
    expect(find.byType(SegmentedButton<TxnKind>), findsNothing);

    // Change only the amount.
    await tester.enterText(find.byType(TextField).first, '2500');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settleReal(tester);

    await tester.runAsync(() async {
      final stored = await YaadDb.txnById(move.id);
      expect(stored, isNotNull);
      expect(stored!.kind, TxnKind.transfer,
          reason: 'an edit must never re-bucket a move as spending');
      expect(stored.direction, TxnDirection.ownTransfer);
      expect(stored.toAccountId, Account.seedSavings);
      expect(stored.purpose, 'savings');
      expect(stored.amount, 2500);
      final balances = await YaadDb.accountBalances();
      expect(balances[Account.seedMeezan], -2500);
      expect(balances[Account.seedSavings], 2500);
      expect(await YaadDb.savingsTotal(), 2500);
    });
  });

  testWidgets('a lending row offers NO Edit in the view screen',
      (tester) async {
    final repay = YaadTransaction(
      amount: 8000,
      dateTime: DateTime.now(),
      kind: TxnKind.repayIn,
      direction: TxnDirection.incoming,
      rawMerchant: 'Ahmed Raza',
      purpose: 'uncategorized',
      source: TxnSource.manual,
      accountId: Account.seedMeezan,
    );
    await tester.pumpWidget(MaterialApp(
        theme: YaadTheme.light('teal'),
        home: TransactionViewScreen(txn: repay)));
    await settleReal(tester);
    expect(find.byKey(const Key('txnEditButton')), findsNothing);
    expect(find.byKey(const Key('txnDeleteButton')), findsOneWidget);
  });

  testWidgets('deleting a "Paid back" row from Activity un-records '
      'the repayment in Udhaar', (tester) async {
    late YaadTransaction repayTxn;
    late LendingRecord loan;
    await tester.runAsync(() async {
      final p = Person(name: 'Ahmed Raza');
      await YaadDb.insertPerson(p);
      loan = LendingRecord(
          personId: p.id,
          originalAmount: 20000,
          currency: 'PKR',
          date: DateTime(2026, 9, 1),
          reason: 'Bike repair',
          isOwedToMe: true);
      await YaadDb.insertLending(loan);
      // UI-shaped pair: repayment linkless, txn carries the link.
      await YaadDb.addRepayment(Repayment(
          lendingId: loan.id, amount: 8000, date: DateTime(2026, 9, 9)));
      repayTxn = YaadTransaction(
        amount: 8000,
        dateTime: DateTime(2026, 9, 9),
        kind: TxnKind.repayIn,
        direction: TxnDirection.incoming,
        rawMerchant: 'Ahmed Raza',
        purpose: 'uncategorized',
        source: TxnSource.manual,
        accountId: Account.seedMeezan,
        personId: p.id,
        linkedLendingId: loan.id,
      );
      await YaadDb.insertTxn(repayTxn);
      expect(await YaadDb.totalRepaid(loan.id), 8000);
    });

    await tester.pumpWidget(MaterialApp(
        theme: YaadTheme.light('teal'),
        home: TransactionViewScreen(txn: repayTxn)));
    await settleReal(tester);
    await tester.tap(find.byKey(const Key('txnDeleteButton')));
    await settleReal(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await settleReal(tester);

    await tester.runAsync(() async {
      expect(await YaadDb.txnById(repayTxn.id), isNull);
      expect(await YaadDb.repaymentsFor(loan.id), isEmpty,
          reason: 'Udhaar must stop claiming the money was repaid');
      expect(await YaadDb.totalRepaid(loan.id), 0);
    });
  });

  testWidgets('Home savings card shows the Savings ACCOUNT balance '
      '(opening counts) and offers Take back', (tester) async {
    await tester.runAsync(() async {
      await YaadDb.setOpeningBalance(Account.seedSavings, 10000);
    });
    await tester.pumpWidget(MaterialApp(
        theme: YaadTheme.light('teal'), home: const HomeScreen()));
    await settleReal(tester);
    await tester.scrollUntilVisible(
      find.text('Take back'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // With transfers-only math this card read PKR 0 and hid the
    // button entirely, while Accounts showed 10,000.
    expect(find.text('Take back'), findsOneWidget);
    expect(find.text('PKR 10,000'), findsAtLeastNWidgets(1));
  });

  testWidgets('savings sheet refuses a move larger than the '
      'from-account balance, with the reason on screen',
      (tester) async {
    await tester.runAsync(() async {
      await YaadDb.setOpeningBalance(Account.seedMeezan, 1000);
    });
    await tester.pumpWidget(MaterialApp(
        theme: YaadTheme.light('teal'), home: const HomeScreen()));
    await settleReal(tester);
    await tester.scrollUntilVisible(
      find.text('Add to savings'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Add to savings'));
    await settleReal(tester);

    await tester.enterText(find.byType(TextField), '5000');
    await tester.pump();
    expect(find.text('Not enough in Meezan'), findsOneWidget);
    final moveBtn =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Move'));
    expect(moveBtn.onPressed, isNull);

    await tester.enterText(find.byType(TextField), '500');
    await tester.pump();
    expect(find.text('Not enough in Meezan'), findsNothing);
    final moveBtn2 =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Move'));
    expect(moveBtn2.onPressed, isNotNull);
  });

  testWidgets('settle-up is offered when lend and borrow cancel out '
      'but both records are still open', (tester) async {
    late Person p;
    await tester.runAsync(() async {
      p = Person(name: 'Bilal');
      await YaadDb.insertPerson(p);
      await YaadDb.insertLending(LendingRecord(
          personId: p.id,
          originalAmount: 5000,
          currency: 'PKR',
          date: DateTime.now(),
          reason: 'lent',
          isOwedToMe: true));
      await YaadDb.insertLending(LendingRecord(
          personId: p.id,
          originalAmount: 5000,
          currency: 'PKR',
          date: DateTime.now(),
          reason: 'borrowed',
          isOwedToMe: false));
    });
    await tester.pumpWidget(MaterialApp(
        theme: YaadTheme.light('teal'),
        home: PersonDetailScreen(person: p)));
    await settleReal(tester);
    expect(find.text('Settle up'), findsOneWidget);
  });

  testWidgets('LendingDetail Repay targets the record person, not '
      'the person the screen was opened with', (tester) async {
    late Person a, b;
    late LendingRecord record;
    await tester.runAsync(() async {
      a = Person(name: 'Original Person');
      b = Person(name: 'Moved Person');
      await YaadDb.insertPerson(a);
      await YaadDb.insertPerson(b);
      // The post-edit state: the record now belongs to B, while the
      // screen was opened from A's page.
      record = LendingRecord(
          personId: b.id,
          originalAmount: 1000,
          currency: 'PKR',
          date: DateTime.now(),
          reason: '',
          isOwedToMe: true);
      await YaadDb.insertLending(record);
    });
    await tester.pumpWidget(MaterialApp(
        theme: YaadTheme.light('teal'),
        home: LendingDetailScreen(person: a, lendingId: record.id)));
    await settleReal(tester);
    await tester.scrollUntilVisible(
      find.text('Repay'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Repay'));
    await settleReal(tester);
    final screen = tester.widget<RepayScreen>(find.byType(RepayScreen));
    expect(screen.person.id, b.id);
  });
}
