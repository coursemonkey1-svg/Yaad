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
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (_, i) {
              final a = items[i];
              return ListTile(
                leading: const Icon(Icons.label_outline),
                title: Text(a.alias,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(a.rawName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text('×${a.usageCount}',
                    style: Theme.of(context).textTheme.bodySmall),
                onTap: () => _edit(context, a),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, null),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _edit(BuildContext context, MerchantAlias? existing) async {
    final s = Strings(appState.settings.language);
    final rawCtrl = TextEditingController(text: existing?.rawName ?? '');
    final aliasCtrl = TextEditingController(text: existing?.alias ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
            existing == null ? s.get('addYourName') : s.get('editName')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: rawCtrl,
                decoration: InputDecoration(
                    labelText: s.get('bankLabelExactly'))),
            const SizedBox(height: 8),
            TextField(
                controller: aliasCtrl,
                decoration: InputDecoration(
                    labelText: s.get('yourNameForIt'))),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.get('cancel'))),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(s.get('save'))),
        ],
      ),
    );
    if (ok == true &&
        rawCtrl.text.trim().isNotEmpty &&
        aliasCtrl.text.trim().isNotEmpty) {
      await YaadDb.upsertAlias(rawCtrl.text, aliasCtrl.text);
      appState.refresh();
      if (mounted) setState(() {});
    }
    rawCtrl.dispose();
    aliasCtrl.dispose();
  }
}
