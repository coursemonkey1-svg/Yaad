import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/transaction.dart';
import '../screens/transaction_view.dart';
import 'capture_inbox.dart';
import 'capture_payload.dart';

/// One auto-captured transaction handed off from the drain:
/// the recorded txn plus whether it needs a human eye.
typedef CapturedTxn = ({YaadTransaction txn, bool needsReview});

/// Yaad's own phone notifications about auto-captured bank alerts
/// (§v1.3 autocap). Everything is on-device: we only ever post about
/// transactions this phone already recorded.
class CaptureNotify {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'yaad_capture';
  static const _promptedKey = 'capture_notif_prompted_v1';
  static const _pendingTapKey = 'capture_pending_tap_v1';
  static String? _pendingPayload;

  /// Whether the app-lock Gate is REALLY showing the lock screen
  /// right now. Maintained by the Gate (lock transition → true,
  /// successful auth → false). A notification tap must be stashed
  /// only while this is true: testing the app-lock SETTING instead
  /// stashed every tap that arrived while the app sat open and
  /// unlocked, and the tap then did nothing until some future
  /// lock→unlock cycle — the notification looked dead.
  static final ValueNotifier<bool> gateLocked = ValueNotifier<bool>(false);

  /// A transaction tap that arrived while the app lock was on. It must
  /// never open above the lock screen (that would bypass the lock), but
  /// dropping it silently loses the tap — so it is stashed here and
  /// opened by [openPendingAfterUnlock] once Gate reports a real unlock.
  /// Persisted (see [_pendingTapKey]), not just held in this field:
  /// the process can die while the phone sits locked, and a memory-only
  /// stash died with it.
  static String? _pendingLockedTxnId;

