import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/db.dart';
import '../main.dart';
import '../models/account.dart';
import '../models/transaction.dart';
import 'capture_notify.dart';
import 'sms_parse.dart';

/// Result of [CaptureService.completePendingNotifOptIn].
enum NotifOptInOutcome {
  /// No opt-in was pending; nothing was done.
  none,

  /// A pending opt-in found its OS grant and capture is now on.
  enabled,

  /// A pending opt-in was checked and the OS grant is still missing;
  /// the pending flag was cleared and nothing was enabled.
  missing,
}

/// Result of [CaptureService.completePendingSmsOptIn].
enum SmsOptInOutcome {
  /// No opt-in was pending; nothing was done.
  none,

  /// A pending opt-in found its OS grant and capture is now on.
  enabled,

  /// A pending opt-in was checked and the OS grant is still missing;
  /// the pending flag was cleared and nothing was enabled.
  missing,
}

/// Bridges the native SMS/notification queues into Yaad (§6).
/// Everything is on-device: the native side only queues when the user
/// opted in, and Dart parses + imports on next app open.
class CaptureService {
  static const _ch = MethodChannel('yaad/capture');

  /// Serialises every capture pass that reads-modifies-writes the
  /// shared settings flags (complete-pending, reconcile, drain).
  /// Three callers fire these on the SAME resume/unlock event (Gate
  /// unlock, shell drain, Settings resume) with no ordering between
  /// them; unserialised, their check-then-act passes interleave
  /// across awaits and a stale whole-object settings write can undo
  /// a completed opt-in — the build-26 complaint returning
  /// non-deterministically. Public entry points enqueue; private
  /// workers assume their pass is already running (a worker calling
  /// a public entry point would queue behind itself, so workers only
  /// call workers).
  ///
  /// The queue is deliberately NOT a future chain: a job's listeners
  /// are attached synchronously when it is enqueued, and the next
  /// job is started by the previous job's own completion — so a
  /// pass that finishes inside a short-lived zone (a widget test's
  /// fake zone, say) still hands over cleanly to a pass enqueued
  /// later from a different zone, instead of wedging it behind a
  /// completion notification that will never be delivered.
  static final List<Future<void> Function()> _queue = [];
  static bool _passActive = false;

  static Future<T> _serialized<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _queue.add(() async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _pumpQueue();
    return completer.future;
  }

  static void _pumpQueue() {
    if (_passActive || _queue.isEmpty) return;
    _passActive = true;
    final job = _queue.removeAt(0);
    job().whenComplete(() {
      _passActive = false;
      _pumpQueue();
    });
  }

  static Future<void> setSmsEnabled(bool on) =>
      _ch.invokeMethod('setSmsEnabled', {'enabled': on});

  static Future<void> setNotificationEnabled(bool on) =>
      _ch.invokeMethod('setNotificationEnabled', {'enabled': on});

  /// Deletes the native capture queue files (factory wipe): bank
  /// alerts queued before a wipe must never be imported as fresh
  /// entries if capture is turned on again afterwards. Never
  /// throws — an unavailable channel means there is no native
  /// queue to clear.
  static Future<void> clearCaptureQueues() async {
    try {
      await _ch.invokeMethod('clearCaptureQueues');
    } catch (_) {
      // Channel unavailable (non-Android build, tests).
    }
  }

  static Future<bool> isNotificationAccessGranted() async {
    try {
      return await _ch.invokeMethod<bool>('isNotificationAccessGranted') ??
          false;
    } catch (_) {
      // PlatformException, or MissingPluginException where the channel
      // isn't registered: either way access is not verifiably granted.
      return false;
    }
  }

