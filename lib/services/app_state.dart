import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../l10n/strings.dart';
import '../models/settings.dart';

/// One amount sanity rule for every money entry point (Confirm,
/// Lend, Borrow, the Udhaar editors): finite, positive, and below
/// 100 million in the entry's currency. The lending screens checked
/// only `> 0`, so a pasted "1e309" parsed to Infinity and was
/// STORED — after which every Udhaar total rendered "PKR ∞" and the
/// record could never settle (no repayment can exceed infinity… and
/// `double.tryParse` happily produces it).
bool isSaneAmount(double v) => v.isFinite && v > 0 && v < 100000000;

/// App-wide state: settings + a refresh signal the UI listens to.
/// No accounts, no cloud — everything local.
class AppState extends ChangeNotifier {
  AppSettings settings = const AppSettings();
  bool _ready = false;

  bool get ready => _ready;

  /// SharedPreferences key for the settings JSON. Public so services
  /// that can't import the app shell (e.g. backup) can read the
  /// default account id without a main.dart import cycle.
  static const prefsKey = 'yaad_settings_v1';

  static const _key = prefsKey;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        settings =
            AppSettings.fromMap(Map<String, Object?>.from(jsonDecode(raw)));
      } catch (_) {
        settings = const AppSettings();
      }
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> update(AppSettings next) async {
    settings = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(next.toMap()));
    notifyListeners();
  }

  /// Tell every screen to reload from the database.
  void refresh() => notifyListeners();

  String money(double amount) {
    // Pakistani digit grouping: 1,00,000 (lakh), 1,00,00,000 (crore).
    // The way our users read big numbers — not the Western 100,000.
    final grouped = _groupPakistani(amount.abs().toStringAsFixed(0));
    // A tiny negative that rounds to zero must not render as "-0".
    final neg = amount < 0 && grouped != '0';
    return '${settings.currency} ${neg ? '-' : ''}$grouped';
  }

  /// First group from the right is 3 digits, then groups of 2:
  /// 2450 -> 2,450 · 100000 -> 1,00,000 · 10000000 -> 1,00,00,000.
  static String _groupPakistani(String digits) {
    if (digits.length <= 3) return digits;
    final tail = digits.substring(digits.length - 3);
    var head = digits.substring(0, digits.length - 3);
    final groups = <String>[];
    while (head.length > 2) {
      groups.add(head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) groups.add(head);
    return '${groups.reversed.join(',')},$tail';
  }

  // ---------- timezone-aware date helpers ----------
  // Week / month summaries must use the user's chosen timezone and
  // week-start day, not the phone's locale.

  tz.Location get _loc {
    try {
      return tz.getLocation(settings.timezone);
    } catch (_) {
      return tz.local;
    }
  }

  /// "Now" in the user's chosen timezone.
  tz.TZDateTime nowInTz() => tz.TZDateTime.now(_loc);

  static int _ms(tz.TZDateTime d) => d.millisecondsSinceEpoch;

  /// Start of today (user timezone) as epoch millis.
  int startOfTodayMs() {
    final n = nowInTz();
    return _ms(tz.TZDateTime(_loc, n.year, n.month, n.day));
  }

  /// Start of the current week (user timezone + chosen week-start day).
  int startOfWeekMs() {
    final n = nowInTz();
    // firstDayOfWeek: 1 = Monday … 7 = Sunday, matching DateTime.weekday.
    // Clamp a corrupt stored value into range instead of trusting it.
    final first = ((settings.firstDayOfWeek - 1) % 7) + 1;
    final diff = (n.weekday - first) % 7;
    // Pure calendar math (the TZDateTime constructor normalises a
    // day <= 0 into the previous month) — subtracting a Duration
    // instead would drift by an hour across DST changes and could
    // land on the wrong calendar day.
    return _ms(tz.TZDateTime(_loc, n.year, n.month, n.day - diff));
  }

  /// Start of the current month (user timezone).
  int startOfMonthMs() {
    final n = nowInTz();
    return _ms(tz.TZDateTime(_loc, n.year, n.month, 1));
  }

  // ---------- shared viewing period ----------
  // One persisted period (AppSettings.period) drives Home, Activity
  // and Summary alike, so every screen always talks about the same
  // stretch of time. All bounds use the user's timezone.

  /// Parses a 'month:YYYY-MM' period value into (year, month).
  /// Returns null for the fixed period values.
  static (int, int)? periodMonthParts(String period) {
    if (!period.startsWith('month:')) return null;
    final parts = period.substring(6).split('-');
    if (parts.length != 2) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null || m < 1 || m > 12) return null;
    return (y, m);
  }

  /// Inclusive epoch-ms bounds for [period] (default: the persisted
  /// settings period), as a positional record — destructure it:
  /// `final (fromMs, toMs) = appState.periodRangeMs();`
  /// Open-ended periods (thisWeek/thisMonth/thisYear/allTime) end at
  /// "now"; closed periods (lastMonth, a picked month) end at their
  /// last millisecond. 'allTime' starts at 0. Feed the bounds
  /// straight into YaadDb sums / txns(fromMs:, toMs:) — e.g.
  /// Left = sumReceived − sumSpent − savingsNet(fromMs, toMs).
  (int fromMs, int toMs) periodRangeMs([String? period]) {
    final p = period ?? settings.period;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final n = nowInTz();
    final loc = _loc;
    final picked = periodMonthParts(p);
    if (picked != null) {
      final (y, m) = picked;
      final start = tz.TZDateTime(loc, y, m, 1);
      final next = tz.TZDateTime(loc, y, m + 1, 1);
      return (start.millisecondsSinceEpoch, next.millisecondsSinceEpoch - 1);
    }
    switch (p) {
      case AppSettings.periodThisWeek:
        return (startOfWeekMs(), nowMs);
      case AppSettings.periodLastMonth:
        // TZDateTime normalises month 0 into December of the year
        // before, so January's "last month" is right too.
        final start = tz.TZDateTime(loc, n.year, n.month - 1, 1);
        return (start.millisecondsSinceEpoch, startOfMonthMs() - 1);
      case AppSettings.periodThisYear:
        final start = tz.TZDateTime(loc, n.year, 1, 1);
        return (start.millisecondsSinceEpoch, nowMs);
      case AppSettings.periodAllTime:
        return (0, nowMs);
      case AppSettings.periodThisMonth:
      default:
        return (startOfMonthMs(), nowMs);
    }
  }

  /// The period's display name in the user's language — the noun a
  /// heading composes with, e.g. "Spent in " + periodLabel():
  /// 'October' (thisMonth), 'October 2025' (a picked month),
  /// 'Last month', 'This week', '2026' (thisYear), 'All time'.
  String periodLabel([String? period]) {
    final p = period ?? settings.period;
    final s = Strings(settings.language);
    final n = nowInTz();
    final picked = periodMonthParts(p);
    if (picked != null) {
      final (y, m) = picked;
      return '${s.monthFull(m)} $y';
    }
    switch (p) {
      case AppSettings.periodThisWeek:
        return s.get('thisWeek');
      case AppSettings.periodLastMonth:
        return s.get('lastMonth');
      case AppSettings.periodThisYear:
        return '${n.year}';
      case AppSettings.periodAllTime:
        return s.get('rangeAllTime');
      case AppSettings.periodThisMonth:
      default:
        return s.monthFull(n.month);
    }
  }

  /// Date formatted per the user's chosen date format.
  String formatDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    switch (settings.dateFormat) {
      case 'mdy':
        return '$mm/$dd/${d.year}';
      case 'ymd':
        return '${d.year}-$mm-$dd';
      default:
        return '$dd/$mm/${d.year}';
    }
  }
}
