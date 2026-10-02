import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/transaction.dart';
import '../theme.dart';
import '../widgets/atoms.dart';
import 'home.dart';

/// Needs Review inbox: every unannotated transaction, quick to clear.
/// No note is ever required — saving with a purpose is enough.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(s.get('needsReview'))),
        body: FutureBuilder<List<YaadTransaction>>(
          future: YaadDb.txns(status: TxnStatus.needsReview.name, limit: 500),
          builder: (context, snap) {
            if (snap.hasError) {
              return YaadErrorState(
                message: '${snap.error}',
                onRetry: () => appState.refresh(),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snap.data!;
            if (items.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_outline,
                        size: 64, color: Colors.green),
                    const SizedBox(height: 12),
                    Text(s.get('allCaughtUp'),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    Text(s.get('everyStory')),
                  ],
                ),
              );
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(s
                        .get('toReview')
                        .replaceFirst('{n}', '${items.length}')),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    // Bottom clearance so the last card never sits
                    // flush under the screen edge / gesture bar.
                    padding: const EdgeInsets.only(bottom: Gap.x4),
                    itemCount: items.length,
                    itemBuilder: (_, i) => TxnRow(
                      txn: items[i],
                      onTap: null, // default: open detail view
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
