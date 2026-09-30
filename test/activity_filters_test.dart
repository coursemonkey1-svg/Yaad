import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/models/custom_purpose.dart';
import 'package:yaad/models/purposes.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/widgets/filter_sheet.dart';
import 'package:yaad/widgets/purpose_grid.dart';

/// Activity multi-select filters + custom purposes. Runs on the real
/// SQLite engine via ffi, in its own databases directory so parallel
/// test files never share the yaad.db file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('yaad_activity_test');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
    // Custom-purpose registry starts empty in tests.
    registerCustomPurposes({});
  });

  setUp(() async {
    final db = await YaadDb.db;
    await db.delete('transactions');
    await db.delete('custom_purposes');
    await YaadDb.refreshCustomPurposeRegistry();
  });

  int _id = 0;

  Future<void> insertTxn({
    required String purpose,
    required TxnDirection direction,
    required String merchant,
    double amount = 1000,
  }) async {
    final db = await YaadDb.db;
    final now = DateTime(2026, 9, 15).millisecondsSinceEpoch;
    final id = 'act-${_id++}';
    await db.insert('transactions', {
      'id': id,
      'amount': amount,
      'currency': 'PKR',
      'dateTime': now,
      'direction': direction.name,
      'kind': direction == TxnDirection.out ? 'spend' : 'receive',
      'rawMerchant': merchant,
      'purpose': purpose,
      'note': '',
      'tags': '[]',
      'source': 'manual',
      'status': 'confirmed',
      'createdAt': now,
      'updatedAt': now,
    });
  }

  Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)));

  /// The picker grid and the filter sheet are taller than the default
  /// 800x600 test viewport; give them room so every tile/chip is tappable.
  Future<void> pumpTall(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(wrap(child));
  }

  // (a) Custom purpose: create -> registry, picker tile, filter chip.
  test('create custom purpose: registry, picker and filter see it',
      () async {
    final cp = await YaadDb.insertCustomPurpose('Zakat');
    expect(cp.id, 'custom_zakat');
    expect(cp.label, 'Zakat');

    final all = await YaadDb.customPurposes();
    expect(all.map((c) => c.label), contains('Zakat'));

    // purposeLabel()/purposeIcon() resolve the custom id gracefully.
    expect(purposeLabel(cp.id), 'Zakat');
    expect(purposeIcon(cp.id), Icons.tag);
    expect(isCustomPurpose(cp.id), isTrue);
    expect(isCustomPurpose('groceries'), isFalse);
    // Unknown ids still fall back safely.
    expect(purposeLabel('nope'), 'Other');
    expect(purposeIcon('nope'), Icons.help_outline);
  });

  testWidgets('custom purpose appears in the picker grid', (tester) async {
    final cp = CustomPurpose(id: 'custom_zakat', label: 'Zakat', createdAt: 0);
    var tappedNew = false;
    String? tapped;
    await pumpTall(tester, PurposeGrid(
      purposes: [...kSpendPurposes, cp.asPurpose],
      selected: 'uncategorized',
      onSelect: (p) => tapped = p,
      customIds: {cp.id},
      onAddCustom: () => tappedNew = true,
      newTileLabel: '＋ New purpose',
    ));

    expect(find.text('Zakat'), findsOneWidget);
    expect(find.text('＋ New purpose'), findsOneWidget);

    await tester.tap(find.text('Zakat'));
    expect(tapped, 'custom_zakat');
    await tester.tap(find.text('＋ New purpose'));
    expect(tappedNew, isTrue);
  });

  testWidgets('custom purpose appears in the filter sheet', (tester) async {
    final cp = CustomPurpose(id: 'custom_zakat', label: 'Zakat', createdAt: 0);
    await pumpTall(tester, ActivityFilterSheet(
      s: const Strings('en'),
      initialPurposes: const {},
      initialDirection: null,
      customs: [cp],
      onChanged: (_) {},
    ));

    expect(find.text('Filters'), findsOneWidget);
    expect(find.text('My purposes'), findsOneWidget);
    expect(find.text('Zakat'), findsOneWidget);
  });

  // (b) Multi-select purposes filter correctly.
  test('txns filters by a purpose set (multi-select)', () async {
    await insertTxn(
        purpose: 'groceries', direction: TxnDirection.out, merchant: 'M1');
    await insertTxn(
        purpose: 'food', direction: TxnDirection.out, merchant: 'M2');
    await insertTxn(
        purpose: 'bills', direction: TxnDirection.out, merchant: 'M3');

    final rows =
        await YaadDb.txns(limit: 500, purposes: {'groceries', 'food'});
    expect(rows.map((t) => t.purpose).toSet(), {'groceries', 'food'});

    final one = await YaadDb.txns(limit: 500, purposes: {'bills'});
    expect(one.map((t) => t.purpose).toSet(), {'bills'});

    final none = await YaadDb.txns(limit: 500, purposes: null);
    expect(none.length, 3);
  });

  testWidgets('sheet toggles purposes multi-select, live', (tester) async {
    FilterSelection? last;
    await pumpTall(tester, ActivityFilterSheet(
      s: const Strings('en'),
      initialPurposes: const {},
      initialDirection: null,
      customs: const [],
      onChanged: (sel) => last = sel,
    ));

    await tester.tap(find.text('Groceries'));
    await tester.pump();
    expect(last, isNotNull);
    expect(last!.purposes, {'groceries'});

    await tester.tap(find.text('Food'));
    await tester.pump();
    expect(last!.purposes, {'groceries', 'food'});

    // Tap again clears just that one.
    await tester.tap(find.text('Groceries'));
    await tester.pump();
    expect(last!.purposes, {'food'});
  });

  // (c) direction + purposes + search combine (mirrors the timeline).
  test('direction AND purposes AND search combine', () async {
    await insertTxn(
        purpose: 'groceries',
        direction: TxnDirection.out,
        merchant: 'KHAADI GROCERY');
    await insertTxn(
        purpose: 'food',
        direction: TxnDirection.out,
        merchant: 'KHAADI FOODS');
    await insertTxn(
        purpose: 'groceries',
        direction: TxnDirection.incoming,
        merchant: 'KHAADI REFUND');

    // Same call the timeline makes: SQL for query+purposes…
    var rows = await YaadDb.txns(
        limit: 500, query: 'KHAADI', purposes: {'groceries'});
    expect(rows.map((t) => t.rawMerchant).toSet(),
        {'KHAADI GROCERY', 'KHAADI REFUND'});

    // …then the direction filter the timeline applies client-side.
    const direction = TxnDirection.out;
    rows = rows.where((t) => t.direction == direction).toList();
    expect(rows.map((t) => t.rawMerchant).toList(), ['KHAADI GROCERY']);
  });

  // (d) Delete reassigns transactions to 'uncategorized'.
  test('delete custom purpose reassigns its transactions', () async {
    final cp = await YaadDb.insertCustomPurpose('Eid Gifts');
    await insertTxn(
        purpose: cp.id,
        direction: TxnDirection.out,
        merchant: 'TOY SHOP');

    await YaadDb.deleteCustomPurpose(cp.id);

    expect(await YaadDb.customPurposes(), isEmpty);
    final rows = await YaadDb.txns(limit: 500);
    expect(rows.length, 1);
    expect(rows.first.purpose, 'uncategorized');
    // Registry fell back: never an orphan label.
    expect(purposeLabel(cp.id), 'Other');
  });

  testWidgets('long-press deletes a custom purpose from the sheet',
      (tester) async {
    final cp = await YaadDb.insertCustomPurpose('Zakat');
    FilterSelection? last;
    await pumpTall(tester, ActivityFilterSheet(
      s: const Strings('en'),
      initialPurposes: const {},
      initialDirection: null,
      customs: [cp],
      onChanged: (sel) => last = sel,
    ));

    expect(find.text('Zakat'), findsOneWidget);
    await tester.longPress(find.text('Zakat'));
    await tester.pumpAndSettle();
    expect(find.text('Delete purpose?'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Zakat'), findsNothing);
    expect(
        (await YaadDb.customPurposes()).map((c) => c.id), isNot(contains(cp.id)));
    expect(last, isNotNull);
    // The sheet told the timeline to refresh its selection.
    expect(last!.purposes, isEmpty);
  });

  // (e) Clear-all resets.
  testWidgets('clear-all resets purposes and direction', (tester) async {
    FilterSelection? last;
    await pumpTall(tester, ActivityFilterSheet(
      s: const Strings('en'),
      initialPurposes: const {'groceries', 'food'},
      initialDirection: TxnDirection.out,
      customs: const [],
      onChanged: (sel) => last = sel,
    ));

    await tester.tap(find.text('Clear all'));
    await tester.pump();

    expect(last, isNotNull);
    expect(last!.purposes, isEmpty);
    expect(last!.direction, isNull);
    // One-line feedback, per the Khatir notes.
    expect(find.text('Filters cleared'), findsOneWidget);
  });

  testWidgets('direction is single-select, tap again clears', (tester) async {
    FilterSelection? last;
    await pumpTall(tester, ActivityFilterSheet(
      s: const Strings('en'),
      initialPurposes: const {},
      initialDirection: null,
      customs: const [],
      onChanged: (sel) => last = sel,
    ));

    await tester.tap(find.text('Money out'));
    await tester.pump();
    expect(last!.direction, TxnDirection.out);

    await tester.tap(find.text('Money out'));
    await tester.pump();
    expect(last!.direction, isNull);

    await tester.tap(find.text('Money in'));
    await tester.pump();
    expect(last!.direction, TxnDirection.incoming);
  });

  // (f) Urdu completeness.
  test('urduComplete covers every new filter string', () {
    expect(Strings.urduComplete, isTrue);
    const keys = [
      'filters',
      'clearAll',
      'filtersCleared',
      'myPurposes',
      'newPurpose',
      'purposeNameHint',
      'purposeAdded',
      'purposeExists',
      'deletePurposeTitle',
      'deletePurposeBody',
      'purposeDeleted',
      'longPressHint',
      'noCustomHint',
      'noMatchFilters',
      'tryClearing',
    ];
    for (final k in keys) {
      expect(Strings('en').get(k), isNotEmpty, reason: 'en:$k');
      expect(Strings('ur').get(k), isNotEmpty, reason: 'ur:$k');
    }
  });
}
