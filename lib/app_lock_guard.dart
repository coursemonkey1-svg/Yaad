/// Maps a local_auth [PlatformException] code to the lock-screen string
/// key to show. Codes that mean "this phone has no usable screen lock"
/// get the dedicated set-a-screen-lock message; anything else gets the
/// generic try-again message. Pure, so the mapping is unit-testable
/// (local_auth itself can't run in tests).
String lockErrorKeyForPlatformCode(String? code) {
  switch (code) {
    case 'NotEnrolled':
    case 'PasscodeNotSet':
    case 'NotAvailable':
    case 'NoBiometricsEnrolled':
      return 'lockNotSupported';
    default:
      return 'lockAuthFailed';
  }
}

/// Decides whether the [Gate] must lock again after the app returns from the
/// background.
///
/// Pure logic with no platform calls (local_auth can't run in unit tests),
/// so the re-lock decision itself is testable in isolation.
class AppLockGuard {
  bool _backgrounded = false;

  /// True while Gate's own system auth prompt is on screen. Showing that
  /// prompt pauses/resumes the app by itself; those transitions must never
  /// re-lock, or every successful unlock would instantly lock again and the
  /// user could never get in (infinite lock loop).
  bool _authInFlight = false;

  /// Call when Gate starts/stops showing the system auth prompt.
  void setAuthInFlight(bool inFlight) {
    _authInFlight = inFlight;
  }

  /// Call when the lifecycle hits paused/inactive.
  void onPaused() {
    if (_authInFlight) return;
    _backgrounded = true;
  }

  /// Call when the lifecycle hits resumed.
  ///
  /// [firstBuild] is true while Gate's first build is in flight — auth
  /// already ran in initState, so a resume there must not relock.
  /// [appLockEnabled] is false when the app-lock setting is off or the plan
  /// doesn't cover it — the "straight in" path, no relock ever.
  ///
  /// Returns true when the gate must lock and re-run auth.
  bool onResumed({required bool firstBuild, required bool appLockEnabled}) {
    if (_authInFlight) return false;
    final wasBackgrounded = _backgrounded;
    _backgrounded = false;
    if (!appLockEnabled || firstBuild) return false;
    return wasBackgrounded;
  }
}
