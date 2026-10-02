import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
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

/// Regression (build-26): on a real phone, a detailed TxnRow for a
/// savings move with a wide amount — "PKR 1,00,000" — squeezed the
/// card body until the "Cash → Savings" chip overflowed the card
/// (yellow RIGHT OVERFLOWED stripes in the user's screenshots).
/// The chip label now sits in a Flexible with ellipsis, so the chip
/// shrinks instead of bursting. This pumps exactly that row at a
/// 360dp phone width and asserts no framework exception is raised.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-txnrow-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
    // Open the real DB so the seeded accounts exist: the row looks
    // up the Cash / Savings display names by id.
    await YaadDb.db;
  });

  setUp(() {
    appState.settings = const AppSettings();
  });

  testWidgets(
      'transfer row with a wide amount does not overflow at 360dp',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final txn = YaadTransaction(
      amount: 100000,
      dateTime: DateTime(2026, 10, 3, 2, 34),
      direction: TxnDirection.ownTransfer,
      kind: TxnKind.transfer,
      purpose: 'savings',
      accountId: 'cash',
      toAccountId: 'savings',
    );
    // Seed the transaction itself, as on the user's phone.
    await tester.runAsync(() => YaadDb.insertTxn(txn));

    await tester.pumpWidget(MaterialApp(
      theme: YaadTheme.light('teal'),
      home: Scaffold(body: TxnRow(txn: txn)),
    ));
    // The row's name lookups hit real sqlite; the ffi isolate's
    // replies only land during runAsync windows, so alternate real
    // time with pumps (the settleRealWork pattern from
    // flow_capture_audit_test) until the FutureBuilder has data.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    // The loaded state rendered: title, the from→to chip, the amount.
    expect(find.text('Moved to Savings'), findsOneWidget);
    expect(find.text('Cash → Savings'), findsOneWidget);
    expect(find.text('PKR 1,00,000'), findsOneWidget);
    // …and nothing overflowed while it did.
    expect(tester.takeException(), isNull);
  });
}
