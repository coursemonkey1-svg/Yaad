import 'package:flutter/material.dart';

import '../l10n/strings.dart';

/// Shared dialogs for user-created purposes. The delete rule lives with
/// the data layer ([YaadDb.deleteCustomPurpose]): transactions using a
/// deleted purpose are reassigned to 'uncategorized' ("Other").

/// Longest name a custom purpose may have. The picker tile is small;
/// anything longer would be unreadable there (and in lists) anyway.
const maxPurposeNameLength = 30;

/// Asks for a new custom-purpose name. Returns the trimmed name, or null
/// when cancelled. A blank name can neither be submitted nor confirmed —
/// the Add button stays disabled until something is typed, instead of
/// the dialog closing on an empty name the caller then silently drops.
Future<String?> promptCustomPurposeName(BuildContext context, Strings s) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PurposeNameDialog(s: s),
  );
}

/// The dialog as a StatefulWidget that OWNS its text controller and
/// disposes it in State.dispose — the codebase rule for dialog
/// controllers (see Accounts' _promptAccount): disposing from the
/// caller when the dialog future completes races the exit
/// animation, which rebuilds the field once more and crashes with
/// "used after being disposed"; never disposing leaks it.
class _PurposeNameDialog extends StatefulWidget {
  final Strings s;
  const _PurposeNameDialog({required this.s});

  @override
  State<_PurposeNameDialog> createState() => _PurposeNameDialogState();
}

class _PurposeNameDialogState extends State<_PurposeNameDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return AlertDialog(
      title: Text(s.get('newPurpose')),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: maxPurposeNameLength,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: s.get('purpose'),
          hintText: s.get('purposeNameHint'),
          border: const OutlineInputBorder(),
          counterText: '',
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (v) {
          final name = v.trim();
          if (name.isNotEmpty) Navigator.pop(context, name);
        },
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.get('cancel'))),
        TextButton(
          onPressed: _ctrl.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text(s.get('add')),
        ),
      ],
    );
  }
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
