import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/purposes.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/confirm.dart';
import 'package:yaad/screens/transaction_view.dart';
import 'package:yaad/services/ocr.dart';
import 'package:yaad/services/txn_display.dart';
import 'package:yaad/widgets/note_field.dart';
import 'package:yaad/widgets/purpose_dialogs.dart';
import 'package:yaad/widgets/purpose_grid.dart';

/// Flow-level audit tests for capture & transaction detail (v1.5).
///
/// The centrepiece is the voice-note lifecycle contract that build-24
/// broke and fixed: a recording attached to a SAVED transaction must
/// survive save → close → reopen, must survive backing out of an edit
/// that discarded it, and must be removed (row + file together) only
/// when the discarding edit is actually saved. The record/speech
/// plugins have no test implementations, so a recording cannot be
/// *made* in a widget test; the contract is therefore pinned at every
/// seam reachable without them (edit-save, edit-discard-cancel,
/// edit-discard-save, view-delete), which is exactly where the
/// deletion decisions live.
///
/// DB work is real sqlite: reads/writes from the test body go through
/// tester.runAsync, and UI-triggered saves are given real time inside
/// runAsync to land before assertions run.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    // AppState.periodRangeMs() (called by ConfirmScreen._save) reads
    // the timezone database — production initializes it in main();
    // without this every save dies with a LateInitializationError.
    tzdata.initializeTimeZones();
    // ConfirmScreen constructs an AudioRecorder whose (unawaited)
    // platform 'create' call throws MissingPluginException in tests;
    // the error lands during runAsync windows and fails the test.
    // Mock the record channel: every method is void/nullable there.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async => null,
    );
    tmpDir = await Directory.systemTemp.createTemp('yaad-flow-audit');
    await YaadDb.db;
  });

  setUp(() {
    appState.settings = const AppSettings();
  });

  /// Host page that pushes [screen] from a button — mirrors how the
  /// app actually navigates, so popping the screen under test lands
  /// back here instead of on a black route.
  Future<void> pumpHost(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => screen)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Reveals [finder] in the screen's lazy ListView, scrolling with
  /// jumpTo steps — NOT gestures: a drag that starts on a TextField
  /// is eaten by its text-selection gesture and the list never moves
  /// (dragUntilVisible then reports a bare "Bad state: No element"
  /// for the target). The lazy list doesn't build below-the-fold
  /// children at all (the Save button sits ~900px down), so a bare
  /// tap on them finds zero widgets.
  Future<void> revealInList(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isNotEmpty) return;
    final pos = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    var offset = pos.pixels;
    while (finder.evaluate().isEmpty && offset < pos.maxScrollExtent) {
      offset = (offset + 250).clamp(0.0, pos.maxScrollExtent).toDouble();
      pos.jumpTo(offset);
      await tester.pump();
    }
    await tester.ensureVisible(finder);
    await tester.pump();
  }

  /// Scrolls the screen's list until [finder] is built, then taps it.
  Future<void> tapInList(WidgetTester tester, Finder finder) async {
    await revealInList(tester, finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  /// Lets UI-triggered async DB work (started by a tap) finish in
  /// real time, then rebuilds. The alternation matters: a tap-born
  /// future chain (file check → DB write → refresh) advances one
  /// "real event → fake-zone microtask" hop per runAsync window, so a
  /// single window leaves _save stranded mid-chain. Loop until the
  /// chain has had several windows to drain.
  Future<void> settleRealWork(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
    // Run out route/snackbar animations: a popped screen is still
    // "found" by finders until its exit animation finishes, and the
    // fake clock only advances when a pump carries a duration.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  /// NOTE: file writes use the SYNC API on purpose - an awaited
  /// dart:io future inside a testWidgets body (FakeAsync zone) never
  /// completes, which is exactly how this helper once hung the whole
  /// file. Sync IO is zone-independent.
  File fakeAudio(String name) {
    final f = File(p.join(tmpDir.path, name));
    f.writeAsStringSync('fake-audio-bytes');
    return f;
  }

  group('voice note lifecycle (build-24 bug class)', () {
    testWidgets('save → close → reopen keeps the saved recording',
        (tester) async {
      final audio = fakeAudio('flow_keep.m4a');
      final t = YaadTransaction(
        amount: 800,
        dateTime: DateTime(2026, 10, 1, 9, 15),
        kind: TxnKind.spend,
        rawMerchant: 'FlowKeep Store',
        purpose: 'groceries',
        audioPath: audio.path,
        voiceNote: 'doodh aur cheeni',
      );
      await tester.runAsync(() => YaadDb.insertTxn(t));

      await pumpHost(
        tester,
        TransactionViewScreen(
          txn: t,
          names: const TxnDisplayNames(accountLabel: 'Meezan'),
        ),
      );
      // Voice card + play button render in the view screen.
      expect(find.byKey(const Key('txnVoice')), findsOneWidget);
      expect(find.byKey(const Key('txnVoicePlay')), findsOneWidget);
      expect(find.text('doodh aur cheeni'), findsOneWidget);

      // Edit → change nothing about the voice note → Save.
      await tester.tap(find.byKey(const Key('txnEditButton')));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmScreen), findsOneWidget);
      await tapInList(tester, find.text('Save'));
      await settleRealWork(tester);
      // Back on the view screen (the editor popped itself).
      expect(find.byType(TransactionViewScreen), findsOneWidget);
      expect(find.byType(ConfirmScreen), findsNothing);

      // THE regression assertion: closing the editor after save must
      // not have deleted the saved recording, and the row must still
      // point at it.
      expect(audio.existsSync(), isTrue);
      final fresh = await tester.runAsync(() => YaadDb.txnById(t.id));
      expect(fresh!.audioPath, audio.path);
      expect(fresh.voiceNote, 'doodh aur cheeni');

      // Reopen: pop back to the host and push a FRESH view instance
      // (a second pumpWidget would NOT reset the Navigator - its
      // state survives identical widget trees, routes and all).
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('txnVoice')), findsOneWidget);
      expect(find.byKey(const Key('txnVoicePlay')), findsOneWidget);
      expect(find.text('doodh aur cheeni'), findsOneWidget);
      // Flush ConfirmScreen's one-shot plugin timer.
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets(
        'discarding voice in the editor then backing out keeps the file',
        (tester) async {
      final audio = fakeAudio('flow_discard_cancel.m4a');
      final t = YaadTransaction(
        amount: 300,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.spend,
        rawMerchant: 'FlowDiscardCancel Store',
        audioPath: audio.path,
        voiceNote: 'keep me',
      );
      await tester.runAsync(() => YaadDb.insertTxn(t));

      await pumpHost(tester, ConfirmScreen(editing: t));
      expect(find.byType(ConfirmScreen), findsOneWidget);
      // Remove the recording inside the editor…
      await tapInList(tester, find.byTooltip('Remove recording'));
      await tester.pumpAndSettle();
      // …then back out WITHOUT saving.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmScreen), findsNothing);

      // The stored row still references the recording, so the file
      // must still exist (deleting it here was the orphan bug).
      expect(audio.existsSync(), isTrue);
      final fresh = await tester.runAsync(() => YaadDb.txnById(t.id));
      expect(fresh!.audioPath, audio.path);
      expect(fresh.voiceNote, 'keep me');
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('discarding voice and saving clears row and file together',
        (tester) async {
      final audio = fakeAudio('flow_discard_save.m4a');
      final t = YaadTransaction(
        amount: 450,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.spend,
        rawMerchant: 'FlowDiscardSave Store',
        audioPath: audio.path,
        voiceNote: 'remove me',
      );
      await tester.runAsync(() => YaadDb.insertTxn(t));

      await pumpHost(tester, ConfirmScreen(editing: t));
      await tapInList(tester, find.byTooltip('Remove recording'));
      await tester.pumpAndSettle();
      await tapInList(tester, find.text('Save'));
      await settleRealWork(tester);
      expect(find.byType(ConfirmScreen), findsNothing);

      final fresh = await tester.runAsync(() => YaadDb.txnById(t.id));
      expect(fresh!.audioPath, isNull);
      expect(fresh.voiceNote, isNull);
      // Cleared on save — the now-unreferenced file goes with it.
      expect(audio.existsSync(), isFalse);
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('editing amount and purpose persists', (tester) async {
      final t = YaadTransaction(
        amount: 100,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.spend,
        rawMerchant: 'FlowEdit Store',
        purpose: 'groceries',
        note: 'original note',
      );
      await tester.runAsync(() => YaadDb.insertTxn(t));

      await pumpHost(tester, ConfirmScreen(editing: t));
      // Amount is the first text field; note is the last one.
      await tester.enterText(find.byType(TextField).first, '275');
      await tapInList(tester, find.text('Food'));
      await tester.pumpAndSettle();
      await tapInList(tester, find.text('Save'));
      await settleRealWork(tester);

      final fresh = await tester.runAsync(() => YaadDb.txnById(t.id));
      expect(fresh!.amount, 275);
      expect(fresh.purpose, 'food');
      expect(fresh.note, 'original note');
      await tester.pump(const Duration(minutes: 5));
    });
  });

  group('manual add validation', () {
    testWidgets('rapid double-tap on Save creates exactly one transaction',
        (tester) async {
      final before = await tester
          .runAsync(() => YaadDb.txns(query: 'FlowDoubleTap Store'));
      await pumpHost(tester, const ConfirmScreen());
      await tester.enterText(find.byType(TextField).first, '500');
      await tester.enterText(
          find.byType(TextField).at(1), 'FlowDoubleTap Store');
      await tester.pumpAndSettle();
      // Two taps in the same frame - the second must hit the guard,
      // not the database.
      await tester.scrollUntilVisible(find.text('Save'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.tap(find.text('Save'));
      await settleRealWork(tester);
      expect(find.byType(ConfirmScreen), findsNothing);
      final rows = await tester
          .runAsync(() => YaadDb.txns(query: 'FlowDoubleTap Store'));
      expect(rows!.length, before!.length + 1);
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('absurd amount is rejected with an explanation',
        (tester) async {
      final before = await tester
          .runAsync(() => YaadDb.txns(query: 'FlowHuge Store'));
      await pumpHost(tester, const ConfirmScreen());
      await tester.enterText(find.byType(TextField).first,
          '999999999999999999999999999');
      await tester.enterText(find.byType(TextField).at(1), 'FlowHuge Store');
      await tapInList(tester, find.text('Save'));
      await tester.pumpAndSettle();
      // Still on the form, told why, nothing written.
      expect(find.byType(ConfirmScreen), findsOneWidget);
      expect(find.text('That amount looks too big — please check it.'),
          findsOneWidget);
      final rows = await tester
          .runAsync(() => YaadDb.txns(query: 'FlowHuge Store'));
      expect(rows!.length, before!.length);
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('zero amount is rejected with an explanation',
        (tester) async {
      await pumpHost(tester, const ConfirmScreen());
      await tester.enterText(find.byType(TextField).first, '0');
      await tapInList(tester, find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmScreen), findsOneWidget);
      expect(find.text('Please enter an amount.'), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('very long merchant name does not overflow the form',
        (tester) async {
      await pumpHost(tester, const ConfirmScreen());
      await tester.enterText(find.byType(TextField).at(1),
          'A Very Long Merchant Name That Goes On And On And On 1234567890');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(minutes: 5));
    });
  });

  group('transaction view delete + missing files', () {
    testWidgets('delete removes the row and its recording, then pops',
        (tester) async {
      final audio = fakeAudio('flow_delete.m4a');
      final t = YaadTransaction(
        amount: 999,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.spend,
        rawMerchant: 'FlowDelete Store',
        audioPath: audio.path,
        voiceNote: 'bye',
      );
      await tester.runAsync(() => YaadDb.insertTxn(t));

      await pumpHost(
        tester,
        TransactionViewScreen(
          txn: t,
          names: const TxnDisplayNames(accountLabel: 'Meezan'),
        ),
      );
      await tester.tap(find.byKey(const Key('txnDeleteButton')));
      await tester.pumpAndSettle();
      expect(find.text('Delete this transaction?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await settleRealWork(tester);

      expect(find.byType(TransactionViewScreen), findsNothing);
      expect(await tester.runAsync(() => YaadDb.txnById(t.id)), isNull);
      expect(audio.existsSync(), isFalse);
    });

    testWidgets('receipt path with a missing file hides the section',
        (tester) async {
      final t = YaadTransaction(
        amount: 150,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.spend,
        rawMerchant: 'FlowNoReceipt Store',
        receiptPath: p.join(tmpDir.path, 'gone.jpg'),
      );
      await pumpHost(
        tester,
        TransactionViewScreen(
          txn: t,
          names: const TxnDisplayNames(accountLabel: 'Meezan'),
        ),
      );
      expect(find.byKey(const Key('txnHero')), findsOneWidget);
      expect(find.byKey(const Key('txnReceipt')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'nameless transaction: hero title is the purpose, never the kind word',
        (tester) async {
      final t = YaadTransaction(
        amount: 320,
        dateTime: DateTime(2026, 10, 1),
        kind: TxnKind.spend,
        purpose: 'groceries',
        // No rawMerchant and no alias — the case from the screenshot.
      );
      await pumpHost(
        tester,
        TransactionViewScreen(
          txn: t,
          names: const TxnDisplayNames(accountLabel: 'Meezan'),
        ),
      );
      final hero = find.byKey(const Key('txnHero'));
      // Title falls back to the purpose name…
      expect(
          find.descendant(of: hero, matching: find.text('Groceries')),
          findsOneWidget);
      // …never the kind word (it lives in the chip row + app bar).
      expect(find.descendant(of: hero, matching: find.text('Spent')),
          findsNothing);
    });
  });

  group('purpose dialog + grid', () {
    testWidgets('blank purpose name cannot be submitted; long name capped',
        (tester) async {
      String? result = 'unset';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  result =
                      await promptCustomPurposeName(context, Strings('en'));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      // Add starts disabled while the field is blank.
      final addButton = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Add'));
      expect(addButton.onPressed, isNull);

      // Typing enables it; the field caps the name at the tile-safe
      // limit instead of accepting an unbounded label.
      await tester.enterText(find.byType(TextField), 'x' * 45);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text.length, maxPurposeNameLength);
      final addEnabled = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Add'));
      expect(addEnabled.onPressed, isNotNull);

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(result, 'x' * maxPurposeNameLength);
    });

    testWidgets('very long purpose label ellipsizes instead of overflowing',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PurposeGrid(
              purposes: [
                Purpose('custom_long',
                    'A very very long custom purpose name indeed', Icons.tag),
              ],
              selected: 'uncategorized',
              onSelect: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final label = tester.widget<Text>(find
          .text('A very very long custom purpose name indeed'));
      expect(label.maxLines, 2);
      expect(label.overflow, TextOverflow.ellipsis);
    });
  });

  group('saved-outside-period message (user-reported)', () {
    // Today is October 2026 and the default period is thisMonth.
    testWidgets('save dated last month says where it went', (tester) async {
      await pumpHost(
        tester,
        ConfirmScreen(
          initial: OcrResult(
            rawText: '',
            amount: 400,
            merchant: 'FlowPeriodPast Store ${DateTime.now().microsecondsSinceEpoch}',
            date: DateTime(2026, 9, 15),
          ),
        ),
      );
      await tapInList(tester, find.text('Save'));
      await settleRealWork(tester);
      expect(find.byType(ConfirmScreen), findsNothing);
      expect(find.text('Saved in September'), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('save dated inside the period shows no extra message',
        (tester) async {
      await pumpHost(
        tester,
        ConfirmScreen(
          initial: OcrResult(
            rawText: '',
            amount: 400,
            merchant: 'FlowPeriodNow Store ${DateTime.now().microsecondsSinceEpoch}',
            date: DateTime(2026, 10, 1),
          ),
        ),
      );
      await tapInList(tester, find.text('Save'));
      await settleRealWork(tester);
      expect(find.byType(ConfirmScreen), findsNothing);
      expect(find.text('Saved in October'), findsNothing);
      await tester.pump(const Duration(minutes: 5));
    });
  });

  group('add account from the picker (user-reported)', () {
    Finder dialogSave() => find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Save'));
    Finder dialogField() => find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));

    testWidgets(
        'create + select mid-entry; form state preserved; saved to DB',
        (tester) async {
      await pumpHost(tester, const ConfirmScreen());
      await settleRealWork(tester); // let the account chips load
      expect(find.byKey(const Key('addAccountChip')), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Meezan'), findsOneWidget);

      // Fill the form FIRST — creating an account must not disturb
      // amount, merchant, or purpose.
      await tester.enterText(find.byType(TextField).first, '750');
      await tester.enterText(
          find.byType(TextField).at(1), 'FlowNewAcct Store');
      await tapInList(tester, find.text('Food'));
      await tester.pumpAndSettle();

      await tapInList(tester, find.byKey(const Key('addAccountChip')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(dialogField().first, 'HBL Flow');
      // The optional opening-balance field takes an amount without
      // disturbing the create flow (blank would mean 0).
      await tester.enterText(dialogField().at(1), '5000');
      await tester.tap(dialogSave());
      await settleRealWork(tester);
      expect(find.byType(AlertDialog), findsNothing);

      // The new account's chip is there and selected for this entry.
      final chip = tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'HBL Flow'));
      expect(chip.selected, isTrue);
      // Everything typed/chosen before the dialog is still there.
      expect(
          tester.widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          '750');
      expect(
          tester.widget<TextField>(find.byType(TextField).at(1))
              .controller!
              .text,
          'FlowNewAcct Store');

      // Saving lands the entry in the new account…
      await tapInList(tester, find.text('Save'));
      await settleRealWork(tester);
      expect(find.byType(ConfirmScreen), findsNothing);
      // …and the account is a real DB row (Settings list and the
      // Activity filter read the same table).
      final accounts = await tester.runAsync(() => YaadDb.accounts());
      final created = accounts!.firstWhere((a) => a.name == 'HBL Flow');
      final rows = await tester
          .runAsync(() => YaadDb.txns(query: 'FlowNewAcct Store'));
      expect(rows!.length, 1);
      expect(rows.first.accountId, created.id);
      expect(rows.first.amount, 750);
      expect(rows.first.purpose, 'food');
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('duplicate name selects the existing account, creates nothing',
        (tester) async {
      final before = await tester.runAsync(() => YaadDb.accounts());
      if (!before!.any((a) => a.name == 'Dupe Flow')) {
        await tester.runAsync(() => YaadDb.insertAccount('Dupe Flow'));
      }
      final countBefore =
          (await tester.runAsync(() => YaadDb.accounts()))!.length;

      await pumpHost(tester, const ConfirmScreen());
      await settleRealWork(tester);
      await tapInList(tester, find.byKey(const Key('addAccountChip')));
      await tester.pumpAndSettle();
      await tester.enterText(dialogField().first, 'dupe flow'); // case differs
      await tester.tap(dialogSave());
      await settleRealWork(tester);

      expect(find.text('That account already exists'), findsOneWidget);
      final chip = tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Dupe Flow'));
      expect(chip.selected, isTrue);
      final countAfter =
          (await tester.runAsync(() => YaadDb.accounts()))!.length;
      expect(countAfter, countBefore);
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('blank name is rejected with a message, creates nothing',
        (tester) async {
      final countBefore =
          (await tester.runAsync(() => YaadDb.accounts()))!.length;
      await pumpHost(tester, const ConfirmScreen());
      await settleRealWork(tester);
      await tapInList(tester, find.byKey(const Key('addAccountChip')));
      await tester.pumpAndSettle();
      await tester.enterText(dialogField().first, '   ');
      await tester.tap(dialogSave());
      await settleRealWork(tester);

      expect(find.text('Give the account a name first.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      final countAfter =
          (await tester.runAsync(() => YaadDb.accounts()))!.length;
      expect(countAfter, countBefore);
      await tester.pump(const Duration(minutes: 5));
    });
  });

  group('end-of-scroll clearance (floating-UI class)', () {
    // The user's build-24 screenshot: Home's floating "+ Add" button
    // overlapped the last Recent card because the scroll content had
    // no bottom clearance. These tests pin the same property on the
    // capture/detail screens: at max scroll, the last element is
    // fully visible AND ends with real clearance above whatever sits
    // at the screen's bottom edge (keyboard, gesture bar, edge).
    testWidgets(
        'confirm: Save actions clear the keyboard edge at max scroll',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.reset);
      appState.settings = const AppSettings();
      await tester.pumpWidget(
          const MaterialApp(home: ConfirmScreen()));
      await tester.pumpAndSettle();

      for (var i = 0; i < 3; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -1200));
        await tester.pumpAndSettle();
      }
      const keyboardTop = 640 - 280;
      final saveRect = tester.getRect(find.text('Save'));
      expect(saveRect.bottom, lessThanOrEqualTo(keyboardTop));
      expect(saveRect.top, greaterThanOrEqualTo(56)); // below the AppBar
      final lastRect = tester.getRect(find.text('Save without note'));
      expect(lastRect.bottom, lessThanOrEqualTo(keyboardTop));
      // The actual clearance: the last action must not kiss the edge.
      expect(keyboardTop - lastRect.bottom, greaterThanOrEqualTo(24));
      await tester.pump(const Duration(minutes: 5));
      // Unmount fully before the metrics reset: a deactivated
      // EditableText's metrics observer otherwise fires during the
      // NEXT test's view changes and fails it.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('view: last section fully visible with clearance at max scroll',
        (tester) async {
      tester.view.physicalSize = const Size(360, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final t = YaadTransaction(
        amount: 2500,
        dateTime: DateTime(2026, 10, 1, 14, 30),
        kind: TxnKind.spend,
        rawMerchant: 'FlowClearance Diner',
        purpose: 'food',
        note: 'team lunch',
        voiceNote: 'doodh bhi lena hai',
        audioPath: '/tmp/voice_clearance.m4a',
        bankReference: 'REF-CLEARANCE-1',
      );
      await pumpHost(
        tester,
        TransactionViewScreen(
          txn: t,
          names: const TxnDisplayNames(accountLabel: 'Meezan'),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -1200));
        await tester.pumpAndSettle();
      }
      // Bank reference is the last section: fully on screen, and its
      // bottom edge keeps real clearance from the screen's bottom.
      final refRect =
          tester.getRect(find.byKey(const Key('txnBankRef')));
      expect(refRect.bottom, lessThanOrEqualTo(560));
      expect(560 - refRect.bottom, greaterThanOrEqualTo(32));
      expect(tester.takeException(), isNull);
    });
  });

  group('receipt note separation (user-reported)', () {
    testWidgets(
        'IBFT scan: note stays empty; reference saved as bank reference',
        (tester) async {
      await pumpHost(
        tester,
        ConfirmScreen(
          initial: OcrResult(
            rawText: '',
            amount: 8000,
            recipient: 'Fatima Khan',
            merchant: 'Fatima Khan',
            sender: 'Ali Raza',
            reference: '534946',
            transactionType: 'ibft',
            transactionTypeRaw: '1LINK IBFT',
            date: DateTime(2026, 9, 28, 17, 7),
          ),
        ),
      );
      // The person field carries the printed recipient name…
      expect(
          tester
              .widget<TextField>(find.byType(TextField).at(1))
              .controller!
              .text,
          'Fatima Khan');
      // …and the note field is EMPTY — not "Ref 534946 · 1LINK IBFT".
      await revealInList(tester, find.byType(NoteField));
      final note = tester.widget<NoteField>(find.byType(NoteField));
      expect(note.controller.text, '');

      await tapInList(tester, find.text('Save'));
      await settleRealWork(tester);
      expect(find.byType(ConfirmScreen), findsNothing);
      final rows = await tester
          .runAsync(() => YaadDb.txns(query: 'Fatima Khan'));
      final saved =
          rows!.where((t) => t.bankReference == '534946').toList();
      expect(saved, isNotEmpty);
      expect(saved.first.note, '');
      expect(saved.first.rawMerchant, 'Fatima Khan');
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets('a genuine description prefills the note', (tester) async {
      await pumpHost(
        tester,
        ConfirmScreen(
          initial: OcrResult(
            rawText: '',
            amount: 25000,
            recipient: 'Landlord Flow',
            merchant: 'Landlord Flow',
            description: 'Monthly rent for October',
            reference: '777001',
            date: DateTime(2026, 10, 1),
          ),
        ),
      );
      await revealInList(tester, find.byType(NoteField));
      final note = tester.widget<NoteField>(find.byType(NoteField));
      expect(note.controller.text, 'Monthly rent for October');
      await tester.pump(const Duration(minutes: 5));
    });
  });

  group('ocr empty result', () {
    test('text with nothing extractable parses as an empty result', () {
      // This is the input captureImage's new "nothing found" branch
      // keys on: OCR succeeded but there is nothing to prefill.
      final r = OcrService()
          .parseText('a photo of a cat sitting on a wall in the garden');
      expect(r.isEmpty, isTrue);
      expect(r.amount, isNull);
    });
  });
}
