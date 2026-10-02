import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/services/app_state.dart';

/// Money formatting + week/month boundaries (audit area 1 & 9).
void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  group('AppState.money — Pakistani grouping, edge values', () {
    final s = AppState()..settings = const AppSettings();
    final cases = <double, String>{
      0: 'PKR 0',
      5: 'PKR 5',
      100: 'PKR 100',
      999: 'PKR 999',
      1000: 'PKR 1,000',
      2450: 'PKR 2,450',
      100000: 'PKR 1,00,000',
      1000000: 'PKR 10,00,000',
      10000000: 'PKR 1,00,00,000',
      123456789: 'PKR 12,34,56,789',
      -100: 'PKR -100',
      -50000: 'PKR -50,000',
      -10000000: 'PKR -1,00,00,000',
    };
    cases.forEach((amount, expected) {
      test('money($amount) = $expected', () {
        expect(s.money(amount), expected);
      });
    });

    test('decimals round to the nearest rupee', () {
      expect(s.money(999.4), 'PKR 999');
      expect(s.money(999.5), 'PKR 1,000');
      expect(s.money(2450.6), 'PKR 2,451');
    });

    test('a negative that rounds to zero never shows "-0"', () {
      expect(s.money(-0.4), 'PKR 0');
      expect(s.money(-0.1), 'PKR 0');
      expect(s.money(0.4), 'PKR 0');
      // …but a negative that rounds to a real amount keeps its sign.
      expect(s.money(-0.6), 'PKR -1');
    });
  });

  group('startOfWeekMs — every week-start day', () {
    for (var first = 1; first <= 7; first++) {
      test('firstDayOfWeek=$first lands on that weekday at midnight', () {
        final s = AppState()
          ..settings = AppSettings(firstDayOfWeek: first);
        final start = tz.TZDateTime.fromMillisecondsSinceEpoch(
            tz.getLocation('Asia/Karachi'), s.startOfWeekMs());
        expect(start.weekday, first);
        expect(start.hour, 0);
        expect(start.minute, 0);
        expect(start.second, 0);
        final now = DateTime.now().millisecondsSinceEpoch;
        expect(s.startOfWeekMs(), lessThanOrEqualTo(now));
        expect(now - s.startOfWeekMs(), lessThan(7 * 24 * 3600 * 1000));
      });
    }

    test('a corrupt stored firstDayOfWeek is clamped, never crashes', () {
      for (final bad in [0, 8, -3, 42]) {
        final s = AppState()
          ..settings = AppSettings(firstDayOfWeek: bad);
        final start = tz.TZDateTime.fromMillisecondsSinceEpoch(
            tz.getLocation('Asia/Karachi'), s.startOfWeekMs());
        expect(start.weekday, inInclusiveRange(1, 7));
        expect(start.hour, 0);
      }
    });
  });

  test('new audit strings exist in both languages', () {
    expect(Strings.urduComplete, isTrue);
    for (final k in [
      'lendingStatus_open',
      'lendingStatus_partial',
      'lendingStatus_settled',
      'lendingStatus_writtenOff',
      'lendingStatus_gift',
      'repayTooMuch',
      'deleteAliasTitle',
      'deleteAliasBody',
      'aliasDeleted',
      'aliasFillBoth',
      'longPressAliasHint',
      'rangeInvalid',
      'noSpendingPeriodBody',
    ]) {
      expect(Strings('en').get(k), isNot(k), reason: 'en:$k');
      expect(Strings('ur').get(k), isNot(k), reason: 'ur:$k');
      expect(Strings('ur').get(k), isNot(Strings('en').get(k)),
          reason: 'ur differs:$k');
    }
  });
}
