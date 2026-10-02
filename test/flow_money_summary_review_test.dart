import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/review.dart';
import 'package:yaad/screens/summary.dart';

/// Summary + Review screens (audit areas 4 & 5): breakdown adds up
/// to the total, lending/excluded rows never leak in, empty period
/// state, review has no fake progress bar.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    tzdata.initializeTimeZones();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('yaad_flow_summary');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
  });

  setUp(() async {
    final d = await YaadDb.db;
    await d.delete('transactions');
    await d.delete('custom_purposes');
    await YaadDb.refreshCustomPurposeRegistry();
  });

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    appState.settings = const AppSettings();
    await tester.pumpWidget(MaterialApp(home: screen));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('SummaryScreen', () {
    testWidgets('purpose breakdown adds up to the month total',
        (tester) async {
      final now = DateTime.now();
      Future<void> add(double amount, TxnKind kind, String purpose,
              {TxnStatus status = TxnStatus.confirmed}) =>
          YaadDb.insertTxn(YaadTransaction(
            amount: amount,
            dateTime: now,
            kind: kind,
            purpose: purpose,
            status: status,
            rawMerchant: 'S $purpose',
          ));
      await add(1000, TxnKind.spend, 'groceries');
      await add(500, TxnKind.spend, 'food');
      await add(250, TxnKind.spend, 'food');
      await add(777, TxnKind.lendOut, 'uncategorized'); // never spending
      await add(9999, TxnKind.spend, 'bills',
          status: TxnStatus.excluded); // excluded never counts
      await add(4000, TxnKind.receive, 'salary'); // not spending either

      await pumpScreen(tester, const SummaryScreen());
      // Total = 1000 + 500 + 250 only.
      expect(find.text('PKR 1,750'), findsOneWidget);
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Food'), findsOneWidget);
      expect(find.text('PKR 750'), findsOneWidget); // 500 + 250 combined
    });

    testWidgets('empty month shows the designed empty state',
        (tester) async {
      await pumpScreen(tester, const SummaryScreen());
      expect(find.text('No spending in this period.'), findsOneWidget);
      expect(find.textContaining('Try another week or month'),
          findsOneWidget);
    });

    testWidgets('a very long custom purpose label cannot overflow',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cp = await YaadDb.insertCustomPurpose(
          'Eid shopping for all the cousins and their families');
      await YaadDb.insertTxn(YaadTransaction(
        amount: 123456,
        dateTime: DateTime.now(),
        kind: TxnKind.spend,
        purpose: cp.id,
        rawMerchant: 'LONG LABEL SHOP',
      ));
      await pumpScreen(tester, const SummaryScreen());
      expect(tester.takeException(), isNull);
      expect(find.text('PKR 1,23,456'), findsWidgets);
    });
  });

  group('ReviewScreen', () {
    testWidgets('lists needs-review rows, with no fake progress bar',
        (tester) async {
      await YaadDb.insertTxn(YaadTransaction(
        amount: 800,
        dateTime: DateTime.now(),
        kind: TxnKind.spend,
        rawMerchant: 'MYSTERY SHOP',
        status: TxnStatus.needsReview,
      ));
      await YaadDb.insertTxn(YaadTransaction(
        amount: 100,
        dateTime: DateTime.now(),
        kind: TxnKind.spend,
        rawMerchant: 'CONFIRMED SHOP',
        status: TxnStatus.confirmed,
      ));
      await pumpScreen(tester, const ReviewScreen());
      expect(find.text('MYSTERY SHOP'), findsWidgets);
      expect(find.text('CONFIRMED SHOP'), findsNothing);
      expect(find.textContaining('1 to review'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('empty review shows the all-caught-up state',
        (tester) async {
      await pumpScreen(tester, const ReviewScreen());
      expect(find.text('All caught up!'), findsOneWidget);
    });
  });
}
