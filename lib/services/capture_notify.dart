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
import 'pro.dart';

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
  static String? _pendingPayload;

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
    // The user lands on the lock screen; the inbox bell still works after.
    final s = appState.settings;
    if (s.appLock && ProService.canUseAppLock(s)) return;
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
      );
    }
    if (promptContext != null) {
      await maybePromptPermission(promptContext);
    }
    if (!await Permission.notification.isGranted) return;
    for (final c in txns) {
      await _post(c.txn, c.needsReview);
    }
  }

  /// One-line rationale + request, the first time an auto-capture happens.
  /// Mirrors the mic-permission UX in confirm.dart: ask at the moment of
  /// need, guide to settings on permanent denial, stay quiet otherwise.
  static Future<void> maybePromptPermission(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_promptedKey) == true) return;
    await prefs.setBool(_promptedKey, true);
    if (await Permission.notification.isGranted) return;
    final s = Strings(appState.settings.language);
    final done = Completer<void>();
    // Post-frame: drains can fire from initState's async gap.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!context.mounted) return;
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
        final status = await Permission.notification.request();
        if (!context.mounted) return;
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
    return done.future.timeout(const Duration(seconds: 15),
        onTimeout: () {});
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
