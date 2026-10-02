import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/services/importer.dart';
import 'package:yaad/widgets/statement_import_wait.dart';

/// Bulletproofing for the statement-import wait (Settings → Import
/// statement). The flow used to show a non-dismissible infinite spinner
/// while `StatementImporter().parseFile` ran with no timeout — one hung
/// parse left the user trapped for minutes. These tests pin the fixes:
///
/// 1. Cancel dismisses the progress dialog and writes nothing.
/// 2. A hung parse times out, dismisses the dialog, shows the friendly
///    "couldn't read it" message, and writes nothing.
/// 3. A parse exception does the same and writes nothing.
///
/// The parse step is injected (`runStatementImport(..., parse: ...)`), so
/// tests drive it with mocks; production passes
/// `StatementImporter().parseFile`. The button in the test harness mirrors
/// `_importStatement`'s post-wait handling (cancel → back to settings,
/// anything else failed → friendly dialog).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    // NOTE: deliberately no deleteDatabase here. This file shares the
    // on-disk yaad.db with other test files running concurrently; deleting
    // it mid-suite breaks them ("no such table"). The "writes nothing"
    // assertions compare counts before/after within each test, which needs
    // no clean slate.
  });

  final s = Strings('en');

  /// Never completes: simulates the hung parse from the bug report.
  Future<ParsedStatement> hangParse(String path) =>
      Completer<ParsedStatement>().future;

  /// Throws immediately: simulates a corrupt/unreadable file.
  Future<ParsedStatement> throwParse(String path) async =>
      throw const FormatException('not a statement');

  /// Real sqlite I/O must run outside FakeAsync: wrap it in runAsync, or
  /// the test wedges at teardown (learned the hard way).
  Future<int> txnCount(WidgetTester tester) => tester
      .runAsync(() => YaadDb.txns(limit: 100000))
      .then((t) => t!.length);

  /// Test harness: a button that runs the real wait + the same follow-up
  /// `_importStatement` performs after the wait.
  Future<void> pumpHarness(
    WidgetTester tester, {
    required Future<ParsedStatement> Function(String) parse,
    required void Function(StatementImportResult) onResult,
    Duration timeout = const Duration(milliseconds: 100),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                final result = await runStatementImport(
                  context,
                  path: 'statement.pdf',
                  strings: s,
                  parse: parse,
                  timeout: timeout,
                );
                onResult(result);
                if (!context.mounted) return;
                if (result.outcome == StatementImportOutcome.cancelled) {
                  return;
                }
                if (result.outcome != StatementImportOutcome.ready ||
                    result.statement == null) {
                  await showImportReadFailedDialog(context, s);
                }
              },
              child: const Text('import'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('cancel dismisses the progress dialog and writes nothing',
      (tester) async {
    StatementImportResult? result;
    await pumpHarness(tester,
        parse: hangParse, onResult: (r) => result = r);

    final before = await txnCount(tester);

    await tester.tap(find.text('import'));
    // Manual pumps: the spinner never settles, so pumpAndSettle would hang.
    await tester.pump();
    await tester.pump();
    expect(find.text(s.get('importReading')), findsOneWidget);
    expect(find.text(s.get('cancel')), findsOneWidget);

    await tester.tap(find.text(s.get('cancel')));
    await tester.pumpAndSettle();

    expect(find.text(s.get('importReading')), findsNothing);
    expect(result?.outcome, StatementImportOutcome.cancelled);
    expect(await txnCount(tester), before);
  });

  testWidgets('timeout shows the friendly message and writes nothing',
      (tester) async {
    StatementImportResult? result;
    await pumpHarness(tester,
        parse: hangParse, onResult: (r) => result = r);

    final before = await txnCount(tester);

    await tester.tap(find.text('import'));
    await tester.pump();
    expect(find.text(s.get('importReading')), findsOneWidget);

    // Advance past the 100ms test timeout: the hung parse gives up.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(result?.outcome, StatementImportOutcome.timedOut);
    // Progress is gone; the plain-language message is up instead.
    expect(find.text(s.get('importReading')), findsNothing);
    expect(find.text(s.get('importReadFailTitle')), findsOneWidget);
    expect(find.text(s.get('importReadFailBody')), findsOneWidget);

    await tester.tap(find.text(s.get('gotIt')));
    await tester.pumpAndSettle();
    expect(find.text(s.get('importReadFailTitle')), findsNothing);

    expect(await txnCount(tester), before);
  });

  testWidgets('parse exception shows the friendly message and writes nothing',
      (tester) async {
    StatementImportResult? result;
    await pumpHarness(tester,
        parse: throwParse, onResult: (r) => result = r);

    final before = await txnCount(tester);

    await tester.tap(find.text('import'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(result?.outcome, StatementImportOutcome.failed);
    expect(find.text(s.get('importReading')), findsNothing);
    expect(find.text(s.get('importReadFailTitle')), findsOneWidget);
    expect(find.text(s.get('importReadFailBody')), findsOneWidget);

    await tester.tap(find.text(s.get('gotIt')));
    await tester.pumpAndSettle();
    expect(find.text(s.get('importReadFailTitle')), findsNothing);

    expect(await txnCount(tester), before);
  });

  testWidgets('android back button cancels the wait too', (tester) async {
    StatementImportResult? result;
    await pumpHarness(tester,
        parse: hangParse, onResult: (r) => result = r);

    await tester.tap(find.text('import'));
    await tester.pump();
    await tester.pump();
    expect(find.text(s.get('importReading')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text(s.get('importReading')), findsNothing);
    expect(result?.outcome, StatementImportOutcome.cancelled);
  });

  testWidgets('a good parse returns ready with the statement', (tester) async {
    final statement = const ParsedStatement(fileName: 'ok.csv');
    StatementImportResult? result;
    await pumpHarness(tester,
        parse: (_) async => statement, onResult: (r) => result = r);

    await tester.tap(find.text('import'));
    await tester.pumpAndSettle();

    expect(result?.outcome, StatementImportOutcome.ready);
    expect(identical(result?.statement, statement), isTrue);
    expect(find.text(s.get('importReading')), findsNothing);
    // No failure dialog for a good parse.
    expect(find.text(s.get('importReadFailTitle')), findsNothing);
  });
}
