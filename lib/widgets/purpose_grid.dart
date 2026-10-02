import 'package:flutter/material.dart';

import '../models/purposes.dart';

/// Large one-tap purpose buttons. The heart of the 5-second capture.
///
/// [customIds] marks user-created purposes: long-pressing one calls
/// [onDeleteCustom] (confirm + delete lives with the caller). The fixed
/// list can never be deleted. [onAddCustom] appends a "+ New" tile that
/// opens the create-purpose dialog.
class PurposeGrid extends StatelessWidget {
  final List<Purpose> purposes;
  final String selected;
  final ValueChanged<String> onSelect;
  final String? suggested;
  final String? suggestionReason;
  final Set<String> customIds;
  final VoidCallback? onAddCustom;

  /// Label for the "New" tile (localized by the caller). The tile
  /// already shows a "+" icon — the label must NOT start with one
  /// (a doubled "+ ＋ New" reads as a typo).
  final String newTileLabel;
  final ValueChanged<String>? onDeleteCustom;

  const PurposeGrid({
    super.key,
    required this.purposes,
    required this.selected,
    required this.onSelect,
    this.suggested,
    this.suggestionReason,
    this.customIds = const {},
    this.onAddCustom,
    this.newTileLabel = 'New',
    this.onDeleteCustom,
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
          itemCount: purposes.length + (onAddCustom != null ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == purposes.length) return _newTile(context);
            final p = purposes[i];
            final isSel = p.id == selected;
            final isCustom = customIds.contains(p.id);
            return GestureDetector(
              onLongPress: isCustom && onDeleteCustom != null
                  ? () => onDeleteCustom!(p.id)
                  : null,
              child: InkWell(
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
                      // A long custom-purpose name ellipsizes inside
                      // its tile instead of overflowing the grid cell.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
            ),
          );
          },
        ),
      ],
    );
  }

  /// The "+ New" tile (plus icon + label). Label comes from the caller.'s strings.
  Widget _newTile(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onAddCustom,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant, width: 1.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, color: scheme.primary),
            const SizedBox(height: 4),
            Text(
              newTileLabel,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}
