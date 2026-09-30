import 'package:flutter/material.dart';

import '../data/db.dart';
import '../main.dart';
import '../models/transaction.dart';
import 'home.dart';

/// Needs Review inbox: every unannotated transaction, quick to clear.
/// No note is ever required — saving with a purpose is enough.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Needs review')),
        body: FutureBuilder<List<YaadTransaction>>(
          future: YaadDb.txns(status: TxnStatus.needsReview.name, limit: 500),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snap.data!;
            if (items.isEmpty) {
              return const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 64, color: Colors.green),
                    SizedBox(height: 12),
                    Text('All caught up!',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('Every transaction has its story.'),
                  ],
                ),
              );
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: LinearProgressIndicator(
                      value: 1 - items.length / (items.length + 1)),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                      '${items.length} to review — tap one, pick a purpose, done.'),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) => TxnRow(
                      txn: items[i],
                      onTap: null, // default: open editor
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
