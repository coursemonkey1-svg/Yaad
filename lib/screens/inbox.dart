import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../services/capture_inbox.dart';
import 'transaction_view.dart';
import 'review.dart';

/// In-app inbox of auto-captured bank alerts (§v1.3 autocap).
/// Tapping an entry opens the read-only detail view; the editor is one
/// explicit Edit tap away from there.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  List<InboxEntry> _items = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await CaptureInbox.instance.load();
    // The badge clears the moment the inbox is opened.
    await CaptureInbox.instance.markAllRead();
    if (mounted) {
      setState(() {
        _items = CaptureInbox.instance.entries;
        _loaded = true;
      });
    }
  }

  Future<void> _open(InboxEntry e) async {
    final s = Strings(appState.settings.language);
    await CaptureInbox.instance.markRead(e.id);
    final txn = await YaadDb.txnById(e.txnId);
    if (!mounted) return;
    if (txn == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.get('captureTxnGone'))));
      return;
    }
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TransactionViewScreen(txn: txn)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(s.get('inboxTitle'))),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.notifications_none_outlined,
                            size: 64, color: cs.onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text(s.get('inboxEmpty'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = _items[i];
                    final merchant = e.merchant.trim();
                    return ListTile(
                      onTap: () => _open(e),
                      leading: CircleAvatar(
                        backgroundColor: e.needsReview
                            ? cs.tertiaryContainer
                            : cs.primaryContainer,
                        child: Icon(
                          e.needsReview
                              ? Icons.rate_review_outlined
                              : Icons.check,
                          color: e.needsReview
                              ? cs.onTertiaryContainer
                              : cs.onPrimaryContainer,
                        ),
                      ),
                      title: Text(
                        merchant.isEmpty
                            ? s.get('captureBankAlert')
                            : merchant,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(appState.formatDate(e.time)),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(appState.money(e.amount),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          e.needsReview
                              ? ActionChip(
                                  label: Text(s.get('needsReview')),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () =>
                                      Navigator.of(context).push(
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  const ReviewScreen())),
                                )
                              : Chip(
                                  label: Text(s.get('captureRecorded')),
                                  visualDensity: VisualDensity.compact,
                                ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
