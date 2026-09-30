import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/settings.dart';

/// App-wide state: settings + a refresh signal the UI listens to.
/// No accounts, no cloud — everything local.
class AppState extends ChangeNotifier {
  AppSettings settings = const AppSettings();
  bool _ready = false;

  bool get ready => _ready;

  static const _key = 'yaad_settings_v1';

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
    // Simple grouping; full locale formatting via intl where needed.
    final parts = amount.toStringAsFixed(0).split('');
    final buf = StringBuffer();
    int count = 0;
    for (int i = parts.length - 1; i >= 0; i--) {
      buf.write(parts[i]);
      count++;
      if (count % 3 == 0 && i != 0) buf.write(',');
    }
    final grouped = buf.toString().split('').reversed.join();
    return '${settings.currency} $grouped';
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
    final diff = (n.weekday - settings.firstDayOfWeek) % 7;
    final start = n.subtract(Duration(days: diff));
    return _ms(tz.TZDateTime(_loc, start.year, start.month, start.day));
  }

  /// Start of the current month (user timezone).
  int startOfMonthMs() {
    final n = nowInTz();
    return _ms(tz.TZDateTime(_loc, n.year, n.month, 1));
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
