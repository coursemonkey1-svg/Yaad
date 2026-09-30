import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/widgets/guided_tour.dart';

/// Minimal harness that mimics MainShell's tour wiring: auto-show once
/// after onboarding, persist `tourSeen` on finish.
class _TourHarness extends StatefulWidget {
  final AppSettings initial;
  const _TourHarness({required this.initial});

  @override
  State<_TourHarness> createState() => _TourHarnessState();
}

class _TourHarnessState extends State<_TourHarness> {
  late AppSettings settings = widget.initial;
  final _targetKey = GlobalKey();
  var tourShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowTour());
  }

  void _maybeShowTour() {
    if (!GuidedTour.shouldShow(settings)) return;
    tourShown = true;
    GuidedTour.show(
      context,
      steps: [
        TourStep(
            targetKey: _targetKey,
            tab: 0,
            titleKey: 'tourAddTitle',
            bodyKey: 'tourAddBody',
            hintKey: 'tourAddHint'),
        const TourStep(
            tab: 0, titleKey: 'tourHomeTitle', bodyKey: 'tourHomeBody'),
      ],
      strings: const Strings('en'),
      onFinish: () =>
          setState(() => settings = settings.copyWith(tourSeen: true)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: _targetKey,
          onPressed: () {},
          child: const Text('target'),
        ),
      ),
    );
  }
}

_TourHarnessState _state(WidgetTester tester) =>
    tester.state<_TourHarnessState>(find.byType(_TourHarness));

Future<void> _pumpHarness(
        WidgetTester tester, AppSettings initial) async =>
    tester.pumpWidget(
        MaterialApp(home: _TourHarness(initial: initial)));

void main() {
  group('GuidedTour.shouldShow', () {
    test('true only after onboarding and before the tour was seen', () {
      expect(
          GuidedTour.shouldShow(
              const AppSettings(onboardingDone: true)),
          isTrue);
      expect(
          GuidedTour.shouldShow(const AppSettings(
              onboardingDone: true, tourSeen: true)),
          isFalse);
      expect(GuidedTour.shouldShow(const AppSettings()), isFalse);
    });
  });

  group('tour overlay', () {
    testWidgets('auto-shows on first post-onboarding launch',
        (tester) async {
      await _pumpHarness(
          tester, const AppSettings(onboardingDone: true));
      await tester.pumpAndSettle();

      expect(_state(tester).tourShown, isTrue);
      // First step caption + hint + controls are visible.
      expect(find.text('Start here: Add'), findsOneWidget);
      expect(find.text('Try it after the tour — it takes 10 seconds.'),
          findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
      expect(find.text('Step 1 of 2'), findsOneWidget);
    });

    testWidgets('skip marks tourSeen and removes the overlay',
        (tester) async {
      await _pumpHarness(
          tester, const AppSettings(onboardingDone: true));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(find.text('Start here: Add'), findsNothing);
      expect(_state(tester).settings.tourSeen, isTrue);
    });

    testWidgets('next and back move between steps', (tester) async {
      await _pumpHarness(
          tester, const AppSettings(onboardingDone: true));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Home: your month at a glance'), findsOneWidget);
      expect(find.text('Step 2 of 2'), findsOneWidget);
      // Last step offers Done instead of Next.
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Next'), findsNothing);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Start here: Add'), findsOneWidget);
    });

    testWidgets('done on the last step finishes the tour',
        (tester) async {
      await _pumpHarness(
          tester, const AppSettings(onboardingDone: true));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.text('Home: your month at a glance'), findsNothing);
      expect(_state(tester).settings.tourSeen, isTrue);
    });

    testWidgets('does not show once tourSeen is set', (tester) async {
      await _pumpHarness(tester,
          const AppSettings(onboardingDone: true, tourSeen: true));
      await tester.pumpAndSettle();

      expect(_state(tester).tourShown, isFalse);
      expect(find.text('Skip'), findsNothing);
    });

    testWidgets('does not show before onboarding is done',
        (tester) async {
      await _pumpHarness(tester, const AppSettings());
      await tester.pumpAndSettle();

      expect(_state(tester).tourShown, isFalse);
      expect(find.text('Skip'), findsNothing);
    });
  });

  group('localization', () {
    test('every English tour key has a Urdu translation', () {
      expect(Strings.urduComplete, isTrue);
      const t = Strings('ur');
      for (final k in [
        'tourAddTitle',
        'tourAddBody',
        'tourAddHint',
        'tourHomeTitle',
        'tourHomeBody',
        'tourActivityTitle',
        'tourActivityBody',
        'tourUdhaarTitle',
        'tourUdhaarBody',
        'tourSettingsTitle',
        'tourSettingsBody',
        'tourSkip',
        'tourNext',
        'tourBack',
        'tourDone',
        'tourStepOf',
        'tourReplay',
        'tourReplaySub',
      ]) {
        expect(t.get(k), isNotEmpty, reason: k);
      }
    });
  });
}
