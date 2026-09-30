import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/lending.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/screens/udhaar.dart';

/// Widget tests for the Udhaar tap-to-filter balance cards: tapping
/// "People owe you" / "You owe" filters the people list, tapping the
/// active card again clears, and the filter combines with search.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    // Fresh database for this file (each test file runs isolated).
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'yaad.db');
    try {
      await File(path).delete();
    } catch (_) {}

    final ahmed = Person(name: 'Ahmed');
    final sara = Person(name: 'Sara');
    await YaadDb.insertPerson(ahmed);
    await YaadDb.insertPerson(sara);
    // Ahmed owes Inzimam; Inzimam owes Sara.
    await YaadDb.insertLending(LendingRecord(
      personId: ahmed.id,
      originalAmount: 2000,
      date: DateTime.now(),
      isOwedToMe: true,
    ));
    await YaadDb.insertLending(LendingRecord(
      personId: sara.id,
      originalAmount: 500,
      date: DateTime.now(),
      isOwedToMe: false,
    ));
  });

  Future<void> pumpUdhaar(WidgetTester tester) async {
    appState.settings = const AppSettings();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UdhaarScreen())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapping "People owe you" filters to debtors', (tester) async {
    await pumpUdhaar(tester);
    expect(find.text('Ahmed'), findsOneWidget);
    expect(find.text('Sara'), findsOneWidget);

    await tester.tap(find.text('People owe you'));
    await tester.pumpAndSettle();

    expect(find.text('Ahmed'), findsOneWidget);
    expect(find.text('Sara'), findsNothing);
  });

  testWidgets('tapping the active card again clears the filter',
      (tester) async {
    await pumpUdhaar(tester);

    await tester.tap(find.text('You owe'));
    await tester.pumpAndSettle();
    expect(find.text('Sara'), findsOneWidget);
    expect(find.text('Ahmed'), findsNothing);

    await tester.tap(find.text('You owe'));
    await tester.pumpAndSettle();
    expect(find.text('Ahmed'), findsOneWidget);
    expect(find.text('Sara'), findsOneWidget);
  });

  testWidgets('search combines with the direction filter', (tester) async {
    await pumpUdhaar(tester);

    await tester.tap(find.text('People owe you'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sara');
    await tester.pumpAndSettle();

    // Sara is excluded by the direction filter even though she matches search.
    expect(find.text('Ahmed'), findsNothing);
    expect(find.text('Sara'), findsNothing);
    expect(find.text('Clear filter'), findsOneWidget);

    // Clearing the filter keeps the search: Sara matches "sara" again.
    await tester.tap(find.text('Clear filter'));
    await tester.pumpAndSettle();
    expect(find.text('Sara'), findsOneWidget);
    expect(find.text('Ahmed'), findsNothing);
  });

  testWidgets('filter empty state tells you what to do', (tester) async {
    await pumpUdhaar(tester);

    await tester.tap(find.text('You owe'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ahmed');
    await tester.pumpAndSettle();

    expect(find.text('You owe nobody right now'), findsOneWidget);
    expect(find.textContaining('borrow money'), findsOneWidget);
    expect(find.text('Clear filter'), findsOneWidget);
  });

  test('urdu strings complete for the new filter keys', () {
    expect(Strings.urduComplete, isTrue);
    final ur = Strings('ur');
    expect(ur.get('filterOweYouEmptyTitle'),
        'ابھی آپ کو کچھ وصول نہیں کرنا ہے');
    expect(ur.get('filterYouOweEmptyTitle'),
        'ابھی آپ کو کچھ ادا نہیں کرنا ہے');
    expect(ur.get('clearFilter'), 'فلٹر صاف کریں');
  });
}
