import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/db.dart';
import '../main.dart';
import '../models/transaction.dart';
import 'capture_notify.dart';
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

  /// Makes the two capture toggles tell the truth.
  ///
  /// Three pieces of state must agree for capture to actually work:
  /// the Dart flag in settings (what the switch shows), the native
  /// queueing flag (yaad_capture prefs, checked by the SMS receiver /
  /// notification listener before anything is queued), and — for
  /// notifications — the OS listener grant; for SMS, the OS runtime
  /// permission. The Settings handlers set the first two together,
  /// but they can drift apart:
  ///
  /// - the user revokes the listener grant / SMS permission in Android
  ///   settings → flags stay ON, capture is dead, switch lies ON;
  /// - a backup restore writes the settings flags from another phone
  ///   where access existed → switch ON, native flag and OS grant on
  ///   THIS phone were never set;
  /// - conversely the OS grant can be present while the native flag
  ///   was never (re-)asserted → switch ON, nothing queues.
  ///
  /// Reconciliation (run from the main shell before every drain, i.e.
  /// on app start and every resume): for each channel whose settings
  /// flag is ON, check the OS-level reality. Granted → re-assert the
  /// native queueing flag. Not granted → turn the settings flag OFF
  /// (the switch then shows the truth, and the existing rationale
  /// flow can re-enable it properly) and clear the native flag. For
  /// channels whose settings flag is OFF, clear the native flag too,
  /// so "off" really means the native side queues nothing.
  ///
  /// The OS checks are injectable so the mapping is unit-testable with
  /// the platform channel mocked.
  static Future<void> reconcileCaptureFlags({
    Future<bool> Function()? smsPermissionGranted,
    Future<bool> Function()? notificationAccessGranted,
  }) async {
    final s = appState.settings;
    var next = s;

    if (!s.smsCapture) {
      await _setQuietly(() => setSmsEnabled(false));
    } else if (await (smsPermissionGranted?.call() ?? _smsGranted())) {
      await _setQuietly(() => setSmsEnabled(true));
    } else {
      next = next.copyWith(smsCapture: false);
      await _setQuietly(() => setSmsEnabled(false));
    }

    if (!s.notificationCapture) {
      await _setQuietly(() => setNotificationEnabled(false));
    } else if (await (notificationAccessGranted?.call() ??
        _notificationGranted())) {
      await _setQuietly(() => setNotificationEnabled(true));
    } else {
      next = next.copyWith(notificationCapture: false);
      await _setQuietly(() => setNotificationEnabled(false));
    }

    if (!identical(next, s)) await appState.update(next);
  }

  static Future<bool> _smsGranted() async {
    try {
      return (await Permission.sms.status).isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _notificationGranted() async {
    try {
      return await isNotificationAccessGranted();
    } catch (_) {
      return false;
    }
  }

  /// Native flag writes during reconciliation must never break the
  /// drain (or app start) when the channel is unavailable.
  static Future<void> _setQuietly(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {
      // Channel unavailable (non-Android build, tests): nothing to sync.
    }
  }

  /// Drain native queues, parse, and import.
  /// Returns (autoRecorded, needsReview) counts. Every captured
  /// transaction also lands in the capture inbox and raises one of
  /// Yaad's own phone notifications (§v1.3 autocap).
  static Future<(int, int)> drainAndImport(
      {BuildContext? promptContext}) async {
    final captured = <CapturedTxn>[];
    final s = appState.settings;
    if (s.smsCapture) {
      captured.addAll(await _drain('drainSmsQueue', TxnSource.sms));
    }
    if (s.notificationCapture) {
      captured.addAll(await _drain('drainNotifQueue', TxnSource.notification));
    }
    final recorded = captured.where((c) => !c.needsReview).length;
    final review = captured.length - recorded;
    if (captured.isNotEmpty) {
      appState.refresh();
      await CaptureNotify.handleCaptured(captured,
          promptContext: promptContext);
    }
    return (recorded, review);
  }

  static Future<List<CapturedTxn>> _drain(
      String method, TxnSource source) async {
    final out = <CapturedTxn>[];
    List<dynamic> items;
    try {
      items = await _ch.invokeMethod<List<dynamic>>(method) ?? [];
    } on PlatformException {
      return out;
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
      final txn = YaadTransaction(
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
        accountId: appState.settings.defaultAccountId,
      );
      await YaadDb.insertTxn(txn);
      out.add((txn: txn, needsReview: needsReview));
    }
    return out;
  }
}
