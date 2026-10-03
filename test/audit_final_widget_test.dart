import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:yaad/main.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/services/capture_flow.dart' as capture_flow;
import 'package:yaad/services/capture_notify.dart';

/// Widget-level regression tests for the final audit (build-28):
/// the app-lock Gate and the capture flows that live on the root
/// navigator, above the Gate's child swap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const authChannel = MethodChannel('plugins.flutter.io/local_auth');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    // The unlocked Gate builds the real shell, whose period label
    // reads the timezone database (production initializes it in
    // main()); without this, Home dies with a LateInitializationError.
    tzdata.initializeTimeZones();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(authChannel, null);
    appState.settings = const AppSettings();
    CaptureNotify.gateLocked.value = false;
  });

  group('app-lock Gate', () {
    testWidgets(
        're-lock pops pushed routes: nothing usable sits above the lock',
        (tester) async {
      messenger.setMockMethodCallHandler(authChannel, (call) async {
        if (call.method == 'isDeviceSupported') return true;
        if (call.method == 'authenticate') return true;
        return null;
      });
      appState.settings = const AppSettings(
        onboardingDone: true,
        appLock: true,
        appLockGrandfathered: true,
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Gate()),
      );
      // First frame: the first-build flag is consumed; auth succeeds.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(CaptureNotify.gateLocked.value, isFalse,
          reason: 'a successful unlock publishes the open state');

      // The user opens a screen (Add/Confirm stand-in) and leaves it
      // open while backgrounding the app. NOT awaited: a push future
      // completes only when the route pops — awaiting it here would
      // suspend the test forever (it did: this file hung every full
      // run until the await was removed).
      unawaited(navigatorKey.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('SECRET SCREEN')))));
      await tester.pumpAndSettle();
      expect(find.text('SECRET SCREEN'), findsOneWidget);

      // Background → return, through the LEGAL transition chain
      // (resumed → inactive → hidden → paused → hidden → inactive →
      // resumed): a direct paused → resumed jump is an invalid
      // transition the framework asserts on, and the aborted
      // dispatch never reaches the Gate's observer.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      // The lock transition is synchronous inside the observer: the
      // routes are popped and the locked state published before any
      // frame runs. (The mocked auth then succeeds and unlocks again
      // — that's the prompt answering, not the lock failing.)
      expect(CaptureNotify.gateLocked.value, isTrue,
          reason: 'the return from background re-locks');
      // The popped route leaves the tree when its exit animation
      // finishes — give it generous fake time.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('SECRET SCREEN'), findsNothing,
          reason: 'a locked app must not leave a usable screen on top');
    });
  });

  group('captureImage progress dialog', () {
    testWidgets(
        'caller disposed mid-OCR: the non-dismissible spinner is removed',
        (tester) async {
      appState.settings = const AppSettings();
      BuildContext? callerCtx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            callerCtx = context;
            return const Scaffold(body: Text('caller'));
          }),
        ),
      );
      // ML Kit has no platform side in tests, so OCR fails fast; the
      // progress dialog is up first. The flow future is deliberately
      // NOT awaited (the receipt_scan_test rule): awaiting it inside
      // testWidgets deadlocks the fake-async zone. Its completion is
      // tracked with a flag and driven by runAsync windows — the ML
      // Kit channel reply only lands in the real async zone.
      var flowDone = false;
      unawaited(capture_flow
          .captureImage(callerCtx!, '/nonexistent.png')
          .then((_) => flowDone = true)
          .catchError((_) => flowDone = true));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'the OCR progress dialog is showing');

      // The Gate swaps the shell for the lock screen: the caller's
      // whole subtree unmounts while the dialog route (on the root
      // navigator) survives.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('LOCK SCREEN'))),
      );
      // Let OCR's failure land and the flow finish: real-async
      // windows for the channel reply, pumps for the frames.
      for (var i = 0; i < 20 && !flowDone; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
      expect(flowDone, isTrue, reason: 'the flow completed');
      expect(find.byType(AlertDialog), findsNothing,
          reason:
              'the progress dialog must be dismissed via its route even '
              'when the caller is gone — before the fix it stayed on '
              'top forever and the app was soft-bricked');
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('POST_NOTIFICATIONS prompt flag', () {
    testWidgets(
        'an unmounted caller does not burn the ask-once flag',
        (tester) async {
      appState.settings = const AppSettings();
      BuildContext? callerCtx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            callerCtx = context;
            return const Scaffold(body: Text('caller'));
          }),
        ),
      );
      // Dispose the caller (Gate teardown), then try to prompt.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('LOCK SCREEN'))),
      );
      CaptureNotify.maybePromptPermission(callerCtx!);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('capture_notif_prompted_v1'), isNot(true),
          reason:
              'the flag is spent only when the dialog actually renders; '
              'before the fix a first capture around a lock screen '
              'burned it and the rationale never appeared, ever');
    });
  });
}
