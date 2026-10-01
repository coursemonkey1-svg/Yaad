import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/app_lock_guard.dart';

void main() {
  group('AppLockGuard', () {
    test('does not relock on the first build', () {
      final guard = AppLockGuard();
      guard.onPaused(); // even if a pause somehow arrived early…
      expect(guard.onResumed(firstBuild: true, appLockEnabled: true), isFalse);
    });

    test('relocks after pause then resume', () {
      final guard = AppLockGuard();
      guard.onPaused();
      expect(guard.onResumed(firstBuild: false, appLockEnabled: true), isTrue);
    });

    test('does not relock when app lock is disabled', () {
      final guard = AppLockGuard();
      guard.onPaused();
      expect(
          guard.onResumed(firstBuild: false, appLockEnabled: false), isFalse);
    });

    test('does not relock if the app never went to background', () {
      final guard = AppLockGuard();
      expect(guard.onResumed(firstBuild: false, appLockEnabled: true), isFalse);
    });

    test('relocks only once after a pause/resume pair', () {
      final guard = AppLockGuard();
      guard.onPaused();
      expect(guard.onResumed(firstBuild: false, appLockEnabled: true), isTrue);
      // Second resume without a new pause must not relock again.
      expect(
          guard.onResumed(firstBuild: false, appLockEnabled: true), isFalse);
    });

    test('disabled app lock clears a pending relock', () {
      final guard = AppLockGuard();
      guard.onPaused();
      expect(
          guard.onResumed(firstBuild: false, appLockEnabled: false), isFalse);
      // …and a later enable does not resurrect the old pause.
      expect(guard.onResumed(firstBuild: false, appLockEnabled: true), isFalse);
    });

    test('auth prompt pause/resume never relocks (no lock loop)', () {
      // Regression test: showing the system auth prompt pauses/resumes the
      // app by itself. Treating that as "user left the app" made every
      // successful unlock instantly lock again — the user could never get in.
      final guard = AppLockGuard();
      guard.setAuthInFlight(true);
      guard.onPaused(); // system prompt appears…
      expect(guard.onResumed(firstBuild: false, appLockEnabled: true), isFalse);
      guard.setAuthInFlight(false);
    });

    test('genuine backgrounding still relocks after a prompt finished', () {
      final guard = AppLockGuard();
      guard.setAuthInFlight(true);
      guard.onPaused();
      expect(guard.onResumed(firstBuild: false, appLockEnabled: true), isFalse);
      guard.setAuthInFlight(false);
      // Now the user really leaves the app…
      guard.onPaused();
      expect(guard.onResumed(firstBuild: false, appLockEnabled: true), isTrue);
    });
  });
}
