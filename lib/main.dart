import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'l10n/strings.dart';
import 'services/app_state.dart';
import 'services/ocr.dart';
import 'screens/onboarding.dart';
import 'screens/home.dart';
import 'screens/timeline.dart';
import 'screens/people.dart';
import 'screens/settings.dart';
import 'screens/capture.dart';
import 'screens/confirm.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final appState = AppState();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones(); // on-device IANA database (free, offline)
  await appState.load();
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
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Yaad',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: ThemeData(
              colorSchemeSeed: Colors.teal, useMaterial3: true),
          darkTheme: ThemeData(
              colorSchemeSeed: Colors.teal,
              brightness: Brightness.dark,
              useMaterial3: true),
          home: s.onboardingDone ? const Gate() : const OnboardingScreen(),
        );
      },
    );
  }
}

/// Decides between app-lock screen and the main shell.
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
    if (!appState.settings.appLock) {
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

class _MainShellState extends State<MainShell> {
  int _index = 0;
  late final StreamSubscription _mediaSub;
  final _ocr = OcrService();

  static const _tabs = [
    HomeScreen(),
    TimelineScreen(),
    PeopleScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // Cold start: app opened via Share from Meezan / gallery.
    ReceiveSharingIntent.instance.getInitialMedia().then(_handleMedia);
    // Warm: already running.
    _mediaSub =
        ReceiveSharingIntent.instance.getMediaStream().listen(_handleMedia);
  }

  void _handleMedia(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    final f = files.first;
    if (f.type == SharedMediaType.text) {
      // Shared receipt text (e.g. Meezan's Share button).
      _handleText(f.path);
    } else if (f.type == SharedMediaType.image) {
      _ocr.fromImage(f.path).then((result) {
        _openConfirm(result.copyWith(imagePath: f.path));
      });
    }
  }

  void _handleText(String text) {
    final result = _ocr.parseText(text);
    _openConfirm(result);
  }

  void _openConfirm(OcrResult result) {
    navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => ConfirmScreen(initial: result),
    ));
  }

  @override
  void dispose() {
    _mediaSub.cancel();
    _ocr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      floatingActionButton: FloatingActionButton.large(
        onPressed: () => showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => const QuickCaptureSheet(),
        ).then((_) => appState.refresh()),
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
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
              icon: const Icon(Icons.group_outlined),
              selectedIcon: const Icon(Icons.group),
              label: s.get('people')),
          NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: s.get('settings')),
        ],
      ),
    );
  }
}
