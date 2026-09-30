import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/screens/settings.dart';

/// Widget tests for the first-run restricted-settings guide: on sideloaded
/// builds the phone blocks bank SMS / notification capture until the user
/// allows restricted settings once, so the first toggle-ON shows a Yaad
/// dialog explaining the one phone setting needed.
Future<void> _pumpSettings(WidgetTester tester) async {
  appState.settings = const AppSettings();
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: SettingsScreen())),
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(
    find.text(label),
    500,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _flipSmsOn(WidgetTester tester) async {
  await _scrollTo(tester, 'Bank SMS alerts');
  await tester.tap(find.text('Bank SMS alerts'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  group('permission guide', () {
    testWidgets('first SMS toggle-ON shows the guide dialog',
        (tester) async {
      await _pumpSettings(tester);
      await _flipSmsOn(tester);

      expect(find.text('One phone setting first'), findsOneWidget);
      expect(find.text('Open phone settings'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(find.textContaining('Allow restricted settings'),
          findsOneWidget);

      // "Not now" dismisses; the toggle stays off; the guide is marked seen.
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('One phone setting first'), findsNothing);
      expect(appState.settings.smsCapture, isFalse);
      expect(appState.settings.smsGuideSeen, isTrue);
    });

    testWidgets('guide does not show on second toggle-ON', (tester) async {
      await _pumpSettings(tester);
      await _flipSmsOn(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      // Second attempt: no guide — straight to the existing rationale.
      await _flipSmsOn(tester);
      expect(find.text('One phone setting first'), findsNothing);
      expect(find.text('Turn on bank SMS capture?'), findsOneWidget);
    });

    testWidgets('first notification toggle-ON shows the guide too',
        (tester) async {
      await _pumpSettings(tester);
      await _scrollTo(tester, 'Bank notifications');
      await tester.tap(find.text('Bank notifications'));
      await tester.pumpAndSettle();

      expect(find.text('One phone setting first'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      // Flags are per capture type.
      expect(appState.settings.notifGuideSeen, isTrue);
      expect(appState.settings.smsGuideSeen, isFalse);
      expect(appState.settings.notificationCapture, isFalse);
    });

    test('Urdu has every permission-guide key', () {
      const keys = [
        'permGuideTitle',
        'permGuideBody',
        'permGuideStep1',
        'permGuideStep2',
        'permGuideStep3',
        'permGuideOpen',
      ];
      final ur = Strings('ur');
      for (final k in keys) {
        expect(ur.get(k), isNot(equals(k)),
            reason: 'missing Urdu string for $k');
      }
      expect(Strings.urduComplete, isTrue);
    });
  });
}
