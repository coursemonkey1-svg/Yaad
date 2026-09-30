import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../main.dart';
import '../theme.dart';

/// Shared UI atoms: designed empty/loading/error states and
/// section headers, so every screen speaks the same visual language.

/// A designed empty state: icon, plain-words title + guidance,
/// optional action. Used on every screen (§1: "this is for this").
class YaadEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  const YaadEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: cs.primary),
            ),
            const SizedBox(height: Gap.x2),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.x1),
            Text(body,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Gap.x3),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Section header: bold title + optional "see all" action.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title,
            style:
                const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

/// Big money text with the app's grouping format.
class MoneyText extends StatelessWidget {
  final double amount;
  final double size;
  final FontWeight weight;
  final Color? color;

  const MoneyText(this.amount,
      {super.key,
      this.size = 32,
      this.weight = FontWeight.bold,
      this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      appState.money(amount),
      style: TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()]),
    );
  }
}

/// Loading skeleton for lists: shimmer-free, simple pulsing bars.
class YaadLoading extends StatelessWidget {
  const YaadLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.all(Gap.x2),
      itemCount: 5,
      itemBuilder: (_, __) => Container(
        height: 72,
        margin: const EdgeInsets.only(bottom: Gap.x1 + 4),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Radius.tile),
        ),
      ),
    );
  }
}

/// Error state with a next step.
class YaadErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const YaadErrorState(
      {super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return YaadEmptyState(
      icon: Icons.error_outline,
      title: s.get('somethingWrong'),
      body: message,
      actionLabel: s.get('retry'),
      onAction: onRetry,
    );
  }
}
