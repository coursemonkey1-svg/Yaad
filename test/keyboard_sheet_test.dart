import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/screens/capture.dart';

/// The capture sheet autofocuses the amount field, so the keyboard is up the
/// moment it opens. Regression tests for the keyboard-covering-the-form bug:
/// the sheet must lift by the keyboard height (viewInsets) and scroll, so
/// every control stays reachable on a small phone screen.
Future<void> _pumpSheet(WidgetTester tester, {double keyboard = 0}) async {
  appState.settings = const AppSettings();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          // Fake the open keyboard: keep the real screen size, override
          // only the bottom view inset.
          data: MediaQuery.of(context)
              .copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
          // resizeToAvoidBottomInset off: the real sheet lives in a
          // bottom-sheet route, not a Scaffold body, so the Scaffold must
          // not consume the inset a second time here.
          child: const Scaffold(
            resizeToAvoidBottomInset: false,
            body: QuickCaptureSheet(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The padding that lifts the sheet above the keyboard: the Padding wrapping
/// the sheet's SafeArea.
Padding _keyboardPadding(WidgetTester tester) {
  final finder = find.ancestor(
    of: find.byType(SafeArea),
    matching: find.byType(Padding),
  );
  expect(finder, findsOneWidget);
  return tester.widget<Padding>(finder);
}

void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  group('QuickCaptureSheet keyboard safety', () {
    testWidgets('bottom padding tracks the keyboard height', (tester) async {
      await _pumpSheet(tester, keyboard: 280);
      final pad = _keyboardPadding(tester);
      expect((pad.padding as EdgeInsets).bottom, 280);
    });

    testWidgets('no bottom padding when the keyboard is closed',
        (tester) async {
      await _pumpSheet(tester);
      final pad = _keyboardPadding(tester);
      expect((pad.padding as EdgeInsets).bottom, 0);
    });

    testWidgets('sheet content is scrollable', (tester) async {
      await _pumpSheet(tester, keyboard: 280);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('every control reachable with the keyboard up', (tester) async {
      await _pumpSheet(tester, keyboard: 280);

      // Amount field, all four intents, and the scan-receipt button.
      expect(find.byType(TextField), findsOneWidget);
      const labels = [
        'I spent',
        'I received',
        'I lent',
        'I borrowed',
        'Scan receipt',
      ];
      for (final label in labels) {
        expect(find.text(label), findsOneWidget);
      }

      // Each one can be scrolled into view above the keyboard.
      final scrollable = find.byType(SingleChildScrollView);
      for (final label in labels) {
        await tester.scrollUntilVisible(find.text(label), 200,
            scrollable: scrollable);
        expect(find.text(label), findsOneWidget);
      }
    });
  });
}
