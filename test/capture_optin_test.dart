import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/l10n/strings.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/screens/settings.dart';
import 'package:yaad/services/sms_capture.dart';

/// Build-26: the notification-capture opt-in flow.
///
/// Three defects are pinned here:
/// 1. the toggle checked for the OS grant only AFTER the guide +
///    rationale dialog, so a user who had already granted access in
///    system settings got the dialog loop again;
/// 2. "finish the opt-in when the user returns" lived in a widget
///    field, which the app-lock Gate disposes when it swaps the shell
///    for the lock screen — the pending opt-in is now persisted
///    settings state ([AppSettings.notifOptInPending]) completed by
///    [CaptureService.completePendingNotifOptIn];
/// 3. "Open settings" discarded the native result and swallowed every
///    error, so a failed open looked like a dead button.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('yaad/capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    appState.settings = const AppSettings();
  });

  group('notifOptInPending setting', () {
    test('defaults false, round-trips, and is false when absent', () {
      expect(const AppSettings().notifOptInPending, isFalse);
      final on = const AppSettings().copyWith(notifOptInPending: true);
      expect(on.notifOptInPending, isTrue);
      expect(AppSettings.fromMap(on.toMap()).notifOptInPending, isTrue);
      // Settings/backups written before the field existed still load.
      expect(AppSettings.fromMap(const {}).notifOptInPending, isFalse);
    });

    test('new failure string exists in English and Urdu', () {
      expect(Strings('en').get('notifOpenSettingsFailed'),
          contains('Notification access'));
      expect(Strings('ur').get('notifOpenSettingsFailed'),
          isNot('notifOpenSettingsFailed'));
      expect(Strings.urduComplete, isTrue);
    });
  });

  group('completePendingNotifOptIn', () {
    final calls = <MethodCall>[];
    var granted = false;

    setUp(() {
      calls.clear();
      granted = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'isNotificationAccessGranted') return granted;
        return null; // drains return nothing queued; flag writes succeed
      });
    });

    bool? nativeFlag(String method) {
      final hits = calls.where((c) => c.method == method);
      if (hits.isEmpty) return null;
      return hits.last.arguments['enabled'] as bool?;
    }

    test('pending + granted: capture turns on, pending cleared', () async {
      granted = true;
      appState.settings = const AppSettings(notifOptInPending: true);
      final outcome = await CaptureService.completePendingNotifOptIn();
      expect(outcome, NotifOptInOutcome.enabled);
      expect(appState.settings.notificationCapture, isTrue);
      expect(appState.settings.notifOptInPending, isFalse);
      expect(nativeFlag('setNotificationEnabled'), isTrue);
      // The queue was drained as part of turning capture on.
      expect(calls.any((c) => c.method == 'drainNotifQueue'), isTrue);
      // Idempotent: a second completion pass is a no-op.
      final again = await CaptureService.completePendingNotifOptIn();
      expect(again, NotifOptInOutcome.none);
      expect(appState.settings.notificationCapture, isTrue);
    });

    test('pending + not granted: nothing enabled, pending cleared',
        () async {
      granted = false;
      appState.settings = const AppSettings(notifOptInPending: true);
      final outcome = await CaptureService.completePendingNotifOptIn();
      expect(outcome, NotifOptInOutcome.missing);
      expect(appState.settings.notificationCapture, isFalse);
      expect(appState.settings.notifOptInPending, isFalse);
      expect(nativeFlag('setNotificationEnabled'), isNull);
    });

    test('not pending: no-op even when access is granted', () async {
      granted = true;
      appState.settings = const AppSettings();
      final outcome = await CaptureService.completePendingNotifOptIn();
      expect(outcome, NotifOptInOutcome.none);
      expect(appState.settings.notificationCapture, isFalse);
    });
  });

  group('reconcile while an opt-in is pending', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    test('notification channel is skipped entirely', () async {
      appState.settings = const AppSettings(notifOptInPending: true);
      await CaptureService.reconcileCaptureFlags(
        smsPermissionGranted: () async => true,
        notificationAccessGranted: () async => true,
      );
      // The pending opt-in owns the notification channel until it
      // completes: reconcile must not touch its native flag or the
      // settings flags mid-flow.
      expect(calls.any((c) => c.method == 'setNotificationEnabled'),
          isFalse);
      expect(appState.settings.notificationCapture, isFalse);
      expect(appState.settings.notifOptInPending, isTrue);
      // The SMS channel still reconciles normally (flag off → native
      // queueing forced off).
      expect(calls.any((c) => c.method == 'setSmsEnabled'), isTrue);
    });
  });

  group('openNotificationSettings result', () {
    test('no handler (plugin missing): returns false, never throws',
        () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(await CaptureService.openNotificationSettings(), isFalse);
    });

    test('native true comes through', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => true);
      expect(await CaptureService.openNotificationSettings(), isTrue);
    });

    test('native false comes through', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await CaptureService.openNotificationSettings(), isFalse);
    });

    test('PlatformException becomes false', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'no-activity');
      });
      expect(await CaptureService.openNotificationSettings(), isFalse);
    });
  });

  group('notification toggle with access already granted', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'isNotificationAccessGranted') return true;
        return null;
      });
    });

    testWidgets('turns straight on — no guide, no rationale dialog',
        (tester) async {
      appState.settings = const AppSettings();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SettingsScreen())),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Bank notifications'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bank notifications'));
      await tester.pumpAndSettle();

      expect(find.text('One phone setting first'), findsNothing);
      expect(find.text('Turn on bank notification capture?'),
          findsNothing);
      expect(appState.settings.notificationCapture, isTrue);
      expect(appState.settings.notifOptInPending, isFalse);
      final hits = calls.where((c) => c.method == 'setNotificationEnabled');
      expect(hits.isNotEmpty, isTrue);
      expect(hits.last.arguments['enabled'], isTrue);
      // Turning capture on kicks off a queue drain whose sqflite
      // query stalls under the fake clock (its replies need real
      // async); let sqflite's 10s transaction watchdog timer fire
      // before teardown, or the binding's no-pending-timers
      // invariant fails — same pattern as flow_system_test's shell
      // test.
      await tester.pump(const Duration(seconds: 11));
    });
  });
}
