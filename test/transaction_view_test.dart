import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/confirm.dart';
import 'package:yaad/screens/transaction_view.dart';
import 'package:yaad/services/txn_display.dart';
import 'package:yaad/theme.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Transaction detail view (v1.4): renders every populated field,
/// hides empty optional sections, Edit navigates to the editor,
/// and the source badge speaks every TxnSource in EN + UR.
///
/// Widget tests inject [TxnDisplayNames] explicitly — the screen's
/// own database lookups can't run inside the widget-test FakeAsync
/// zone (the ffi isolate's replies never arrive there). The loader
/// itself is covered by plain unit tests below, in the real zone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-txnview-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
    // Open the real DB so seeded accounts exist.
    await YaadDb.db;
  });

  tearDown(() {
    appState.settings = const AppSettings();
  });

  YaadTransaction fullTxn() => YaadTransaction(
        amount: 2500,
        dateTime: DateTime(2026, 10, 1, 14, 30),
        kind: TxnKind.spend,
        rawMerchant: 'ViewTest Diner 42',
        purpose: 'food',
        note: 'team lunch',
        voiceNote: 'doodh bhi lena hai',
        audioPath: '/tmp/voice_1.m4a',
        bankReference: 'REF-12345',
        source: TxnSource.notification,
      );

  const fullNames = TxnDisplayNames(
    personName: 'ViewTest Bilal',
    accountLabel: 'Meezan',
  );

  Future<void> pumpView(WidgetTester tester, YaadTransaction t,
      {TxnDisplayNames? names}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YaadTheme.light('teal'),
        home: TransactionViewScreen(txn: t, names: names),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('rendering', () {
    testWidgets('renders all populated fields', (tester) async {
      await pumpView(tester, fullTxn(), names: fullNames);

      // Hero: signed prominent amount.
      expect(find.byKey(const Key('txnHero')), findsOneWidget);
      expect(find.text('−PKR 2,500'), findsOneWidget);
      // Kind + title + date/time.
      expect(find.text('Spent'), findsAtLeastNWidgets(1));
      expect(find.text('ViewTest Diner 42'), findsOneWidget);
      expect(find.textContaining('01/10/2026'), findsOneWidget);
      // Chips: purpose, account tag, source badge.
      expect(find.text('Food'), findsOneWidget);
      expect(find.text('Meezan'), findsOneWidget);
      expect(find.text('Bank alert'), findsOneWidget);
      // Person section.
      expect(find.byKey(const Key('txnPerson')), findsOneWidget);
      expect(find.text('ViewTest Bilal'), findsOneWidget);
      // Typed note.
      expect(find.byKey(const Key('txnNote')), findsOneWidget);
      expect(find.text('team lunch'), findsOneWidget);
      // Voice transcript + play button (file path present).
      expect(find.byKey(const Key('txnVoice')), findsOneWidget);
      expect(find.text('doodh bhi lena hai'), findsOneWidget);
      expect(find.byKey(const Key('txnVoicePlay')), findsOneWidget);
      // Bank reference.
      expect(find.byKey(const Key('txnBankRef')), findsOneWidget);
      expect(find.text('REF-12345'), findsOneWidget);
    });

    testWidgets('hides every section that has no data', (tester) async {
      final t = YaadTransaction(
        amount: 500,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.receive,
        purpose: 'salary',
        source: TxnSource.manual,
        accountId: 'cash',
      );
      await pumpView(tester, t,
          names: const TxnDisplayNames(accountLabel: 'Cash'));

      expect(find.byKey(const Key('txnHero')), findsOneWidget);
      expect(find.text('+PKR 500'), findsOneWidget);
      // No empty sections: person, note, voice, receipt, bank ref
      // are all absent — no blank labels or rows.
      expect(find.byKey(const Key('txnPerson')), findsNothing);
      expect(find.byKey(const Key('txnNote')), findsNothing);
      expect(find.byKey(const Key('txnVoice')), findsNothing);
      expect(find.byKey(const Key('txnReceipt')), findsNothing);
      expect(find.byKey(const Key('txnBankRef')), findsNothing);
      // Kind + purpose + account + source chips still render.
      expect(find.text('Received'), findsAtLeastNWidgets(1));
      expect(find.text('Salary'), findsOneWidget);
      expect(find.text('Cash'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
    });

    testWidgets('voice transcript without a file shows no play button',
        (tester) async {
      final t = YaadTransaction(
        amount: 100,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.spend,
        voiceNote: 'words only',
        accountId: 'meezan',
      );
      await pumpView(tester, t,
          names: const TxnDisplayNames(accountLabel: 'Meezan'));

      expect(find.byKey(const Key('txnVoice')), findsOneWidget);
      expect(find.text('words only'), findsOneWidget);
      expect(find.byKey(const Key('txnVoicePlay')), findsNothing);
    });

    testWidgets('transfer shows no sign on the amount', (tester) async {
      final t = YaadTransaction(
        amount: 10000,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.transfer,
        accountId: 'savings',
      );
      await pumpView(tester, t,
          names: const TxnDisplayNames(accountLabel: 'Savings'));

      expect(find.text('PKR 10,000'), findsOneWidget);
    });

    testWidgets('Urdu: labels and account tag are localised', (tester) async {
      appState.settings = const AppSettings(language: 'ur');
      final t = YaadTransaction(
        amount: 1200,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.spend,
        purpose: 'groceries',
        source: TxnSource.sms,
        accountId: 'meezan',
      );
      await pumpView(tester, t,
          names: const TxnDisplayNames(accountLabel: 'میزان'));

      expect(find.text('خرچ'), findsAtLeastNWidgets(1)); // kind
      expect(find.text('گروسری'), findsOneWidget); // purpose
      expect(find.text('میزان'), findsOneWidget); // account tag
      expect(find.text('SMS الرٹ'), findsOneWidget); // source badge
      expect(find.text('ترمیم کریں'), findsOneWidget); // Edit action
    });
  });

  group('edit flow', () {
    testWidgets('Edit action opens the editor', (tester) async {
      await pumpView(tester, fullTxn(), names: fullNames);

      await tester.tap(find.byKey(const Key('txnEditButton')));
      await tester.pumpAndSettle();

      expect(find.byType(ConfirmScreen), findsOneWidget);
      // ConfirmScreen leaves a one-shot plugin timer pending in tests;
      // flush it so the test teardown invariant passes.
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('editor returns to the detail view, not a stale screen',
        (tester) async {
      await pumpView(tester, fullTxn(), names: fullNames);

      await tester.tap(find.byKey(const Key('txnEditButton')));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmScreen), findsOneWidget);
      // Back out of the editor: the view screen is still on top.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(TransactionViewScreen), findsOneWidget);
      expect(find.byType(ConfirmScreen), findsNothing);
      // Flush ConfirmScreen's one-shot plugin timer (see above).
      await tester.pump(const Duration(minutes: 5));
    });
  });

  group('loadTxnDisplayNames', () {
    test('resolves alias, person, and localised account', () async {
      final person = Person(name: 'Loader Ayesha');
      await YaadDb.insertPerson(person);
      await YaadDb.upsertAlias('Loader Marts 7', 'Loader Marts');
      final t = YaadTransaction(
        amount: 300,
        dateTime: DateTime(2026, 10, 2),
        rawMerchant: 'Loader Marts 7',
        personId: person.id,
        accountId: 'savings',
      );
      final names =
          await loadTxnDisplayNames(t, const Strings('en'));
      expect(names.alias, 'Loader Marts');
      expect(names.personName, 'Loader Ayesha');
      expect(names.accountLabel, 'Savings');
    });

    test('null accountId falls back to the default account', () async {
      final t = YaadTransaction(
        amount: 300,
        dateTime: DateTime(2026, 10, 2),
        accountId: null,
      );
      final names =
          await loadTxnDisplayNames(t, const Strings('en'));
      expect(names.accountLabel, 'Meezan');
      expect(names.alias, isNull);
      expect(names.personName, isNull);
    });

    test('unknown account id falls back to the raw id', () async {
      final t = YaadTransaction(
        amount: 300,
        dateTime: DateTime(2026, 10, 2),
        accountId: 'deleted-account',
      );
      final names =
          await loadTxnDisplayNames(t, const Strings('en'));
      expect(names.accountLabel, 'deleted-account');
    });

    test('account label is localised', () async {
      final t = YaadTransaction(
        amount: 300,
        dateTime: DateTime(2026, 10, 2),
        accountId: 'cash',
      );
      final names =
          await loadTxnDisplayNames(t, const Strings('ur'));
      expect(names.accountLabel, 'نقد');
    });
  });

  group('sourceLabel', () {
    test('covers every TxnSource in English', () {
      const s = Strings('en');
      expect(sourceLabel(s, TxnSource.notification), 'Bank alert');
      expect(sourceLabel(s, TxnSource.share), 'Shared from bank app');
      expect(sourceLabel(s, TxnSource.ocr), 'Receipt scan');
      expect(sourceLabel(s, TxnSource.statementImport), 'Statement import');
      expect(sourceLabel(s, TxnSource.sms), 'SMS alert');
      expect(sourceLabel(s, TxnSource.manual), 'Manual');
    });

    test('covers every TxnSource in Urdu (no English fallbacks)', () {
      const s = Strings('ur');
      const latin = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
      for (final src in TxnSource.values) {
        final label = sourceLabel(s, src);
        expect(label.isNotEmpty, isTrue, reason: '$src empty');
        // SMS stays latin by convention; everything else must be Urdu.
        if (src != TxnSource.sms) {
          expect(label.contains(RegExp('[$latin]')), isFalse,
              reason: '$src fell back to English: $label');
        }
      }
    });
  });
}
