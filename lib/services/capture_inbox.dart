import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// One auto-captured bank alert, as listed in the inbox.
@immutable
class InboxEntry {
  final String id;
  final String txnId;
  final String merchant;
  final double amount;
  final DateTime time;
  final bool needsReview;
  final bool read;

  const InboxEntry({
    required this.id,
    required this.txnId,
    required this.merchant,
    required this.amount,
    required this.time,
    required this.needsReview,
    this.read = false,
  });

  InboxEntry markRead() => InboxEntry(
        id: id,
        txnId: txnId,
        merchant: merchant,
        amount: amount,
        time: time,
        needsReview: needsReview,
        read: true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'txnId': txnId,
        'merchant': merchant,
        'amount': amount,
        'time': time.toIso8601String(),
        'needsReview': needsReview,
        'read': read,
      };

  factory InboxEntry.fromJson(Map<String, dynamic> j) => InboxEntry(
        id: '${j['id'] ?? ''}',
        txnId: '${j['txnId'] ?? ''}',
        merchant: '${j['merchant'] ?? ''}',
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        time: DateTime.tryParse('${j['time'] ?? ''}') ?? DateTime.now(),
        needsReview: j['needsReview'] == true,
        read: j['read'] == true,
      );
}

/// In-app inbox of auto-captured bank alerts (§v1.3 autocap).
///
/// Backed by SharedPreferences (a single JSON list) — deliberately NOT
/// SQLite, so this never needs a database migration. Newest first,
/// capped at 50 entries (oldest evicted).
class CaptureInbox extends ChangeNotifier {
  /// App-wide singleton used by the UI.
  static final CaptureInbox instance = CaptureInbox();

  /// Public constructor so tests can use isolated instances.
  CaptureInbox();

  static const storageKey = 'capture_inbox_v1';
  static const maxEntries = 50;

  List<InboxEntry> _entries = [];
  bool _loaded = false;

  List<InboxEntry> get entries => List.unmodifiable(_entries);

  /// Badge count: unread entries. Clears when the inbox is opened.
  int get unreadCount => _entries.where((e) => !e.read).length;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _entries = list
            .whereType<Map>()
            .map((m) => InboxEntry.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      } catch (_) {
        _entries = [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        storageKey, jsonEncode(_entries.map((e) => e.toJson()).toList()));
  }

  Future<void> add({
    required String txnId,
    required String merchant,
    required double amount,
    required DateTime time,
    required bool needsReview,
  }) async {
    if (!_loaded) await load();
    _entries.insert(
      0,
      InboxEntry(
        id: const Uuid().v4(),
        txnId: txnId,
        merchant: merchant,
        amount: amount,
        time: time,
        needsReview: needsReview,
      ),
    );
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    await _save();
    notifyListeners();
  }

  Future<void> markRead(String id) async {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0 || _entries[i].read) return;
    _entries[i] = _entries[i].markRead();
    await _save();
    notifyListeners();
  }

  Future<void> markAllRead() async {
    if (unreadCount == 0) return;
    _entries = _entries.map((e) => e.markRead()).toList();
    await _save();
    notifyListeners();
  }
}
