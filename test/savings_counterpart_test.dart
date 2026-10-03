import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/account.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/home.dart';
import 'package:yaad/theme.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Build-27: the savings sheet's "other side" came from the DEFAULT
/// account. When the default IS Savings (the user's was), both
/// directions rendered Savings → Savings and a tap recorded a junk
/// self-transfer. The counterpart is now chosen deliberately
/// (default when it isn't Savings, else the first other account,
/// else none), the sheet lets the user pick the moving side, and a
/// self-transfer can no longer be written from the sheet at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    tzdata.initializeTimeZones();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-counterpart-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
    await YaadDb.db;
    // Normalise the accounts table: the shared test DB may carry
    // other files' leftovers. Exactly the three seeds, list order
    // Meezan / Savings / Cash.
    final d = await YaadDb.db;
    await d.delete('accounts');
    for (final a in Account.seeds()) {
      await d.insert('accounts', a.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  });

  tearDown(() {
    appState.settings = const AppSettings();
  });

  /// The ffi isolate's replies only land during runAsync windows, so
  /// alternate real time with pumps until the async UI settles (the
  /// settleRealWork pattern from flow_capture_audit_test).
  Future<void> settleReal(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
    // Run out route/snackbar animations: a popped sheet is still
    // "found" by finders until its exit animation finishes, and the
    // fake clock only advances when a pump carries a duration.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  group('savingsCounterpartId', () {
    Account a(String id) => Account(id: id, name: id, createdAt: 0);
    final all = [a('meezan'), a('savings'), a('cash')];

    test('default is Savings → first non-Savings account', () {
      expect(savingsCounterpartId(all, 'savings'), 'meezan');
    });

    test('default is Meezan → Meezan', () {
      expect(savingsCounterpartId(all, 'meezan'), 'meezan');
    });

    test('default is Cash → Cash (the default wins over list order)',
        () {
      expect(savingsCounterpartId(all, 'cash'), 'cash');
    });

    test('only Savings exists → null', () {
      expect(savingsCounterpartId([a('savings')], 'savings'), isNull);
    });

    test('default id missing → first non-Savings account', () {
      expect(savingsCounterpartId(all, 'long-gone'), 'meezan');
    });

    test('list order decides among non-Savings accounts', () {
      final reordered = [a('savings'), a('cash'), a('meezan')];
      expect(savingsCounterpartId(reordered, 'savings'), 'cash');
    });
  });

  testWidgets(
      'default is Savings: Take back offers Savings → Meezan and '
      'records exactly that move', (tester) async {
    appState.settings =
        const AppSettings(defaultAccountId: Account.seedSavings);
    // Clean slate, then park 1,000 from Meezan so Take back exists.
    await tester.runAsync(() async {
      final d = await YaadDb.db;
      await d.delete('transactions');
      await YaadDb.insertTxn(YaadTransaction(
        amount: 1000,
        dateTime: DateTime.now(),
        direction: TxnDirection.ownTransfer,
        kind: TxnKind.transfer,
        purpose: 'savings',
        source: TxnSource.manual,
        accountId: Account.seedMeezan,
        toAccountId: Account.seedSavings,
      ));
    });

    await tester.pumpWidget(MaterialApp(
      theme: YaadTheme.light('teal'),
      home: const HomeScreen(),
    ));
    await settleReal(tester);

    await tester.scrollUntilVisible(
      find.text('Take back'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Take back'));
    await settleReal(tester);

    // The sheet names the real move — never Savings → Savings.
    expect(find.text('Savings → Meezan'), findsOneWidget);
    expect(find.text('Savings → Savings'), findsNothing);
    // The moving side is a chip choice over the non-Savings accounts.
    expect(find.widgetWithText(ChoiceChip, 'Meezan'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Cash'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '400');
    await tester.pump();
    await tester.tap(find.text('Move'));
    await settleReal(tester);
    expect(find.byType(TextField), findsNothing); // sheet closed

    await tester.runAsync(() async {
      final all = await YaadDb.txns(limit: 50);
      final transfers =
          all.where((t) => t.kind == TxnKind.transfer).toList();
      // The seeded park + this take-back. Nothing else, and no
      // self-transfer anywhere.
      expect(transfers.length, 2);
      expect(transfers.any((t) => t.accountId == t.toAccountId),
          isFalse);
      final back = transfers.firstWhere((t) => t.amount == 400);
      expect(back.accountId, Account.seedSavings);
      expect(back.toAccountId, Account.seedMeezan);
      expect(await YaadDb.savingsTotal(), 600);
    });
  });

  testWidgets(
      'Savings as the only account: moves disabled, reason shown',
      (tester) async {
    appState.settings =
        const AppSettings(defaultAccountId: Account.seedSavings);
    await tester.runAsync(() async {
      final d = await YaadDb.db;
      await d.delete('transactions');
      await d.delete('accounts',
          where: 'id != ?', whereArgs: [Account.seedSavings]);
    });

    await tester.pumpWidget(MaterialApp(
      theme: YaadTheme.light('teal'),
      home: const HomeScreen(),
    ));
    await settleReal(tester);

    await tester.scrollUntilVisible(
      find.text('Add to savings'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // The plain reason is on the card, and the button is dead.
    expect(
        find.text(
            'Add another account to move money in and out of Savings.'),
        findsOneWidget);
    final addButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Add to savings'));
    expect(addButton.onPressed, isNull);
    expect(find.byType(TextField), findsNothing); // no sheet opened

    // Restore the seeds for anything sharing this DB afterwards.
    await tester.runAsync(() async {
      final d = await YaadDb.db;
      for (final a in Account.seeds()) {
        await d.insert('accounts', a.toMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  });
}
