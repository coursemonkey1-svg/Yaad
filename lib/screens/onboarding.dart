import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../main.dart';

/// 3-page intro. One "Get started" tap — no accounts, no sign-up, no server.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _page = PageController();
  int _i = 0;

  Future<void> _done() async {
    await appState.update(
        appState.settings.copyWith(onboardingDone: true));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const Gate()));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final pages = [
      _Page(Icons.psychology_outlined, s.get('onboarding1t'),
          s.get('onboarding1s')),
      _Page(Icons.bolt_outlined, s.get('onboarding2t'), s.get('onboarding2s')),
      _Page(Icons.handshake_outlined, s.get('onboarding3t'),
          s.get('onboarding3s')),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _page,
                onPageChanged: (i) => setState(() => _i = i),
                itemCount: pages.length,
                itemBuilder: (_, i) => pages[i],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                pages.length,
                (i) => Container(
                  margin: const EdgeInsets.all(4),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == _i
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  if (_i < pages.length - 1)
                    TextButton(
                        onPressed: _done, child: Text(s.get('skip'))),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      if (_i < pages.length - 1) {
                        _page.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut);
                      } else {
                        _done();
                      }
                    },
                    child: Text(_i < pages.length - 1
                        ? '→'
                        : s.get('getStarted')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  const _Page(this.icon, this.title, this.sub);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon,
              size: 96, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 32),
          Text(title,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Text(sub,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}