  /// Call once from main() before runApp.
  static Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      // Warm tap: app already running (foreground or background).
      onDidReceiveNotificationResponse: (resp) {
        final id = txnIdFromPayload(resp.payload);
        if (id != null) unawaited(openCapturedTxn(id));
      },
    );
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      'Bank alerts',
      description: 'Posted when Yaad auto-records a bank transaction',
      importance: Importance.high,
    ));
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch != null && launch.didNotificationLaunchApp) {
        _pendingPayload = launch.notificationResponse?.payload;
      }
    } catch (_) {
      // Cold-start details unavailable: the inbox bell still works.
    }
  }

  /// Cold tap: the notification launched a terminated app. Call once,
  /// post-frame, after runApp.
  static Future<void> openPendingLaunch() async {
    final id = txnIdFromPayload(_pendingPayload);
    _pendingPayload = null;
    if (id != null) await openCapturedTxn(id);
  }

  /// Opens the transaction behind a notification tap / inbox entry: the
  /// read-only detail view, with the editor one explicit Edit tap away.
  static Future<void> openCapturedTxn(String txnId) async {
    // App lock is a real lock: never auto-open a transaction above it.
    // Stash the tap instead — Gate opens it after a successful unlock,
    // so the tap is honoured, just only once the user is really in.
    // The test is the Gate's ACTUAL state, not the lock setting: with
    // the app open and unlocked, a tap opens immediately.
    if (gateLocked.value) {
      _pendingLockedTxnId = txnId;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_pendingTapKey, txnId);
      } catch (_) {
        // Memory stash still holds it for this process.
      }
      return;
    }
    await _openTxn(txnId);
  }

  /// Called by Gate after a successful unlock: opens a transaction tap
  /// that was stashed by [openCapturedTxn] while the app was locked.
  /// No-op when nothing is stashed. Bypasses the lock check on purpose —
  /// the caller (Gate) has just authenticated the user.
  static Future<void> openPendingAfterUnlock() async {
    var id = _pendingLockedTxnId;
    _pendingLockedTxnId = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      id ??= prefs.getString(_pendingTapKey);
      await prefs.remove(_pendingTapKey);
    } catch (_) {
      // Fall through with whatever the memory stash held.
    }
    if (id == null) return;
    await _openTxn(id);
  }

  static Future<void> _openTxn(String txnId) async {
    final txn = await YaadDb.txnById(txnId);
    final nav = navigatorKey.currentState;
    if (txn == null || nav == null) return;
    await nav.push(
        MaterialPageRoute(builder: (_) => TransactionViewScreen(txn: txn)));
  }

  /// Called after every drain that captured something: one inbox entry
  /// per transaction, then one phone notification per transaction.
  /// The POST_NOTIFICATIONS permission is asked once, at this first
  /// moment of need, with a plain one-line explanation (mic pattern).
  static Future<void> handleCaptured(List<CapturedTxn> txns,
      {BuildContext? promptContext}) async {
    for (final c in txns) {
      await CaptureInbox.instance.add(
        txnId: c.txn.id,
        merchant: c.txn.rawMerchant,
        amount: c.txn.amount,
        time: c.txn.dateTime,
        needsReview: c.needsReview,
        isOut: c.txn.direction == TxnDirection.out,
      );
    }
    if (promptContext != null) {
      await maybePromptPermission(promptContext);
    }
    if (!await _notifGranted()) return;
    for (final c in txns) {
      await _post(c.txn, c.needsReview);
    }
  }

  /// The notification-permission check, exception-proof: where the
  /// plugin channel is unavailable (tests, a stripped build) the
  /// check itself throws MissingPluginException — that must read as
  /// "not granted", never escape into the drain chain and take the
  /// whole capture pass down with it.
  static Future<bool> _notifGranted() async {
    try {
      return await Permission.notification.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// One-line rationale + request, the first time an auto-capture happens.
  /// Mirrors the mic-permission UX in confirm.dart: ask at the moment of
  /// need, guide to settings on permanent denial, stay quiet otherwise.
  static Future<void> maybePromptPermission(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_promptedKey) == true) return;
    if (await _notifGranted()) return;
    final s = Strings(appState.settings.language);
    final done = Completer<void>();
    // Post-frame: drains can fire from initState's async gap.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!context.mounted) return;
        // The "asked once" flag is spent only now that the dialog is
        // really about to render. It used to be persisted BEFORE this
        // frame callback ran: a first capture landing around a
        // lock/backgrounding disposed the caller's context, the
        // dialog was skipped — and the flag was already spent, so
        // the rationale never appeared, ever, and Yaad's capture
        // notifications silently never arrived.
        await prefs.setBool(_promptedKey, true);
        final want = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            content: Text(s.get('captureNotifRationale')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(s.get('notNow')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(s.get('captureNotifAllow')),
              ),
            ],
          ),
        );
        if (want != true || !context.mounted) return;
        // The request can throw where the plugin is unavailable —
        // that is a quiet "no", not a crash out of a frame callback.
        PermissionStatus? status;
        try {
          status = await Permission.notification.request();
        } catch (_) {
          status = null;
        }
        if (status == null || !context.mounted) return;
        if (status.isPermanentlyDenied) {
          await showDialog(
            context: context,
            builder: (_) => AlertDialog(
              content: Text(s.get('captureNotifSettingsBody')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(s.get('cancel')),
                ),
                FilledButton(
                  onPressed: () {
                    openAppSettings();
                    Navigator.of(context).pop();
                  },
                  child: Text(s.get('openSettings')),
                ),
              ],
            ),
          );
        } else if (!status.isGranted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(s.get('captureNotifDenied'))));
        }
      } finally {
        done.complete();
      }
    });
    // Never hang the drain if no frame ever arrives.
    return done.future.timeout(const Duration(seconds: 15), onTimeout: () {});
  }

  static Future<void> _post(YaadTransaction txn, bool needsReview) async {
    final s = Strings(appState.settings.language);
    final amount = appState.money(txn.amount);
    final title = (needsReview
            ? s.get('captureNotifTitleReview')
            : s.get('captureNotifTitle'))
        .replaceFirst('{amount}', amount);
    final merchant = txn.rawMerchant.trim();
    final body = merchant.isEmpty
        ? s.get('captureNotifBodyNoMerchant')
        : s.get('captureNotifBody').replaceFirst('{merchant}', merchant);
    try {
      await _plugin.show(
        id: txn.id.hashCode & 0x7fffffff,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Bank alerts',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: capturePayload(txn.id),
      );
    } catch (_) {
      // A failed ping must never break the drain.
    }
  }
}
