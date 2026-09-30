import 'package:flutter/material.dart';

import '../data/db.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('My names for shops')),
      body: FutureBuilder<List<MerchantAlias>>(
        future: YaadDb.allAliases(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No saved names yet.\nWhen you add a note like "corner grocery near home" to a confusing bank label, it is remembered here and suggested next time.',
                  textAlign: TextAlign.center,
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
    final rawCtrl = TextEditingController(text: existing?.rawName ?? '');
    final aliasCtrl = TextEditingController(text: existing?.alias ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(existing == null ? 'Add your own name' : 'Edit name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: rawCtrl,
                decoration: const InputDecoration(
                    labelText: 'Bank label (exactly as shown)')),
            const SizedBox(height: 8),
            TextField(
                controller: aliasCtrl,
                decoration: const InputDecoration(
                    labelText: 'Your name for it')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save')),
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
