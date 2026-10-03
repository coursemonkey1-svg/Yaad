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
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _open(InboxEntry e) async {
    final s = Strings(appState.settings.language);
    await CaptureInbox.instance.markRead(e.id);
    final txn = await YaadDb.txnById(e.txnId);
    if (!mounted) return;
    if (txn == null) {
      // The transaction is gone (deleted from Activity): prune the
      // entry so it doesn't sit in the inbox failing forever.
      await CaptureInbox.instance.removeEntry(e.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.get('captureTxnGone'))));
      return;
    }
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TransactionViewScreen(txn: txn)));
    // The transaction may have been deleted from its own detail view —
    // prune the entry instead of leaving a dead row behind. The list
    // itself is live (ListenableBuilder on the inbox), so pruning is
    // all that is needed here.
    final stillThere = await YaadDb.txnById(e.txnId);
    if (stillThere == null) {
      await CaptureInbox.instance.removeEntry(e.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(s.get('inboxTitle'))),
      // Live list: the inbox is a ChangeNotifier (the shell's bell
      // already listens to it) — entries arriving while this screen
      // is open appear immediately instead of waiting for a re-entry
      // the user may never make.
      body: ListenableBuilder(
        listenable: CaptureInbox.instance,
        builder: (context, _) {
          final items = CaptureInbox.instance.entries;
          if (!_loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) {
            return Center(
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
            );
          }
          return ListView.separated(
            // End-of-list clearance: the last entry must be able
            // to scroll fully clear of the bottom system bar /
            // gesture area and of floating UI the size of the
            // shell's Add FAB (56 + its margins ≈ 88) — user
            // screenshots showed the FAB covering list content.
            // Providing an explicit padding replaces ListView's
            // automatic safe-area padding, so the view inset is
            // included here explicitly.
            padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom + 88),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final e = items[i];
              final merchant = e.merchant.trim();
              // Swipe to dismiss: until now a bogus entry could only
              // be removed by deleting the real transaction or
              // waiting for the 50-entry cap to evict it.
              return Dismissible(
                key: ValueKey(e.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: cs.errorContainer,
                  alignment: AlignmentDirectional.centerEnd,
                  padding: const EdgeInsetsDirectional.only(end: 20),
                  child: Icon(Icons.delete_outline,
                      color: cs.onErrorContainer),
                ),
                onDismissed: (_) =>
                    CaptureInbox.instance.removeEntry(e.id),
                child: ListTile(
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
                    merchant.isEmpty ? s.get('captureBankAlert') : merchant,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(appState.formatDate(e.time)),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Signed: money out and money in must not look
                      // identical (they did — every amount rendered
                      // as a bare positive number).
                      Text(
                          '${e.isOut ? '−' : '+'} ${appState.money(e.amount)}',
                          style:
                              const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      e.needsReview
                          ? ActionChip(
                              label: Text(s.get('needsReview')),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const ReviewScreen())),
                            )
                          : Chip(
                              label: Text(s.get('captureRecorded')),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
