import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'l10n/strings.dart';
import 'app_lock_guard.dart';
import 'data/db.dart';
import 'services/app_state.dart';
import 'services/capture_flow.dart';
import 'services/capture_inbox.dart';
import 'services/capture_notify.dart';
import 'services/ocr.dart';
import 'services/pro.dart';
import 'services/sms_capture.dart';
import 'theme.dart';
import 'widgets/guided_tour.dart';
import 'screens/onboarding.dart';
import 'screens/home.dart';
import 'screens/inbox.dart';
import 'screens/review.dart';
import 'screens/timeline.dart';
import 'screens/udhaar.dart';
import 'screens/settings.dart';
import 'screens/capture.dart';
import 'screens/confirm.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final appState = AppState();
final proService = ProService();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones(); // on-device IANA database (free, offline)
  await appState.load();
  // Custom purpose labels live in SQLite; register them so
  // purposeLabel()/purposeIcon() resolve them everywhere.
  try {
    await YaadDb.refreshCustomPurposeRegistry();
  } catch (_) {
    // Non-fatal: custom ids fall back to "Other" until the next refresh.
  }
  // One-time Pro plumbing (dormant until billing is enabled).
  proService.onUnlocked = () {
    appState.update(appState.settings.copyWith(proUnlocked: true));
  };
  await proService.init();
  // Yaad's own notifications about auto-captured bank alerts (§v1.3).
  await CaptureNotify.init();
  await CaptureInbox.instance.load();
  runApp(const YaadApp());
  // Cold start via notification tap: navigate once the first frame is up.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    CaptureNotify.openPendingLaunch();
  });
}

class YaadApp extends StatelessWidget {
  const YaadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        if (!appState.ready) {
          return const MaterialApp(
              home: Scaffold(
                  body: Center(child: CircularProgressIndicator())));
        }
        final s = appState.settings;
        ThemeMode mode;
        switch (s.theme) {
          case 'light':
            mode = ThemeMode.light;
            break;
          case 'dark':
            mode = ThemeMode.dark;
            break;
          default:
            mode = ThemeMode.system;
        }
        final accent =
            ProService.canUseAccent(s, s.accentTheme) ? s.accentTheme : 'teal';
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Yaad',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: YaadTheme.light(accent),
          darkTheme: YaadTheme.dark(accent),
          home: s.onboardingDone ? const Gate() : const OnboardingScreen(),
        );
      },
    );
  }
}

/// Decides between app-lock screen and the main shell.
/// App lock is a Pro feature, grandfathered for v1.0 users.
class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> with WidgetsBindingObserver {
  bool _unlocked = false;
  bool _firstBuild = true;

  /// Plain-language reason shown on the lock screen when auth can't run.
  /// Never unlocks silently: failing closed with a message beats open.
  String? _authError;

  final _guard = AppLockGuard();

