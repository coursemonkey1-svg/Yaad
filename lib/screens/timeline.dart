import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/transaction.dart';
import '../models/purposes.dart';
import 'home.dart';

/// Transaction timeline with search and filters.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key});
  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  String _query = '';
  String? _purpose;
  TxnDirection? _direction;
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(s.get('activity'))),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: s.get('search'),
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  _chip(s.get('all'), _purpose == null && _direction == null,
                      () => setState(() {
                            _purpose = null;
                            _direction = null;
                          })),
                  _chip(s.get('moneyOut'), _direction == TxnDirection.out,
                      () => setState(() {
                            _direction = _direction == TxnDirection.out
                                ? null
                                : TxnDirection.out;
                            _purpose = null;
                          })),
                  _chip(s.get('moneyIn'), _direction == TxnDirection.incoming,
                      () => setState(() {
                            _direction =
                                _direction == TxnDirection.incoming
                                    ? null
                                    : TxnDirection.incoming;
                            _purpose = null;
                          })),
                  for (final p in kPurposes)
                    _chip(p.label, _purpose == p.id, () {
                      setState(() {
                        _purpose = _purpose == p.id ? null : p.id;
                        _direction = null;
                      });
                    }),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<YaadTransaction>>(
                future: YaadDb.txns(
                    limit: 500,
                    query: _query.isEmpty ? null : _query,
                    purpose: _purpose),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }
                  var items = snap.data!;
                  if (_direction != null) {
                    items = items
                        .where((t) => t.direction == _direction)
                        .toList();
                  }
                  if (items.isEmpty) {
                    return Center(child: Text(s.get('noTransactions')));
                  }
                  return ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) => TxnRow(txn: items[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FilterChip(
          label: Text(label), selected: selected, onSelected: (_) => onTap()),
    );
  }
}
