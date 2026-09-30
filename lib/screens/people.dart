import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/lending.dart';
import '../models/person.dart';
import 'person_detail.dart';

/// People & Balances: everyone you lend to / borrow from,
/// with live outstanding balances.
class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key});

  Future<List<_PersonBalance>> _load() async {
    final people = await YaadDb.people();
    final out = <_PersonBalance>[];
    for (final p in people) {
      final records = await YaadDb.lendingForPerson(p.id);
      double owedToMe = 0, iOwe = 0;
      int open = 0;
      for (final l in records) {
        if (l.status == LendingStatus.settled ||
            l.status == LendingStatus.writtenOff ||
            l.status == LendingStatus.gift) {
          continue;
        }
        final repaid = await YaadDb.totalRepaid(l.id);
        final remaining = l.originalAmount - repaid;
        if (remaining <= 0.005) continue;
        open++;
        if (l.isOwedToMe) {
          owedToMe += remaining;
        } else {
          iOwe += remaining;
        }
      }
      out.add(_PersonBalance(p, owedToMe, iOwe, open));
    }
    out.sort((a, b) =>
        (b.owedToMe + b.iOwe).compareTo(a.owedToMe + a.iOwe));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(s.get('people'))),
        body: FutureBuilder<List<_PersonBalance>>(
          future: _load(),
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
                      const Icon(Icons.group_outlined, size: 64),
                      const SizedBox(height: 12),
                      const Text(
                          'No lending records yet.\nTap + then "I lent money" to start.',
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
              );
            }
            return ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final b = items[i];
                final net = b.owedToMe - b.iOwe;
                return ListTile(
                  leading: CircleAvatar(
                      child: Text(b.person.name.isEmpty
                          ? '?'
                          : b.person.name[0].toUpperCase())),
                  title: Text(b.person.name,
                      style:
                          const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(b.open == 0
                      ? 'All settled'
                      : '${b.open} open balance${b.open == 1 ? '' : 's'}'),
                  trailing: Text(
                    net == 0
                        ? '—'
                        : '${net > 0 ? '' : '−'}${appState.money(net.abs())}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: net > 0
                          ? Colors.green
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(
                          builder: (_) =>
                              PersonDetailScreen(person: b.person)))
                      .then((_) => appState.refresh()),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _PersonBalance {
  final Person person;
  final double owedToMe;
  final double iOwe;
  final int open;
  _PersonBalance(this.person, this.owedToMe, this.iOwe, this.open);
}
