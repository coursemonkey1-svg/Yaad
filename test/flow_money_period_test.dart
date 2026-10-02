import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:yaad/data/db.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/main.dart' as app;
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/screens/timeline.dart';
import 'package:yaad/services/app_state.dart';
import 'package:yaad/widgets/period_selector.dart';

/// The shared viewing period (v1.5): settings persistence, range
/// math under every period choice against a seeded multi-month
/// dataset, labels, the picker, and the Activity wiring.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    tzdata.initializeTimeZones();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('yaad_flow_period');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
  });

  setUp(() async {
    final d = await YaadDb.db;
    await d.delete('transactions');
  });

  AppState stateFor(String period) =>
      AppState()..settings = AppSettings(period: period);

  group('AppSettings.period persistence', () {
    test('defaults to thisMonth', () {
      expect(const AppSettings().period, 'thisMonth');
    });

    test('round-trips every value, including a picked month', () {
      for (final v in [
        'thisWeek',
        'thisMonth',
        'lastMonth',
        'thisYear',
        'allTime',
        'month:2025-03',
        'month:2024-12',
      ]) {
        final back = AppSettings.fromMap(
            AppSettings(period: v).toMap());
        expect(back.period, v, reason: v);
      }
    });

    test('garbage or missing values fall back to thisMonth', () {
      final garbage = const AppSettings().toMap()
        ..['period'] = 'lastDecade';
      expect(AppSettings.fromMap(garbage).period, 'thisMonth');
      final badMonth = const AppSettings().toMap()
        ..['period'] = 'month:2025-13';
      expect(AppSettings.fromMap(badMonth).period, 'thisMonth');
      final missing = const AppSettings().toMap()..remove('period');
      expect(AppSettings.fromMap(missing).period, 'thisMonth');
    });

    test('survives a real SharedPreferences save/load (restart)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final s1 = AppState();
      await s1.update(
          s1.settings.copyWith(period: 'month:2025-03'));
      final s2 = AppState();
      await s2.load();
      expect(s2.settings.period, 'month:2025-03');
    });
  });

  group('periodRangeMs against a seeded multi-month dataset', () {
    // Dataset (spends), built relative to "now" in the user tz:
    //   a: today                       100
    //   b: 1st of this month           10
    //   c: 15th of last month          200
    //   d: 15 Mar of last year         300
    //   e: 31 Dec of last year 23:59   400
    Future<void> seed() async {
      final st = stateFor('thisMonth');
      final n = st.nowInTz();
      final loc = n.location;
      Future<void> at(tz.TZDateTime when, double amount) =>
          YaadDb.insertTxn(YaadTransaction(
            amount: amount,
            dateTime: DateTime.fromMillisecondsSinceEpoch(
                when.millisecondsSinceEpoch),
            kind: TxnKind.spend,
            rawMerchant: 'SEEDED',
          ));
      await at(tz.TZDateTime(loc, n.year, n.month, n.day, 12), 100);
      await at(tz.TZDateTime(loc, n.year, n.month, 1, 12), 10);
      final lastMonth = tz.TZDateTime(loc, n.year, n.month - 1, 15, 12);
      await at(lastMonth, 200);
      await at(tz.TZDateTime(loc, n.year - 1, 3, 15, 12), 300);
      await at(tz.TZDateTime(loc, n.year - 1, 12, 31, 23, 59), 400);
      // Keep the "last month is in this year" fact for expectations.
      _lastMonthYear = lastMonth.year;
    }

    Future<double> spent(String period) async {
      final (fromMs, toMs) = stateFor(period).periodRangeMs();
      return YaadDb.sumSpent(fromMs, toMs);
    }

    test('each period choice sums the right rows', () async {
      await seed();
      final n = stateFor('thisMonth').nowInTz();
      expect(await spent('thisMonth'), 110); // a + b
      expect(await spent('lastMonth'),
          200 + (n.month == 1 ? 400 : 0)); // c (+ e in January)
      // thisYear = a + b, plus c when last month is in this year.
      final expectedYear = 110 + (_lastMonthYear == n.year ? 200 : 0);
      expect(await spent('thisYear'), expectedYear);
      expect(await spent('allTime'), 1010); // everything
      expect(await spent('month:${n.year - 1}-03'), 300); // d only
    });

    test('thisWeek starts on the chosen week-start day and includes today',
        () async {
      await seed();
      final st = stateFor('thisWeek');
      final (fromMs, toMs) = st.periodRangeMs();
      expect(fromMs, st.startOfWeekMs());
      expect(await YaadDb.sumSpent(fromMs, toMs),
          greaterThanOrEqualTo(100)); // today's row is always in
    });

    test('picked-month bounds are exact, leap years included', () {
      final st = stateFor('thisMonth');
      final (f24From, f24To) = st.periodRangeMs('month:2024-02');
      expect(f24To - f24From,
          29 * 24 * 3600 * 1000 - 1); // leap February
      final (f25From, f25To) = st.periodRangeMs('month:2025-02');
      expect(f25To - f25From, 28 * 24 * 3600 * 1000 - 1);
      // Dec → Jan boundary: consecutive months share a seam.
      final (decFrom, decTo) = st.periodRangeMs('month:2025-12');
      final (janFrom, _) = st.periodRangeMs('month:2026-01');
      expect(janFrom, decTo + 1);
      expect(decFrom, lessThan(decTo));
    });

    test('the default (no argument) uses the persisted period', () {
      final st = stateFor('month:2025-03');
      expect(st.periodRangeMs(), st.periodRangeMs('month:2025-03'));
    });
  });

  group('periodLabel', () {
    test('composes the heading noun for every period', () {
      final st = stateFor('thisMonth');
      final n = st.nowInTz();
      expect(st.periodLabel('month:2025-03'), 'March 2025');
      expect(st.periodLabel('month:2024-12'), 'December 2024');
      expect(st.periodLabel('allTime'), 'All time');
      expect(st.periodLabel('thisYear'), '${n.year}');
      expect(st.periodLabel('lastMonth'), 'Last month');
      expect(st.periodLabel('thisWeek'), 'This week');
      expect(st.periodLabel('thisMonth'),
          const Strings('en').monthFull(n.month));
    });

    test('labels exist in Urdu too', () {
      final ur = AppState()
        ..settings = const AppSettings(language: 'ur');
      expect(ur.periodLabel('allTime'), 'تمام عرصہ');
      expect(ur.periodLabel('lastMonth'), 'پچھلا مہینہ');
      expect(ur.periodLabel('month:2025-03'), 'مارچ 2025');
    });
  });

  group('picker logic', () {
    test('future months are not selectable', () {
      final now = DateTime(2026, 10, 15);
      expect(periodMonthSelectable(2026, 10, now), isTrue);
      expect(periodMonthSelectable(2026, 9, now), isTrue);
      expect(periodMonthSelectable(2025, 12, now), isTrue);
      expect(periodMonthSelectable(2026, 11, now), isFalse);
      expect(periodMonthSelectable(2027, 1, now), isFalse);
    });
  });

  group('PeriodSelector widget', () {
    testWidgets('choosing Last month persists and relabels',
        (tester) async {
      app.appState.settings = const AppSettings();
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: PeriodSelector())));
      await tester.pumpAndSettle();
      // The chip shows the current month name…
      await tester.tap(find.byType(PeriodSelector));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last month'));
      await tester.pumpAndSettle();
      expect(app.appState.settings.period, 'lastMonth');
      expect(find.text('Last month'), findsOneWidget);
    });

    testWidgets('Pick a month: future months disabled, past month sets period',
        (tester) async {
      app.appState.settings = const AppSettings();
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: PeriodSelector())));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PeriodSelector));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick a month…'));
      await tester.pumpAndSettle();
      expect(find.text('Pick a month…'), findsWidgets);

      final now = app.appState.nowInTz();
      if (now.month < 12) {
        // The month after this one exists in the grid but is disabled.
        final abbr = const Strings('en').monthAbbr(now.month + 1);
        final btn = tester.widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, abbr));
        expect(btn.onPressed, isNull, reason: '$abbr is in the future');
      }
      // January of this year is always selectable.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Jan'));
      await tester.pumpAndSettle();
      expect(app.appState.settings.period,
          'month:${now.year}-01');
      expect(app.appState.periodLabel(),
          'January ${now.year}');
    });
  });

  group('Activity wiring', () {
    testWidgets('rows follow the persisted period', (tester) async {
      final st = stateFor('thisMonth');
      final n = st.nowInTz();
      final loc = n.location;
      // Dates built as TZDateTimes in the user's timezone — a local
      // DateTime with Karachi wall-clock fields would land hours away
      // on a UTC device and fall outside the period.
      await YaadDb.insertTxn(YaadTransaction(
        amount: 100,
        dateTime: DateTime.fromMillisecondsSinceEpoch(
            tz.TZDateTime(loc, n.year, n.month, n.day, 12)
                .millisecondsSinceEpoch),
        kind: TxnKind.spend,
        rawMerchant: 'NOW SHOP',
      ));
      final lastMonth = tz.TZDateTime(loc, n.year, n.month - 1, 15, 12);
      await YaadDb.insertTxn(YaadTransaction(
        amount: 200,
        dateTime: DateTime.fromMillisecondsSinceEpoch(
            lastMonth.millisecondsSinceEpoch),
        kind: TxnKind.spend,
        rawMerchant: 'OLD SHOP',
      ));

      app.appState.settings = const AppSettings();
      await tester
          .pumpWidget(const MaterialApp(home: TimelineScreen()));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('NOW SHOP'), findsWidgets);
      expect(find.text('OLD SHOP'), findsNothing);

      // Switch the shared period → Activity follows without reopening.
      await app.appState.update(
          app.appState.settings.copyWith(period: 'allTime'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('OLD SHOP'), findsWidgets);
    });

    testWidgets('an empty picked period gets its own empty state',
        (tester) async {
      app.appState.settings =
          const AppSettings(period: 'month:2020-05');
      await tester
          .pumpWidget(const MaterialApp(home: TimelineScreen()));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Nothing recorded in May 2020.'), findsOneWidget);
      // …with a one-tap way back to this month.
      await tester.tap(find.text('This month'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(app.appState.settings.period, 'thisMonth');
    });
  });
}

int _lastMonthYear = 0;
