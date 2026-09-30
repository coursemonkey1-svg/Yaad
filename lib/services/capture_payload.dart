/// Notification payload helpers for Yaad's own "bank alert captured"
/// notifications (§v1.3 autocap). Kept dependency-free and pure so the
/// payload -> txnId parsing is unit-testable without the notifications
/// plugin or any platform channels.

/// Builds the tap payload for a captured transaction.
String capturePayload(String txnId) => 'yaad://capture/$txnId';

/// Extracts the transaction id from a notification tap payload.
/// Returns null for null, empty, or foreign payloads.
String? txnIdFromPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  const prefix = 'yaad://capture/';
  if (!payload.startsWith(prefix)) return null;
  final id = payload.substring(prefix.length);
  return id.isEmpty ? null : id;
}
