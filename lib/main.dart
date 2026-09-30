import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'l10n/strings.dart';
import 'services/app_state.dart';
import 'services/capture_flow.dart';
import 'services/ocr.dart';
import 'services/pro.dart';
import 'services/sms_capture.dart';
import 'theme.dart';
import 'screens/onboarding.dart';
import 'screens/home.dart';
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
  // One-time Pro plumbing (dormant until billing is enabled).
  proService.onUnlocked = () {
    appState.update(appState.settings.copyWith(proUnlocked: true));
  };
  await proService.init();
  runApp(const YaadApp());
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

class _GateState extends State<Gate> {
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    final s = appState.settings;
    if (!s.appLock || !ProService.canUseAppLock(s)) {
      _unlocked = true;
    } else {
      _auth();
    }
  }

  Future<void> _auth() async {
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'Unlock Yaad',
        options: const AuthenticationOptions(biometricOnly: false),
      );
      if (mounted) setState(() => _unlocked = ok);
    } on PlatformException {
      if (mounted) setState(() => _unlocked = true); // no biometrics enrolled
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_unlocked) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48),
              const SizedBox(height: 16),
              const Text('Unlock Yaad',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: _auth, child: const Text('Unlock')),
            ],
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

  List<Widget> get _tabs => [
        HomeScreen(onGoToUdhaar: _goToUdhaar),
        const TimelineScreen(),
        const UdhaarScreen(),
        const SettingsScreen(),
      ];

  void _goToUdhaar() => setState(() => _index = 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Cold start: app opened via Share from the bank app / gallery.
    ReceiveSharingIntent.instance.getInitialMedia().then(_handleMedia);
    // Warm: already running.
    _mediaSub =
        ReceiveSharingIntent.instance.getMediaStream().listen(_handleMedia);
    // Import any queued bank alerts (SMS / notifications).
    _drainCapture();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _drainCapture();
  }

  /// Imports queued bank alerts; nudges when some need a human eye.
  Future<void> _drainCapture() async {
    final (recorded, review) = await CaptureService.drainAndImport();
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
      body: IndexedStack(index: _index, children: _tabs),
      floatingActionButton: FloatingActionButton.extended(
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
              icon: const Icon(Icons.home_outlined),
              selectedIcon: const Icon(Icons.home),
              label: s.get('home')),
          NavigationDestination(
              icon: const Icon(Icons.receipt_long_outlined),
              selectedIcon: const Icon(Icons.receipt_long),
              label: s.get('activity')),
          NavigationDestination(
              icon: const Icon(Icons.handshake_outlined),
              selectedIcon: const Icon(Icons.handshake),
              label: s.get('udhaar')),
          NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: s.get('settings')),
        ],
      ),
    );
  }
}
