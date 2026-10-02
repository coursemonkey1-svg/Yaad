import 'dart:async';
import 'dart:io';

import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:yaad/app_lock_guard.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/inbox.dart';
import 'package:yaad/screens/onboarding.dart';
import 'package:yaad/screens/pro.dart';
import 'package:yaad/services/sms_capture.dart';
import 'package:yaad/services/capture_inbox.dart';
import 'package:yaad/services/importer.dart';
import 'package:yaad/services/meezan_parser.dart';
import 'package:yaad/widgets/guided_tour.dart';
import 'package:yaad/widgets/statement_import_wait.dart';

/// Flow-level audit tests for v1.5 WS-system: app lock error mapping,
/// importer variants/edge cases, capture inbox invariants, Pro gating
/// UI, tour on small screens, import-wait re-entrancy, onboarding back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // main() does this in production; Home's PeriodSelector reaches
    // AppState.nowInTz(), which needs the tz database.
    tzdata.initializeTimeZones();
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('lock error mapping', () {
    test('no-screen-lock codes get the dedicated message', () {
      for (final code in [
        'NotEnrolled',
        'PasscodeNotSet',
        'NotAvailable',
        'NoBiometricsEnrolled',
      ]) {
        expect(lockErrorKeyForPlatformCode(code), 'lockNotSupported',
            reason: code);
      }
    });

    test('other / unknown codes get the generic try-again message', () {
      expect(lockErrorKeyForPlatformCode('LockedOut'), 'lockAuthFailed');
      expect(lockErrorKeyForPlatformCode('PermanentlyLockedOut'),
          'lockAuthFailed');
      expect(lockErrorKeyForPlatformCode(null), 'lockAuthFailed');
      expect(lockErrorKeyForPlatformCode(''), 'lockAuthFailed');
    });
  });

  group('CaptureInbox invariants', () {
    test('adding the same transaction twice keeps one entry', () async {
      final inbox = CaptureInbox();
      await inbox.add(
          txnId: 'dup1',
          merchant: 'Bank',
          amount: 100,
          time: DateTime(2026, 9, 1, 10),
          needsReview: false);
      await inbox.add(
          txnId: 'dup1',
          merchant: 'Bank',
          amount: 100,
          time: DateTime(2026, 9, 1, 10, 5),
          needsReview: true);
      expect(inbox.entries, hasLength(1));
      expect(inbox.entries.single.needsReview, isTrue);
      expect(inbox.unreadCount, 1);
    });

    test('a backdated capture does not jump above newer entries', () async {
      final inbox = CaptureInbox();
      await inbox.add(
          txnId: 'new',
          merchant: 'n',
          amount: 1,
          time: DateTime(2026, 9, 10),
          needsReview: false);
      await inbox.add(
          txnId: 'old',
          merchant: 'o',
          amount: 1,
          time: DateTime(2026, 9, 1),
          needsReview: false);
      expect(inbox.entries.map((e) => e.txnId), ['new', 'old']);
    });

    test('removeEntry drops the entry and persists', () async {
      final inbox = CaptureInbox();
      await inbox.add(
          txnId: 'gone',
          merchant: 'g',
          amount: 1,
          time: DateTime(2026, 9, 1),
          needsReview: false);
      await inbox.removeEntry(inbox.entries.single.id);
      expect(inbox.entries, isEmpty);
      expect(inbox.unreadCount, 0);
      final reloaded = CaptureInbox();
      await reloaded.load();
      expect(reloaded.entries, isEmpty);
      // Removing a missing id is a no-op, not an error.
      await inbox.removeEntry('no-such-id');
    });

    test('load() enforces newest-first order and the cap', () async {
      final inbox = CaptureInbox();
      // Write 55 entries oldest-first via add() with increasing times
      // is already ordered; instead seed disorder through add() of a
      // backdated entry in the middle, then reload from storage.
      for (var i = 0; i < 55; i++) {
        await inbox.add(
            txnId: 't$i',
            merchant: 'm',
            amount: i.toDouble(),
            time: DateTime(2026, 1, 1).add(Duration(days: i)),
            needsReview: false);
      }
      final reloaded = CaptureInbox();
      await reloaded.load();
      expect(reloaded.entries.length, CaptureInbox.maxEntries);
      for (var i = 1; i < reloaded.entries.length; i++) {
        expect(reloaded.entries[i - 1].time.isAfter(reloaded.entries[i].time),
            isTrue,
            reason: 'entries must be newest-first after load');
      }
    });
  });

  group('StatementImporter file variants', () {
    Future<File> writeTmp(String name, String content) async {
      final f = File('${Directory.systemTemp.path}/$name');
      await f.writeAsString(content);
      return f;
    }

    test(
        '"Debit Amount"/"Credit Amount" columns are not read as one '
        'signed Amount column (debits were recorded as money in)', () async {
      final f = await writeTmp(
          'flow_dr_cr.csv',
          'Date,Description,Debit Amount,Credit Amount\n'
              '01 Mar 2026,FLOWIMP SHOP,1500,\n'
              '02 Mar 2026,FLOWIMP SALARY,,9000\n');
      final st = await StatementImporter().parseFile(f.path);
      expect(st.rows, hasLength(2));
      expect(st.rows[0].kind, TxnKind.spend);
      expect(st.rows[0].amount, 1500);
      expect(st.rows[1].kind, TxnKind.receive);
      expect(st.rows[1].amount, 9000);
    });

    test('semicolon-delimited file with a UTF-8 BOM parses', () async {
      final f = await writeTmp(
          'flow_semi.csv',
          '\uFEFFDate;Description;Amount\n'
              '01 Mar 2026;FLOWIMP SEMI;-750.00\n'
              '02 Mar 2026;FLOWIMP SEMI IN;1,200.00\n');
      final st = await StatementImporter().parseFile(f.path);
      expect(st.rows, hasLength(2));
      expect(st.rows[0].kind, TxnKind.spend);
      expect(st.rows[0].amount, 750);
      expect(st.rows[1].kind, TxnKind.receive);
      expect(st.rows[1].amount, 1200);
    });

    test('accounting parentheses in a single Amount column mean money out',
        () async {
      final f = await writeTmp(
          'flow_paren.csv',
          'Date,Description,Amount\n'
              '"01 Mar 2026","FLOWIMP PAREN","(2,500.00)"\n');
      final st = await StatementImporter().parseFile(f.path);
      expect(st.rows, hasLength(1));
      expect(st.rows.single.kind, TxnKind.spend);
      expect(st.rows.single.amount, 2500);
    });

    test('a row with an unreadable date is skipped, not re-dated to today',
        () async {
      final f = await writeTmp(
          'flow_baddate.csv',
          'Date,Description,Amount\n'
              'no date here,FLOWIMP NODATE,-50.00\n'
              '01 Mar 2026,FLOWIMP GOOD,-60.00\n');
      final st = await StatementImporter().parseFile(f.path);
      expect(st.rows.map((r) => r.merchant), ['FLOWIMP GOOD']);
      expect(st.errors.join(' '), contains('could not read the date'));
    });

    test(
        'identical rows inside one file are legitimate repeats: both '
        'import, and re-importing the file flags both', () async {
      // The shared on-disk test DB persists across runs: clear any
      // copies a previous run of this very test committed, so the
      // occurrence counts below start from a known zero.
      final d = await YaadDb.db;
      await d.delete('transactions',
          where: 'rawMerchant = ?', whereArgs: ['FLOWIMP TWINS']);
      final f = await writeTmp(
          'flow_dup.csv',
          'Date,Description,Amount\n'
              '01 Mar 2026,FLOWIMP TWINS,-100.00\n'
              '01 Mar 2026,FLOWIMP TWINS,-100.00\n');
      final importer = StatementImporter();
      final st = await importer.parseFile(f.path);
      expect(st.rows, hasLength(2));
      // Occurrence-aware: the database holds no copies yet, so neither
      // copy is a duplicate (statements legitimately repeat identical
      // charges — existence-matching used to drop the second one).
      expect(st.rows.every((r) => !r.isDuplicate), isTrue);
      final report = await importer.commitRows(
          st.rows.where((r) => r.selected).toList(), st.mappingSignature,
          mapping: st.mapping);
      expect(report.imported, 2);
      expect(report.duplicates, 0);
      // Now the database holds both copies: the same file re-imported
      // flags both rows as duplicates.
      final again = await importer.parseFile(f.path);
      expect(again.rows.every((r) => r.isDuplicate), isTrue);
    });

    test('whitespace-separated .txt statement parses via the text fallback',
        () async {
      final f = await writeTmp(
          'flow_txt.txt',
          'Date  Description  Amount\n'
              '01 Mar 2026  FLOWIMP TXT  -300.00\n');
      final st = await StatementImporter().parseFile(f.path);
      expect(st.rows, hasLength(1));
      expect(st.rows.single.merchant, 'FLOWIMP TXT');
      expect(st.rows.single.amount, 300);
      expect(st.rows.single.kind, TxnKind.spend);
    });

    test('xlsx: data on the second sheet is found past a blank first sheet',
        () async {
      final xl = Excel.createExcel();
      xl['Sheet1']; // blank sheet stays first
      final data = xl['Data'];
      data.appendRow([
        TextCellValue('Date'),
        TextCellValue('Description'),
        TextCellValue('Amount'),
      ]);
      data.appendRow([
        TextCellValue('01 Mar 2026'),
        TextCellValue('FLOWIMP XLSX'),
        DoubleCellValue(-425.5),
      ]);
      final bytes = xl.encode();
      expect(bytes, isNotNull);
      final f = File('${Directory.systemTemp.path}/flow_xlsx.xlsx');
      await f.writeAsBytes(bytes!);
      final st = await StatementImporter().parseFile(f.path);
      expect(st.rows, hasLength(1));
      expect(st.rows.single.merchant, 'FLOWIMP XLSX');
      expect(st.rows.single.amount, 425.5);
      expect(st.rows.single.kind, TxnKind.spend);
    });

    test('a non-Excel file named .xlsx lands on an error, not a throw',
        () async {
      final f = await writeTmp('flow_fake.xlsx', 'this is not a workbook');
      final st = await StatementImporter().parseFile(f.path);
      expect(st.rows, isEmpty);
      expect(st.errors, isNotEmpty);
    });
  });

  group('MeezanParser date validation', () {
    test('an impossible date (31 Feb) is skipped, never rolled into March', () {
      const page = 'Booking DateDescriptionCreditDebitAvailable Balance'
          '31 Feb 2026Bad Row- PKR100.00PKR900.00'
          '01 Mar 2026Good Row+ PKR100.00PKR1,000.00'
          '130 Mar 2026, 09:41';
      final st = MeezanParser.parse(page);
      expect(st.rows, hasLength(1));
      expect(st.rows.single.description, contains('Good Row'));
      expect(st.rows.single.date, DateTime(2026, 3, 1));
      expect(st.warnings.join(' '), contains('invalid date'));
    });

    test('repeated header-less pages produce one warning, not a flood', () {
      final st = MeezanParser.parse('junk one\njunk two\njunk three\n');
      expect(
          st.warnings.where((w) => w.contains('without the statement header')),
          hasLength(1));
    });

    test(
        'remittances from the same sender get distinct references '
        '(the shared sender-account token is not the reference)', () {
      const page = 'Booking DateDescriptionCreditDebitAvailable Balance'
          '02 Jul 2026Remittance From SENDER ONE NBPXXXX4253027386 STAN(111111)'
          '+ PKR5,000.00PKR5,000.00'
          '03 Jul 2026Remittance From SENDER ONE NBPXXXX4253027386 STAN(222222)'
          '+ PKR5,000.00PKR10,000.00'
          '130 Sep 2026, 09:41';
      final st = MeezanParser.parse(page);
      expect(st.rows, hasLength(2));
      expect(st.rows[0].reference, 'STAN111111:5000.00');
      expect(st.rows[1].reference, 'STAN222222:5000.00');
    });
  });

  group('ProScreen purchase UI gating', () {
    Future<void> pumpPro(WidgetTester tester, AppSettings settings) async {
      appState.settings = settings;
      await tester.pumpWidget(const MaterialApp(home: ProScreen()));
      await tester.pumpAndSettle();
    }

    tearDown(() => appState.settings = const AppSettings());

    testWidgets('billing off: no buy/restore UI, coming-soon message shown',
        (tester) async {
      await pumpPro(tester, const AppSettings(billingEnabled: false));
      expect(find.text('Pro is coming soon'), findsOneWidget);
      expect(find.textContaining('Get Pro'), findsNothing);
      expect(find.text('Restore purchase'), findsNothing);
    });

    testWidgets('already Pro: thank-you shown, never sold a second time',
        (tester) async {
      await pumpPro(
          tester, const AppSettings(billingEnabled: true, proUnlocked: true));
      expect(find.text('Pro is active on this phone — thank you.'),
          findsOneWidget);
      expect(find.textContaining('Get Pro'), findsNothing);
      expect(find.text('Restore purchase'), findsNothing);
    });

    testWidgets('billing on and not Pro: buy + restore are offered',
        (tester) async {
      await pumpPro(tester, const AppSettings(billingEnabled: true));
      expect(find.textContaining('Get Pro'), findsOneWidget);
      expect(find.text('Restore purchase'), findsOneWidget);
    });

    testWidgets('the screen closes when Pro actually unlocks '
        '(purchase stream / restore), not before', (tester) async {
      appState.settings = const AppSettings(billingEnabled: true);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProScreen())),
              child: const Text('open pro'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open pro'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Get Pro'), findsOneWidget);
      // Simulate the purchase stream flipping proUnlocked.
      await appState
          .update(appState.settings.copyWith(proUnlocked: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('Get Pro'), findsNothing);
      expect(find.text('open pro'), findsOneWidget);
    });
  });

  group('guided tour on a small screen', () {
    testWidgets('tiny landscape screen: no overflow, tour can finish',
        (tester) async {
      tester.view.physicalSize = const Size(320, 240);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      BuildContext? ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold(body: Text('home'));
        }),
      ));
      await tester.pumpAndSettle();
      var finished = 0;
      GuidedTour.show(
        ctx!,
        steps: const [
          TourStep(
              tab: 0,
              titleKey: 'tourAddTitle',
              bodyKey: 'tourAddBody',
              hintKey: 'tourAddHint'),
        ],
        strings: const Strings('en'),
        onFinish: () => finished++,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Skip'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(finished, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('show() with no steps is a no-op, not a crash', (tester) async {
      BuildContext? ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold(body: Text('home'));
        }),
      ));
      await tester.pumpAndSettle();
      await GuidedTour.show(ctx!,
          steps: const [], strings: const Strings('en'), onFinish: () {});
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Skip'), findsNothing);
    });
  });

  group('statement import wait re-entrancy', () {
    testWidgets(
        'a second runStatementImport while one is waiting returns cancelled',
        (tester) async {
      BuildContext? ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold(body: Text('host'));
        }),
      ));
      await tester.pumpAndSettle();
      Future<ParsedStatement> hang(String _) =>
          Completer<ParsedStatement>().future;
      final first = runStatementImport(ctx!,
          path: 'a.pdf',
          strings: const Strings('en'),
          parse: hang,
          timeout: const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump();
      expect(find.text('Reading your statement…'), findsOneWidget);

      StatementImportResult? second;
      runStatementImport(ctx!,
              path: 'b.pdf', strings: const Strings('en'), parse: hang)
          .then((r) => second = r);
      await tester.pump();
      await tester.pump();
      expect(second?.outcome, StatementImportOutcome.cancelled);
      // Still exactly one progress dialog on screen.
      expect(find.text('Reading your statement…'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await first).outcome, StatementImportOutcome.cancelled);
      // Let the abandoned parse's own 500ms timeout elapse so no timer
      // is left pending at teardown.
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('FAB visibility per tab (build-24 screenshot issue)', () {
    test('the Add FAB exists on Home/Activity/Udhaar, never on Settings',
        () {
      expect(yaadFabVisibleForTab(0), isTrue); // Home
      expect(yaadFabVisibleForTab(1), isTrue); // Activity
      expect(yaadFabVisibleForTab(2), isTrue); // Udhaar
      expect(yaadFabVisibleForTab(3), isFalse); // Settings
    });

    testWidgets(
        'shell: FAB present on Home, absent (no phantom target) on Settings',
        (tester) async {
      // Mock the share-intent plugin so MainShell.initState doesn't
      // hit missing platform channels.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('receive_sharing_intent/messages'),
          (call) async => null);
      messenger.setMockStreamHandler(
          const EventChannel('receive_sharing_intent/events-media'),
          MockStreamHandler.inline(onListen: (args, events) {}));
      // Mock the capture channel: reconcile + setters run on shell start.
      messenger.setMockMethodCallHandler(const MethodChannel('yaad/capture'),
          (call) async => null);

      appState.settings =
          const AppSettings(onboardingDone: true, tourSeen: true);
      await tester.pumpWidget(const MaterialApp(home: MainShell()));
      await tester.pump();
      await tester.pump();

      // Home: the FAB is there.
      expect(find.byType(FloatingActionButton), findsOneWidget);
      final fabCenter = tester.getCenter(find.byType(FloatingActionButton));

      // Settings tab: no FAB widget at all — and a tap where the FAB
      // used to float must NOT open the Add sheet (no phantom target).
      // (IndexedStack keeps every tab in the tree, so nav destinations
      // are tapped by icon, not by label text.)
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      // Scaffold animates the FAB out when it becomes null — advance
      // past the exit animation before asserting it is really gone.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FloatingActionButton), findsNothing);

      // Back on Home the FAB returns.
      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pump();
      await tester.pump();
      expect(find.byType(FloatingActionButton), findsOneWidget);

      // No phantom tap target: on Settings again (FAB gone), a tap at
      // the FAB's old spot must NOT open the Add sheet. Done last:
      // the tap lands on whatever Settings row lives there now, which
      // is exactly the point — the row gets the tap, not a ghost FAB.
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.tapAt(fabCenter);
      await tester.pump();
      await tester.pump();
      expect(find.text('What happened?'), findsNothing);

      // Let sqflite's internal 10s transaction watchdog timers (from
      // the tab screens' stalled FakeAsync DB queries) fire before
      // teardown, or the binding's no-pending-timers invariant fails.
      await tester.pump(const Duration(seconds: 11));

      messenger.setMockMethodCallHandler(
          const MethodChannel('receive_sharing_intent/messages'), null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('yaad/capture'), null);
      appState.settings = const AppSettings();
    });
  });

  group('capture toggle reconciliation', () {
    const channel = MethodChannel('yaad/capture');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      appState.settings = const AppSettings();
    });

    bool? nativeFlag(String method) {
      final hits = calls.where((c) => c.method == method);
      if (hits.isEmpty) return null;
      return hits.last.arguments['enabled'] as bool?;
    }

    test('switch ON but OS access revoked: flag turns OFF (no lying ON)',
        () async {
      appState.settings = const AppSettings(
          smsCapture: true, notificationCapture: true);
      await CaptureService.reconcileCaptureFlags(
        smsPermissionGranted: () async => false, // revoked in OS settings
        notificationAccessGranted: () async => true,
      );
      expect(appState.settings.smsCapture, isFalse);
      expect(appState.settings.notificationCapture, isTrue);
      // Native queueing follows the reconciled truth both ways.
      expect(nativeFlag('setSmsEnabled'), isFalse);
      expect(nativeFlag('setNotificationEnabled'), isTrue);
    });

    test('flags ON and access really granted: native side re-asserted',
        () async {
      appState.settings = const AppSettings(
          smsCapture: true, notificationCapture: true);
      await CaptureService.reconcileCaptureFlags(
        smsPermissionGranted: () async => true,
        notificationAccessGranted: () async => true,
      );
      expect(appState.settings.smsCapture, isTrue);
      expect(appState.settings.notificationCapture, isTrue);
      expect(nativeFlag('setSmsEnabled'), isTrue);
      expect(nativeFlag('setNotificationEnabled'), isTrue);
    });

    test('flags OFF: native queueing is forced off too', () async {
      appState.settings = const AppSettings();
      await CaptureService.reconcileCaptureFlags(
        smsPermissionGranted: () async => true,
        notificationAccessGranted: () async => true,
      );
      expect(appState.settings.smsCapture, isFalse);
      expect(appState.settings.notificationCapture, isFalse);
      expect(nativeFlag('setSmsEnabled'), isFalse);
      expect(nativeFlag('setNotificationEnabled'), isFalse);
    });
  });

  group('inbox end-of-list clearance', () {
    testWidgets('the inbox list carries generous bottom padding',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await CaptureInbox.instance.add(
          txnId: 'pad-test-txn',
          merchant: 'PAD SHOP',
          amount: 250,
          time: DateTime(2026, 10, 1),
          needsReview: false);
      await tester.pumpWidget(const MaterialApp(home: InboxScreen()));
      // Manual pumps: loading spinner + prefs futures; pumpAndSettle
      // would spin on the CircularProgressIndicator.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('PAD SHOP'), findsOneWidget);
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.padding, isNotNull);
      expect(list.padding!.resolve(TextDirection.ltr).bottom,
          greaterThanOrEqualTo(80),
          reason:
              'last inbox row must clear the system bar / floating UI');
    });
  });

  group('onboarding back behaviour', () {
    testWidgets('system back on page 2 returns to page 1, not out of the app',
        (tester) async {
      appState.settings = const AppSettings();
      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Your money, remembered.'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Recording takes 10 seconds.'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Your money, remembered.'), findsOneWidget);
      expect(find.text('Recording takes 10 seconds.'), findsNothing);
    });
  });
}
