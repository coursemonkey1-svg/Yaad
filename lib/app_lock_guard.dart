/// Decides whether the [Gate] must lock again after the app returns from the
/// background.
///
/// Pure logic with no platform calls (local_auth can't run in unit tests),
/// so the re-lock decision itself is testable in isolation.
class AppLockGuard {
  bool _backgrounded = false;

  /// Call when the lifecycle hits paused/inactive.
  void onPaused() {
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
    final wasBackgrounded = _backgrounded;
    _backgrounded = false;
    if (!appLockEnabled || firstBuild) return false;
    return wasBackgrounded;
  }
}
