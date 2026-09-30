import 'package:flutter/services.dart';

import '../data/db.dart';
import '../main.dart';
import '../models/transaction.dart';
import 'sms_parse.dart';

/// Bridges the native SMS/notification queues into Yaad (§6).
/// Everything is on-device: the native side only queues when the user
/// opted in, and Dart parses + imports on next app open.
class CaptureService {
  static const _ch = MethodChannel('yaad/capture');

  static Future<void> setSmsEnabled(bool on) =>
      _ch.invokeMethod('setSmsEnabled', {'enabled': on});

  static Future<void> setNotificationEnabled(bool on) =>
      _ch.invokeMethod('setNotificationEnabled', {'enabled': on});

  static Future<bool> isNotificationAccessGranted() async {
    try {
      return await _ch.invokeMethod<bool>('isNotificationAccessGranted') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> openNotificationSettings() async {
    try {
      await _ch.invokeMethod('openNotificationSettings');
    } on PlatformException {
      // System settings unavailable: the settings screen explains.
    }
  }

  /// Drain native queues, parse, and import.
  /// Returns (autoRecorded, needsReview) counts.
  static Future<(int, int)> drainAndImport() async {
    int recorded = 0, review = 0;
    final s = appState.settings;
    if (s.smsCapture) {
      final r = await _drain('drainSmsQueue', TxnSource.sms);
      recorded += r.$1;
      review += r.$2;
    }
    if (s.notificationCapture) {
      final r = await _drain('drainNotifQueue', TxnSource.notification);
      recorded += r.$1;
      review += r.$2;
    }
    if (recorded + review > 0) appState.refresh();
    return (recorded, review);
  }

  static Future<(int, int)> _drain(
      String method, TxnSource source) async {
    int recorded = 0, review = 0;
    List<dynamic> items;
    try {
      items = await _ch.invokeMethod<List<dynamic>>(method) ?? [];
    } on PlatformException {
      return (0, 0);
    }
    for (final item in items) {
      if (item is! Map) continue;
      final sender = '${item['sender'] ?? item['package'] ?? ''}';
      final body = '${item['body'] ?? ''}';
      final ts = (item['timestamp'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      final alert = parseAlert(sender, body);
      if (alert.confidence == AlertConfidence.none) continue;

      final date =
          DateTime.fromMillisecondsSinceEpoch(ts);
      final merchant = (alert.merchant ?? '').trim();
      // Duplicate guard: same reference/amount/merchant/date.
      final dup = await YaadDb.findDuplicate(
        bankReference: alert.reference,
        amount: alert.amount!,
        rawMerchant: merchant,
        date: date,
      );
      if (dup != null) continue;

      final needsReview =
          alert.confidence == AlertConfidence.medium;
      await YaadDb.insertTxn(YaadTransaction(
        amount: alert.amount!,
        currency: appState.settings.currency,
        dateTime: date,
        kind: alert.isOut! ? TxnKind.spend : TxnKind.receive,
        direction: alert.isOut!
            ? TxnDirection.out
            : TxnDirection.incoming,
        rawMerchant: merchant,
        purpose: alert.isOut! ? 'uncategorized' : 'other_in',
        note: needsReview ? body : '',
        bankReference: alert.reference,
        source: source,
        status: needsReview
            ? TxnStatus.needsReview
            : TxnStatus.confirmed,
      ));
      if (needsReview) {
        review++;
      } else {
        recorded++;
      }
    }
    return (recorded, review);
  }
}
