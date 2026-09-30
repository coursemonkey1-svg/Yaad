import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/widgets/guided_tour.dart';

/// Regression tests for the stacked-tours bug: on first launch TWO
/// guided tours popped up on top of each other (the onboarding→main
/// handoff fired the tour twice). [GuidedTour.show] must be idempotent
/// while a tour is already showing, and the guard must reset when the
/// tour finishes so Settings → "Take the tour" keeps working.
List<TourStep> _steps() => const [
      TourStep(tab: 0, titleKey: 'tourAddTitle', bodyKey: 'tourAddBody'),
      TourStep(tab: 0, titleKey: 'tourHomeTitle', bodyKey: 'tourHomeBody'),
    ];

/// Pumps a bare host and returns a BuildContext under a Navigator.
Future<BuildContext> _pumpHost(WidgetTester tester) async {
  BuildContext? ctx;
  await tester.pumpWidget(MaterialApp(
    home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold(body: Text('home'));
    }),
  ));
  await tester.pumpAndSettle();
  return ctx!;
}

Future<void> _show(BuildContext ctx, {VoidCallback? onFinish}) =>
    GuidedTour.show(
      ctx,
      steps: _steps(),
      strings: const Strings('en'),
      onFinish: onFinish ?? () {},
    );

void main() {
  group('GuidedTour.show single-show guard', () {
    testWidgets('two rapid show() calls push exactly one tour route',
        (tester) async {
      final ctx = await _pumpHost(tester);

      // Fire twice before the first tour completes — the exact shape of
      // the double-handoff bug. Both callers share the in-flight tour.
      final first = _show(ctx);
      final second = _show(ctx);
      expect(identical(first, second), isTrue);
      await tester.pumpAndSettle();

      // With two stacked routes there would be two "Step 1 of 2" cards.
      expect(find.text('Step 1 of 2'), findsOneWidget);
    });

    testWidgets('the guard resets once the tour finishes', (tester) async {
      final ctx = await _pumpHost(tester);

      var finished = 0;
      _show(ctx, onFinish: () => finished++);
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 2'), findsOneWidget);

      // Finish the tour: Next to the last step, then Done.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(finished, 1);
      expect(find.text('Step 1 of 2'), findsNothing);

      // Guard reset: a fresh tour shows again (this is what Settings →
      // "Take the tour" relies on).
      _show(ctx);
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 2'), findsOneWidget);
    });
  });
}