  /// Opens the system notification-access settings page. The native
  /// side reports whether the intent actually fired; false means the
  /// user must be told how to get there manually — never fail silent
  /// (a dead "Open settings" button reads as a broken app).
  static Future<bool> openNotificationSettings() async {
    try {
      return await _ch.invokeMethod<bool>('openNotificationSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Completes a notification-capture opt-in the user started before
  /// leaving for system settings ([AppSettings.notifOptInPending]).
  ///
  /// The pending flag is persisted settings state, not widget state,
  /// because the trip to system settings can tear the widget tree down:
  /// the app-lock Gate replaces the whole shell with the lock screen on
  /// re-lock, disposing the Settings state that used to hold this in a
  /// field — the "finish the opt-in when the user returns" step was
  /// thrown away with it and the toggle could never turn on.
  ///
  /// Outcomes:
  /// - not pending → [NotifOptInOutcome.none], nothing happens;
  /// - pending + access granted → capture turns fully on (settings
  ///   flag, native queueing flag, pending cleared, queue drained):
  ///   [NotifOptInOutcome.enabled];
  /// - pending + access still missing → the return-check is over, so
  ///   pending is cleared and nothing is enabled:
  ///   [NotifOptInOutcome.missing]. The Settings screen shows the
  ///   'notifAccessNeeded' nudge for this outcome.
  ///
  /// Idempotent: safe to call from shell resume, Gate unlock, and the
  /// Settings screen's own resume handler in any order — the first
  /// call resolves the flag, later calls see [NotifOptInOutcome.none].
  /// Serialised with the other capture passes (see [_serialized]):
  /// the doc-idempotency above only holds if concurrent callers
  /// cannot interleave their check-then-act steps.
  static Future<NotifOptInOutcome> completePendingNotifOptIn({
    Future<bool> Function()? notificationAccessGranted,
  }) =>
      _serialized(() => _completePendingNotifOptIn(
          notificationAccessGranted: notificationAccessGranted));

  static Future<NotifOptInOutcome> _completePendingNotifOptIn({
    Future<bool> Function()? notificationAccessGranted,
  }) async {
    if (!appState.settings.notifOptInPending) {
      return NotifOptInOutcome.none;
    }
    final granted = await (notificationAccessGranted?.call() ??
        _notificationGranted());
    if (!granted) {
      // Record the miss durably: the Settings state that started
      // this trip may have been disposed by the app-lock Gate, and
      // the fresh one still owes the user the explanation nudge.
      await appState.update(appState.settings.copyWith(
          notifOptInPending: false, notifOptInMissed: true));
      return NotifOptInOutcome.missing;
    }
    await appState.update(appState.settings.copyWith(
        notificationCapture: true,
        notifOptInPending: false,
        notifOptInMissed: false));
    await _setQuietly(() => setNotificationEnabled(true));
    await _drainAndImport();
    return NotifOptInOutcome.enabled;
  }

  /// Completes an SMS-capture opt-in the user started before the
  /// system permission dialog ([AppSettings.smsOptInPending]).
  ///
  /// The SMS flow had the exact disease build-26 fixed for
  /// notifications: the grant result lived only in the Settings
  /// screen's async handler, and the app-lock Gate disposes that
  /// screen when the permission trip re-locks the app — a granted
  /// permission was thrown away on `if (!mounted) return` and the
  /// toggle stayed off with no explanation. The pending flag is
  /// persisted before the request; this pass (shell drain, Gate
  /// unlock, Settings resume — first one wins) finishes it.
  static Future<SmsOptInOutcome> completePendingSmsOptIn({
    Future<bool> Function()? smsPermissionGranted,
  }) =>
      _serialized(() => _completePendingSmsOptIn(
          smsPermissionGranted: smsPermissionGranted));

  static Future<SmsOptInOutcome> _completePendingSmsOptIn({
    Future<bool> Function()? smsPermissionGranted,
  }) async {
    if (!appState.settings.smsOptInPending) {
      return SmsOptInOutcome.none;
    }
    bool granted;
    try {
      if (smsPermissionGranted != null) {
        granted = await smsPermissionGranted();
      } else {
        granted = await _smsGrantedOrNull() ?? false;
      }
    } catch (_) {
      granted = false;
    }
    if (!granted) {
      await appState.update(appState.settings
          .copyWith(smsOptInPending: false, smsOptInMissed: true));
      return SmsOptInOutcome.missing;
    }
    await appState.update(appState.settings.copyWith(
        smsCapture: true, smsOptInPending: false, smsOptInMissed: false));
    await _setQuietly(() => setSmsEnabled(true));
    await _drainAndImport();
    return SmsOptInOutcome.enabled;
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
  /// While a notification opt-in is mid-trip to system settings
  /// ([AppSettings.notifOptInPending]) the notification channel is
  /// skipped entirely — [completePendingNotifOptIn] owns it until the
  /// user returns.
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
  }) =>
      _serialized(() => _reconcileCaptureFlags(
          smsPermissionGranted: smsPermissionGranted,
          notificationAccessGranted: notificationAccessGranted));

  static Future<void> _reconcileCaptureFlags({
    Future<bool> Function()? smsPermissionGranted,
    Future<bool> Function()? notificationAccessGranted,
  }) async {
    final s = appState.settings;
    // Decisions only — applied at the end to a FRESH settings read.
    // This pass awaits platform checks; a concurrent pass (or the
    // user) can legitimately change settings meanwhile, and writing
    // back a whole object built from the pre-await snapshot would
    // silently revert their change (it reverted completed opt-ins).
    var smsOff = false;
    var notifOff = false;

    if (s.smsOptInPending) {
      // An SMS opt-in trip is in progress; completePendingSmsOptIn
      // owns the channel until the user returns (same rule as the
      // notification channel below).
    } else if (!s.smsCapture) {
      await _setQuietly(() => setSmsEnabled(false));
    } else {
      final g = await _checkSms(smsPermissionGranted);
      if (g == true) {
        await _setQuietly(() => setSmsEnabled(true));
      } else if (g == false) {
        smsOff = true;
        await _setQuietly(() => setSmsEnabled(false));
      }
      // g == null: the check itself failed (channel hiccup) — that
      // is "unknown", not "revoked". Leave every flag untouched and
      // let the next resume re-check; treating a hiccup as a
      // revocation silently killed working capture.
    }

    if (s.notifOptInPending) {
      // An opt-in trip to system settings is in progress. Leave the
      // notification channel completely alone: reconciling it now —
      // before completePendingNotifOptIn runs on return — could
      // clear/re-assert native flags mid-flow and fight the
      // completion pass.
    } else if (!s.notificationCapture) {
      await _setQuietly(() => setNotificationEnabled(false));
    } else {
      final g = await _checkNotif(notificationAccessGranted);
      if (g == true) {
        await _setQuietly(() => setNotificationEnabled(true));
      } else if (g == false) {
        notifOff = true;
        await _setQuietly(() => setNotificationEnabled(false));
      }
    }

    if (smsOff || notifOff) {
      final fresh = appState.settings;
      await appState.update(fresh.copyWith(
        smsCapture: smsOff ? false : fresh.smsCapture,
        notificationCapture: notifOff ? false : fresh.notificationCapture,
      ));
    }
  }

  /// Tri-state permission checks: true = granted, false = definitely
  /// not granted, null = the check itself failed (unknown). Only a
  /// definitive false may turn a capture flag off.
  static Future<bool?> _checkSms(
      Future<bool> Function()? injected) async {
    try {
      if (injected != null) return await injected();
      return await _smsGrantedOrNull();
    } catch (_) {
      return null;
    }
  }

  static Future<bool?> _checkNotif(
      Future<bool> Function()? injected) async {
    try {
      if (injected != null) return await injected();
      return await _notificationGrantedOrNull();
    } catch (_) {
      return null;
    }
  }

  static Future<bool?> _smsGrantedOrNull() async {
    try {
      return (await Permission.sms.status).isGranted;
    } catch (_) {
      return null;
    }
  }

  static Future<bool?> _notificationGrantedOrNull() async {
    try {
      return await _ch.invokeMethod<bool>('isNotificationAccessGranted');
    } catch (_) {
      return null;
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
  static Future<(int, int)> drainAndImport({BuildContext? promptContext}) =>
      _serialized(() => _drainAndImport(promptContext: promptContext));

  static Future<(int, int)> _drainAndImport(
      {BuildContext? promptContext}) async {
    final captured = <CapturedTxn>[];
    final s = appState.settings;
    // Every alert in this drain books to the same account: the bank
    // account (see bankEventAccountId), resolved ONCE here — never
    // the raw settings default at drain time, which the user may
    // have changed (or set to Savings by an accidental Accounts tap)
    // between the alert arriving and this drain running.
    String? accountId;
    if (s.smsCapture || s.notificationCapture) {
      accountId = bankEventAccountId(await YaadDb.accounts(),
          defaultBank: s.defaultBank, preferredId: s.defaultAccountId);
    }
    if (s.smsCapture) {
      captured
          .addAll(await _drain('drainSmsQueue', TxnSource.sms, accountId!));
    }
    if (s.notificationCapture) {
      captured.addAll(
          await _drain('drainNotifQueue', TxnSource.notification, accountId!));
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
      String method, TxnSource source, String accountId) async {
    final out = <CapturedTxn>[];
    List<dynamic> items;
    try {
      items = await _ch.invokeMethod<List<dynamic>>(method) ?? [];
    } catch (_) {
      // PlatformException AND MissingPluginException (which is NOT a
      // PlatformException subclass): on a build where the channel is
      // not registered the drain must quietly find nothing, never
      // throw into the resume chain and take reconcile down with it.
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
        kind: alert.isOut! ? TxnKind.spend : TxnKind.receive,
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
        accountId: accountId,
      );
      await YaadDb.insertTxn(txn);
      out.add((txn: txn, needsReview: needsReview));
    }
    return out;
  }
}
