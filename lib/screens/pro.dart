import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../main.dart';
import '../theme.dart';

/// The Pro upsell — shown only when a locked Pro feature is tapped,
/// and only once billing is enabled (§11).
///
/// Positioning: "thank you, never ransom." The free tier stays magical;
/// Pro is for people who want to support Yaad and unlock power tools.
class ProScreen extends StatefulWidget {
  const ProScreen({super.key});

  @override
  State<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends State<ProScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _buy() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await proService.buyPro();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      // The purchase stream flips proUnlocked; close on next rebuild.
      Navigator.of(context).pop();
    } else {
      final s = Strings(appState.settings.language);
      setState(() => _error = s.get('proStoreUnavailable'));
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    await proService.restore();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    final price = proService.priceLabel;
    return Scaffold(
      appBar: AppBar(title: Text(s.get('yaadPro'))),
      body: ListView(
        padding: const EdgeInsets.all(Gap.x3),
        children: [
          Container(
            padding: const EdgeInsets.all(Gap.x3),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [cs.primary, cs.tertiary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(Radius.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.get('proTitle'),
                    style: TextStyle(
                        color: cs.onPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: Gap.x1),
                Text(s.get('proSubtitle'),
                    style: TextStyle(
                        color:
                            cs.onPrimary.withValues(alpha: 0.9),
                        fontSize: 15)),
              ],
            ),
          ),
          const SizedBox(height: Gap.x3),
          for (final f in [
            s.get('proF1'),
            s.get('proF2'),
            s.get('proF3'),
            s.get('proF4'),
            s.get('proF5'),
          ])
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: Gap.x1),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline,
                      color: cs.primary),
                  const SizedBox(width: Gap.x1 + 4),
                  Expanded(child: Text(f, style: const TextStyle(fontSize: 15))),
                ],
              ),
            ),
          const SizedBox(height: Gap.x3),
          FilledButton(
            onPressed: _busy ? null : _buy,
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54)),
            child: _busy
                ? const CircularProgressIndicator()
                : Text(price != null
                    ? s
                        .get('proBuy')
                        .replaceFirst('{price}', price)
                    : s.get('proBuyNoPrice')),
          ),
          const SizedBox(height: Gap.x1),
          TextButton(
              onPressed: _busy ? null : _restore,
              child: Text(s.get('restorePurchase'))),
          if (_error != null) ...[
            const SizedBox(height: Gap.x1),
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.error)),
          ],
          const SizedBox(height: Gap.x2),
          Text(s.get('proFinePrint'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
