import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/alias.dart';

/// Merchant aliases: your own recognizable names for confusing
/// bank labels. Edit inline; applied to matching transactions.
class AliasesScreen extends StatefulWidget {
  const AliasesScreen({super.key});
  @override
  State<AliasesScreen> createState() => _AliasesScreenState();
}

class _AliasesScreenState extends State<AliasesScreen> {
  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return Scaffold(
      appBar: AppBar(title: Text(s.get('aliasesTitle'))),
      body: FutureBuilder<List<MerchantAlias>>(
        future: YaadDb.allAliases(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.label_outline, size: 56),
                    const SizedBox(height: 12),
                    Text(s.get('noAliasesYet'),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(s.get('aliasEmpty'),
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(s.get('longPressAliasHint'),
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  // This screen has its own "+ Add" FAB — the last
                  // alias row must scroll fully clear of it.
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final a = items[i];
                    return ListTile(
                      leading: const Icon(Icons.label_outline),
                      title: Text(a.alias,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600)),
                      subtitle: Text(a.rawName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      trailing: Text('×${a.usageCount}',
                          style:
                              Theme.of(context).textTheme.bodySmall),
                      onTap: () => _edit(context, a),
                      onLongPress: () => _confirmDelete(context, a),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, null),
        child: const Icon(Icons.add),
      ),
    );
  }

  /// Deletes one alias row. YaadDb has no deleteAlias API, so this
  /// goes through its public database handle — the same table
  /// upsertAlias writes to.
  Future<void> _deleteAlias(MerchantAlias a) async {
    final d = await YaadDb.db;
    await d.delete('aliases', where: 'id = ?', whereArgs: [a.id]);
  }

  Future<void> _confirmDelete(
      BuildContext context, MerchantAlias a) async {
    final s = Strings(appState.settings.language);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.get('deleteAliasTitle')),
        content: Text(
            s.get('deleteAliasBody').replaceFirst('{name}', a.alias)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.get('cancel'))),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor:
                    Theme.of(context).colorScheme.error),
            child: Text(s.get('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _deleteAlias(a);
    appState.refresh();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(s.get('aliasDeleted').replaceFirst('{name}', a.alias))));
  }

  Future<void> _edit(BuildContext context, MerchantAlias? existing) async {
    final s = Strings(appState.settings.language);
    // The dialog owns (and disposes) its controllers — disposing them
    // here after the future completes crashes the exit animation.
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _AliasEditDialog(s: s, existing: existing),
    );
    if (result == null) return;
    final (raw, alias) = result;
    if (raw.isEmpty || alias.isEmpty) {
      // Say so — silently closing made it look saved when it wasn't.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.get('aliasFillBoth'))));
      }
      return;
    }
    await YaadDb.upsertAlias(raw, alias);
    // Editing the bank label itself: the alias MOVES to the new
    // label — without this the old row stayed behind as a
    // duplicate pointing at the same name.
    if (existing != null && existing.rawName != raw) {
      await _deleteAlias(existing);
    }
    appState.refresh();
    if (mounted) setState(() {});
  }
}

/// The add/edit alias dialog. Owns its text controllers and disposes
/// them in [State.dispose] — only once the dialog route (and its exit
/// animation) is fully gone. Pops the trimmed (rawName, alias) pair,
/// or null when cancelled.
class _AliasEditDialog extends StatefulWidget {
  final Strings s;
  final MerchantAlias? existing;
  const _AliasEditDialog({required this.s, required this.existing});

  @override
  State<_AliasEditDialog> createState() => _AliasEditDialogState();
}

class _AliasEditDialogState extends State<_AliasEditDialog> {
  late final TextEditingController _rawCtrl =
      TextEditingController(text: widget.existing?.rawName ?? '');
  late final TextEditingController _aliasCtrl =
      TextEditingController(text: widget.existing?.alias ?? '');

  @override
  void dispose() {
    _rawCtrl.dispose();
    _aliasCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return AlertDialog(
      title: Text(
          widget.existing == null ? s.get('addYourName') : s.get('editName')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
              controller: _rawCtrl,
              maxLength: 80,
              decoration:
                  InputDecoration(labelText: s.get('bankLabelExactly'))),
          const SizedBox(height: 8),
          TextField(
              controller: _aliasCtrl,
              maxLength: 60,
              decoration:
                  InputDecoration(labelText: s.get('yourNameForIt'))),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.get('cancel'))),
        FilledButton(
            onPressed: () => Navigator.of(context)
                .pop((_rawCtrl.text.trim(), _aliasCtrl.text.trim())),
            child: Text(s.get('save'))),
      ],
    );
  }
}
