import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/widgets/purpose_grid.dart';
import 'package:yaad/models/purposes.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)));

  testWidgets('renders every purpose and selects on tap', (tester) async {
    String? tapped;
    await tester.pumpWidget(wrap(PurposeGrid(
      purposes: kPurposes,
      selected: 'uncategorized',
      onSelect: (p) => tapped = p,
    )));

    // Every purpose label is visible.
    for (final p in kPurposes) {
      expect(find.text(p.label), findsOneWidget);
    }

    await tester.tap(find.text('Groceries'));
    expect(tapped, 'groceries');
  });

  testWidgets('shows suggestion banner and tapping it selects', (tester) async {
    String? tapped;
    await tester.pumpWidget(wrap(PurposeGrid(
      purposes: kPurposes,
      selected: 'uncategorized',
      onSelect: (p) => tapped = p,
      suggested: 'food',
      suggestionReason: 'You chose "food" here 3 times before',
    )));

    expect(find.text('Suggested: Food'), findsOneWidget);
    expect(find.text('You chose "food" here 3 times before'),
        findsOneWidget);

    await tester.tap(find.text('Use'));
    expect(tapped, 'food');
  });

  testWidgets('no banner when suggestion equals selected', (tester) async {
    await tester.pumpWidget(wrap(PurposeGrid(
      purposes: kPurposes,
      selected: 'food',
      onSelect: (_) {},
      suggested: 'food',
    )));
    expect(find.textContaining('Suggested:'), findsNothing);
  });
}
