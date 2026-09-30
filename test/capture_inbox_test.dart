import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaad/services/capture_inbox.dart';
import 'package:yaad/services/capture_payload.dart';

/// Auto-capture inbox store + notification payload parsing (§v1.3 autocap).
/// Pure unit tests: no plugin, no platform channels, no database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // setMockInitialValues nullifies the cached singleton, so each test
  // gets a fresh, isolated SharedPreferences.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('CaptureInbox', () {
    test('adds entries newest-first', () async {
      final inbox = CaptureInbox();
      await inbox.add(
          txnId: 't1',
          merchant: 'Meezan',
          amount: 5000,
          time: DateTime(2026, 9, 1),
          needsReview: false);
      await inbox.add(
          txnId: 't2',
          merchant: 'KFC',
          amount: 1200,
          time: DateTime(2026, 9, 2),
          needsReview: true);
      expect(inbox.entries.map((e) => e.txnId), ['t2', 't1']);
      expect(inbox.unreadCount, 2);
    });

    test('caps at 50, oldest evicted', () async {
      final inbox = CaptureInbox();
      for (var i = 0; i < 55; i++) {
        await inbox.add(
            txnId: 't$i',
            merchant: 'm',
            amount: i.toDouble(),
            time: DateTime(2026, 1, 1).add(Duration(days: i)),
            needsReview: false);
      }
      expect(inbox.entries.length, 50);
      // Newest first: t54 down to t5; t0..t4 evicted.
      expect(inbox.entries.first.txnId, 't54');
      expect(inbox.entries.last.txnId, 't5');
      expect(inbox.entries.any((e) => e.txnId == 't4'), isFalse);
    });

    test('markRead / markAllRead clear the badge count', () async {
      final inbox = CaptureInbox();
      await inbox.add(
          txnId: 't1',
          merchant: 'a',
          amount: 1,
          time: DateTime(2026, 9, 1),
          needsReview: false);
      await inbox.add(
          txnId: 't2',
          merchant: 'b',
          amount: 2,
          time: DateTime(2026, 9, 2),
          needsReview: true);
      expect(inbox.unreadCount, 2);
      await inbox.markRead(inbox.entries.first.id);
      expect(inbox.unreadCount, 1);
      await inbox.markAllRead();
      expect(inbox.unreadCount, 0);
      // Re-marking is a no-op, not an error.
      await inbox.markAllRead();
      expect(inbox.unreadCount, 0);
    });

    test('persistence round-trip via SharedPreferences', () async {
      final a = CaptureInbox();
      final when = DateTime.utc(2026, 5, 1, 12, 30);
      await a.add(
          txnId: 'tx-9',
          merchant: 'Meezan',
          amount: 2500.5,
          time: when,
          needsReview: true);
      // A fresh instance loads what the first one saved.
      final b = CaptureInbox();
      await b.load();
      expect(b.entries.length, 1);
      final e = b.entries.first;
      expect(e.txnId, 'tx-9');
      expect(e.merchant, 'Meezan');
      expect(e.amount, 2500.5);
      expect(e.time.toUtc(), when);
      expect(e.needsReview, isTrue);
      expect(e.read, isFalse);
      expect(b.unreadCount, 1);
    });
  });

  group('capture notification payload', () {
    test('round-trips the transaction id', () {
      expect(txnIdFromPayload(capturePayload('abc-123')), 'abc-123');
    });

    test('rejects null, empty, and foreign payloads', () {
      expect(txnIdFromPayload(null), isNull);
      expect(txnIdFromPayload(''), isNull);
      expect(txnIdFromPayload('yaad://other/abc'), isNull);
      expect(txnIdFromPayload('yaad://capture/'), isNull);
    });
  });
}
