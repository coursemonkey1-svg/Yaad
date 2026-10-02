import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/screens/accounts.dart';
import 'package:yaad/screens/aliases.dart';
import 'package:yaad/widgets/export_range_dialog.dart';

/// Accounts, Aliases and the export range dialog (audit areas 6–8).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('yaad_flow_acct');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
    await YaadDb.db; // create + seed accounts
  });

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    appState.settings = const AppSettings();
    await tester.pumpWidget(MaterialApp(home: screen));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('AccountsScreen', () {
    testWidgets('deleting the LAST account is blocked', (tester) async {
      // Reduce to a single account through the real delete path.
      await YaadDb.deleteAccount('savings', reassignTo: 'meezan');
      await YaadDb.deleteAccount('cash', reassignTo: 'meezan');
      expect((await YaadDb.accounts()).length, 1);

      await pumpScreen(tester, const AccountsScreen());
      expect(find.text('Meezan'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.delete_outline));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Keep at least one account.'), findsOneWidget);
      expect((await YaadDb.accounts()).length, 1);
    });

    testWidgets('renaming to the same name is a no-op (seed stays localised)',
        (tester) async {
      final before = await YaadDb.accountById('meezan');
      expect(before!.customName, isFalse);

      await pumpScreen(tester, const AccountsScreen());
      // The first row is always Meezan (oldest seed).
      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      // The field is prefilled with the stored name — just hit Save.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final after = await YaadDb.accountById('meezan');
      expect(after!.customName, isFalse,
          reason: 'an unchanged rename must not freeze the localised label');
      expect(after.name, 'Meezan');
    });

    testWidgets('a real rename sticks and duplicate names are refused',
        (tester) async {
      await pumpScreen(tester, const AccountsScreen());
      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'My Bank');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final renamed = await YaadDb.accountById('meezan');
      expect(renamed!.name, 'My Bank');
      expect(renamed.customName, isTrue);
      expect(find.text('My Bank'), findsWidgets);

      // Adding another account with the same name (any case) is refused.
      final countBefore = (await YaadDb.accounts()).length;
      await tester.tap(find.text('Add account'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'my bank');
      await tester.tap(find.text('Save'));
      // Snackbars queue: the "Renamed…" one is still showing, so the
      // refusal appears only after it clears. Pump (fake) time until
      // it shows up instead of guessing a fixed wait.
      var shown = false;
      for (var i = 0; i < 240 && !shown; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        shown = find
            .text('That account already exists')
            .evaluate()
            .isNotEmpty;
      }
      expect(shown, isTrue,
          reason: 'the duplicate-name refusal snackbar should appear');
      expect((await YaadDb.accounts()).length, countBefore);
    });
  });

  group('AliasesScreen', () {
    setUp(() async {
      final d = await YaadDb.db;
      await d.delete('aliases');
    });

    /// Manual pumps: the aliases list reloads behind a spinner after
    /// every change, so pumpAndSettle would never settle.
    Future<void> settleShort(WidgetTester tester) async {
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('long-press deletes an alias after confirming',
        (tester) async {
      await YaadDb.upsertAlias('RAW BANK XYZ', 'My Shop');
      await pumpScreen(tester, const AliasesScreen());
      expect(find.text('My Shop'), findsOneWidget);

      await tester.longPress(find.text('My Shop'));
      await settleShort(tester);
      expect(find.text('Delete this name?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await settleShort(tester);

      expect(await YaadDb.allAliases(), isEmpty);
      expect(find.text('No saved names yet.'), findsOneWidget);
    });

    testWidgets('saving with an empty field explains instead of vanishing',
        (tester) async {
      await pumpScreen(tester, const AliasesScreen());
      await tester.tap(find.byType(FloatingActionButton));
      await settleShort(tester);
      await tester.tap(find.text('Save'));
      await settleShort(tester);
      expect(find.text('Fill in both the bank label and your name.'),
          findsOneWidget);
      expect(await YaadDb.allAliases(), isEmpty);
    });

    testWidgets('editing the bank label moves the alias, no duplicate',
        (tester) async {
      await YaadDb.upsertAlias('OLD LABEL', ' Corner shop ');
      await pumpScreen(tester, const AliasesScreen());
      await tester.tap(find.text('Corner shop'));
      await settleShort(tester);
      final fields = find.byType(TextField);
      await tester.enterText(fields.first, 'NEW LABEL');
      await tester.tap(find.text('Save'));
      await settleShort(tester);

      final all = await YaadDb.allAliases();
      expect(all.length, 1);
      expect(all.first.rawName, 'NEW LABEL');
      expect(all.first.alias, 'Corner shop');
    });
  });

  group('Export range dialog', () {
    testWidgets('custom range: from-after-to is shown and blocks export',
        (tester) async {
      ExportRange? result;
      var returned = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => FilledButton(
              onPressed: () async {
                result = await showExportRangeDialog(ctx);
                returned = true;
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Pick a date range'), findsOneWidget);

      await tester.tap(find.text('Custom range…'));
      await tester.pumpAndSettle();

      Future<void> pickDate(String buttonLabel, String typed) async {
        await tester.tap(find.text(buttonLabel));
        await tester.pumpAndSettle();
        // Switch the date picker to typed input and enter the date.
        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, typed);
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }

      // From = 2 Oct 2026, To = 1 Oct 2026 → invalid.
      await pickDate('From', '10/02/2026');
      await pickDate('To', '10/01/2026');
      expect(find.textContaining('is after'), findsOneWidget);
      final exportBtn = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Export'));
      expect(exportBtn.onPressed, isNull);
      expect(returned, isFalse);

      // Fix the To date (its button now shows 01/10/2026 in dmy) →
      // the error clears and export works.
      await pickDate('01/10/2026', '10/03/2026');
      expect(find.textContaining('is after'), findsNothing);
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(result, isNotNull);
      expect(result!.from!.day, 2);
      expect(result!.to!.day, 3);
      expect(result!.fileLabel, '2026-10-02_to_2026-10-03');
    });
  });
}