  bool get _appLockActive =>
      appState.settings.appLock &&
      ProService.canUseAppLock(appState.settings);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!_appLockActive) {
      _unlocked = true; // no app lock: straight in
    } else {
      _auth();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _guard.onPaused();
    } else if (state == AppLifecycleState.resumed) {
      if (_guard.onResumed(
          firstBuild: _firstBuild, appLockEnabled: _appLockActive)) {
        setState(() {
          _unlocked = false;
          _authError = null;
        });
        _auth();
      }
    }
  }

  Future<void> _auth() async {
    final s = Strings(appState.settings.language);
    final auth = LocalAuthentication();
    try {
      // Detect the hopeless case upfront: no device screen lock means the
      // system prompt can never succeed. Fail closed with a clear message.
      if (!await auth.isDeviceSupported()) {
        if (mounted) {
          setState(() {
            _unlocked = false;
            _authError = s.get('lockNotSupported');
          });
        }
        return;
      }
      final ok = await auth.authenticate(
        localizedReason: s.get('lockUnlockYaad'),
        options: const AuthenticationOptions(biometricOnly: false),
      );
      if (mounted) {
        setState(() {
          _unlocked = ok;
          _authError = null;
        });
      }
    } on PlatformException {
      // The prompt couldn't be shown. Stay locked and explain what to do —
      // never silently unlock on error.
      if (mounted) {
        setState(() {
          _unlocked = false;
          _authError = s.get('lockAuthFailed');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_firstBuild) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _firstBuild = false);
    }
    if (!_unlocked) {
      final s = Strings(appState.settings.language);
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 16),
                Text(s.get('lockUnlockYaad'),
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                if (_authError != null) ...[
                  const SizedBox(height: 12),
                  Text(_authError!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 16),
                FilledButton(
                    onPressed: _auth,
                    child: Text(s.get(_authError == null
                        ? 'lockUnlockButton'
                        : 'lockTryAgain'))),
              ],
            ),
          ),
        ),
      );
    }
    return const MainShell();
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _index = 0;
  late final StreamSubscription _mediaSub;
  final _ocr = OcrService();

  // Guided-tour spotlight targets. The nav bar swaps icon widgets when
  // selected, so selected/unselected states need separate keys.
  final _fabKey = GlobalKey();
  final _navKeys = [GlobalKey(), GlobalKey(), GlobalKey(), GlobalKey()];
  final _navKeysSel = [GlobalKey(), GlobalKey(), GlobalKey(), GlobalKey()];
  late final List<TourStep> _tourSteps;
  bool _tourActive = false;

  List<Widget> get _tabs => [
        HomeScreen(onGoToUdhaar: _goToUdhaar),
        const TimelineScreen(),
        const UdhaarScreen(),
        SettingsScreen(onTakeTour: _replayTour),
      ];

  void _goToUdhaar() => setState(() => _index = 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tourSteps = [
      TourStep(
          targetKey: _fabKey,
          tab: 0,
          titleKey: 'tourAddTitle',
          bodyKey: 'tourAddBody',
          hintKey: 'tourAddHint'),
      TourStep(
          targetKey: _navKeysSel[0],
          tab: 0,
          titleKey: 'tourHomeTitle',
          bodyKey: 'tourHomeBody'),
      TourStep(
          targetKey: _navKeysSel[1],
          tab: 1,
          titleKey: 'tourActivityTitle',
          bodyKey: 'tourActivityBody'),
      TourStep(
          targetKey: _navKeysSel[2],
          tab: 2,
          titleKey: 'tourUdhaarTitle',
          bodyKey: 'tourUdhaarBody'),
      TourStep(
          targetKey: _navKeysSel[3],
          tab: 3,
          titleKey: 'tourSettingsTitle',
          bodyKey: 'tourSettingsBody'),
    ];
    // Cold start: app opened via Share from the bank app / gallery.
    ReceiveSharingIntent.instance.getInitialMedia().then(_handleMedia);
    // Warm: already running.
    _mediaSub =
        ReceiveSharingIntent.instance.getMediaStream().listen(_handleMedia);
    // Import any queued bank alerts (SMS / notifications).
    _drainCapture();
    _maybeShowTour();
  }

  /// First launch only: show the guided tour once, after onboarding.
  void _maybeShowTour() {
    if (!GuidedTour.shouldShow(appState.settings)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !GuidedTour.shouldShow(appState.settings)) return;
      _startTour();
    });
  }

  void _startTour() {
    if (_tourActive) return;
    _tourActive = true;
    GuidedTour.show(
      context,
      steps: _tourSteps,
      strings: Strings(appState.settings.language),
      onStep: (i) => setState(() => _index = _tourSteps[i].tab),
      onFinish: _finishTour,
    ).then((_) => _tourActive = false);
  }

  /// Single tour exit path: persist `tourSeen` and land back on Home.
  void _finishTour() {
    if (mounted) setState(() => _index = 0);
    appState.update(appState.settings.copyWith(tourSeen: true));
  }

  /// Settings → "Take the tour": replay on demand, any time.
  void _replayTour() {
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startTour();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _drainCapture();
  }

  /// Imports queued bank alerts; nudges when some need a human eye.
  /// Auto-captured transactions also land in the inbox and raise one of
  /// Yaad's own phone notifications each (CaptureNotify handles both).
  Future<void> _drainCapture() async {
    final (recorded, review) =
        await CaptureService.drainAndImport(promptContext: context);
    if (!mounted || recorded + review == 0) return;
    final s = Strings(appState.settings.language);
    final messenger = ScaffoldMessenger.of(context);
    if (review > 0) {
      messenger.showSnackBar(SnackBar(
        content: Text(
            s.get('capturedReview').replaceFirst('{n}', '$review')),
        action: SnackBarAction(
          label: s.get('review'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const ReviewScreen())),
        ),
        duration: const Duration(seconds: 6),
      ));
    }
    if (recorded > 0) {
      messenger.showSnackBar(SnackBar(
        content: Text(s
            .get('capturedRecorded')
            .replaceFirst('{n}', '$recorded')),
        duration: const Duration(seconds: 3),
      ));
    }
  }

  void _handleMedia(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    final f = files.first;
    if (f.type == SharedMediaType.text) {
      _handleText(f.path);
    } else if (f.type == SharedMediaType.image) {
      // OCR with progress + error handling — never silent (§4).
      captureImage(context, f.path);
    }
  }

  void _handleText(String text) {
    final result = _ocr.parseText(text);
    // Never silent: open the confirm screen even when nothing was
    // parsed — the shared text is kept as the note.
    _openConfirm(result);
  }

  void _openConfirm(OcrResult result) {
    navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => ConfirmScreen(initial: result),
    ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mediaSub.cancel();
    _ocr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return Scaffold(
      // MainShell has no AppBar of its own — each tab screen owns one —
      // so the capture-inbox bell is pinned top-end, where an app-bar
      // action would sit. The end side of every tab's AppBar is empty,
      // and PositionedDirectional keeps it correct in Urdu RTL.
      body: Stack(
        children: [
          IndexedStack(index: _index, children: _tabs),
          PositionedDirectional(
            top: 0,
            end: 0,
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsetsDirectional.only(top: 4, end: 4),
                child: ListenableBuilder(
                  listenable: CaptureInbox.instance,
                  builder: (context, _) {
                    final n = CaptureInbox.instance.unreadCount;
                    return Badge(
                      isLabelVisible: n > 0,
                      label: Text('$n'),
                      child: IconButton(
                        tooltip: s.get('inboxTitle'),
                        icon:
                            const Icon(Icons.notifications_outlined),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const InboxScreen()),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: _fabKey,
        onPressed: () => showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => const QuickCaptureSheet(),
        ).then((_) => appState.refresh()),
        icon: const Icon(Icons.add),
        label: Text(s.get('add')),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
              icon: Icon(Icons.home_outlined, key: _navKeys[0]),
              selectedIcon: Icon(Icons.home, key: _navKeysSel[0]),
              label: s.get('home')),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined, key: _navKeys[1]),
              selectedIcon: Icon(Icons.receipt_long, key: _navKeysSel[1]),
              label: s.get('activity')),
          NavigationDestination(
              icon: Icon(Icons.handshake_outlined, key: _navKeys[2]),
              selectedIcon: Icon(Icons.handshake, key: _navKeysSel[2]),
              label: s.get('udhaar')),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined, key: _navKeys[3]),
              selectedIcon: Icon(Icons.settings, key: _navKeysSel[3]),
              label: s.get('settings')),
        ],
      ),
    );
  }
}
