import 'package:flutter/material.dart';

import '../models/purposes.dart';

/// Large one-tap purpose buttons. The heart of the 5-second capture.
class PurposeGrid extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;
  final String? suggested;
  final String? suggestionReason;

  const PurposeGrid({
    super.key,
    required this.selected,
    required this.onSelect,
    this.suggested,
    this.suggestionReason,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (suggested != null && suggested != selected)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () => onSelect(suggested!),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(purposeIcon(suggested!),
                        size: 20,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Suggested: ${purposeLabel(suggested!)}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          if (suggestionReason != null)
                            Text(suggestionReason!,
                                style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    TextButton(
                        onPressed: () => onSelect(suggested!),
                        child: const Text('Use')),
                  ],
                ),
              ),
            ),
          ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.5,
          ),
          itemCount: kPurposes.length,
          itemBuilder: (context, i) {
            final p = kPurposes[i];
            final isSel = p.id == selected;
            return InkWell(
              onTap: () => onSelect(p.id),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                decoration: BoxDecoration(
                  color: isSel
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(p.icon,
                        color: isSel
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(height: 4),
                    Text(
                      p.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            isSel ? FontWeight.bold : FontWeight.normal,
                        color: isSel
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
