import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:yaad/services/app_state.dart';
import 'package:yaad/models/settings.dart';

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  group('AppState.money', () {
    test('formats PKR with thousand separators', () {
      final s = AppState()..settings = const AppSettings();
      expect(s.money(2450), 'PKR 2,450');
      expect(s.money(1000000), 'PKR 1,000,000');
      expect(s.money(0), 'PKR 0');
    });

    test('respects the configured currency', () {
      final s = AppState()..settings = const AppSettings(currency: 'USD');
      expect(s.money(500), 'USD 500');
    });
  });

  group('timezone-aware boundaries', () {
    test('defaults to Asia/Karachi', () {
      final s = AppState()..settings = const AppSettings();
      expect(s.settings.timezone, 'Asia/Karachi');
      expect(s.nowInTz().location.name, 'Asia/Karachi');
    });

    test('today boundary brackets now', () {
      final s = AppState()..settings = const AppSettings();
      final now = DateTime.now().millisecondsSinceEpoch;
      final start = s.startOfTodayMs();
      expect(start, lessThanOrEqualTo(now));
      expect(now - start, lessThan(24 * 3600 * 1000));
    });

    test('week boundary matches the chosen week-start day', () {
      final s = AppState()
        ..settings = const AppSettings(firstDayOfWeek: 7); // Sunday
      final start = tz.TZDateTime.fromMillisecondsSinceEpoch(
          tz.getLocation('Asia/Karachi'), s.startOfWeekMs());
      expect(start.weekday, 7);
    });

    test('month boundary is the 1st at midnight', () {
      final s = AppState()..settings = const AppSettings();
      final start = tz.TZDateTime.fromMillisecondsSinceEpoch(
          tz.getLocation('Asia/Karachi'), s.startOfMonthMs());
      expect(start.day, 1);
      expect(start.hour, 0);
      expect(start.minute, 0);
    });

    test('falls back to local on unknown timezone name', () {
      final s = AppState()
        ..settings = const AppSettings(timezone: 'Mars/Olympus');
      expect(() => s.nowInTz(), returnsNormally);
    });
  });

  group('formatDate', () {
    final d = DateTime(2026, 9, 5);

    test('dmy', () {
      final s = AppState()..settings = const AppSettings(dateFormat: 'dmy');
      expect(s.formatDate(d), '05/09/2026');
    });

    test('mdy', () {
      final s = AppState()..settings = const AppSettings(dateFormat: 'mdy');
      expect(s.formatDate(d), '09/05/2026');
    });

    test('ymd', () {
      final s = AppState()..settings = const AppSettings(dateFormat: 'ymd');
      expect(s.formatDate(d), '2026-09-05');
    });
  });
}
