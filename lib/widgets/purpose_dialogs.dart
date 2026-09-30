import 'package:flutter/material.dart';

import '../l10n/strings.dart';

/// Shared dialogs for user-created purposes. The delete rule lives with
/// the data layer ([YaadDb.deleteCustomPurpose]): transactions using a
/// deleted purpose are reassigned to 'uncategorized' ("Other").

/// Asks for a new custom-purpose name. Returns the trimmed name, or null
/// when cancelled.
Future<String?> promptCustomPurposeName(BuildContext context, Strings s) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.get('newPurpose')),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: s.get('purpose'),
          hintText: s.get('purposeNameHint'),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.get('cancel'))),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: Text(s.get('add')),
        ),
      ],
    ),
  );
}

/// Confirm dialog before deleting a custom purpose. Returns true when the
/// user confirms.
Future<bool> confirmDeleteCustomPurpose(
    BuildContext context, Strings s, String label) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.get('deletePurposeTitle')),
      content:
          Text(s.get('deletePurposeBody').replaceFirst('{name}', label)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.get('cancel'))),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error),
          child: Text(s.get('delete')),
        ),
      ],
    ),
  );
  return ok == true;
}
