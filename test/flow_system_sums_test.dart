import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/transaction.dart';

/// PROOF for the build-24 user report: a PKR 8,000 "Bank alert" spend
/// dated 28 Sep 2026 does not appear in Home's "Spent in October",
/// while an October bank alert does.
///
/// The sums path (YaadDb.sumByKind, used by Home via sumSpent /
/// sumReceived) filters on kind + status != 'excluded' + the date
/// window ONLY — there is no source filter anywhere (Home, Activity,
/// Summary were all audited). So a bank-alert row counts exactly like
/// a manual one IF its stored dateTime is in the month. The capture
/// drain (services/sms_capture.dart) stores the bank EVENT instant
/// (notification postTime / SMS receive time from the native queue),
/// kind from the alert direction, and status confirmed (high
/// confidence) or needsReview (medium) — both count, since only
/// 'excluded' is filtered out.
///
/// These tests seed rows built field-for-field the way the capture
/// drain writes them, and assert BOTH directions against the real
/// sumSpent over the real (timezone-aware) month windows Home uses.
/// All assertions are deltas, so the shared test DB can't interfere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const marker = 'FLOWSUMS PROOF';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    tzdata.initializeTimeZones(); // main() does this in production
  });

  tearDownAll(() async {
    final d = await YaadDb.db;
    await d.delete('transactions',
        where: 'rawMerchant LIKE ?', whereArgs: ['$marker%']);
  });

  YaadTransaction captureRow({
    required double amount,
    required DateTime dateTime,
    required TxnSource source,
    required TxnStatus status,
    String suffix = '',
  }) =>
      // Field-for-field what CaptureService._drain inserts for a
      // spend alert (see services/sms_capture.dart).
      YaadTransaction(
        amount: amount,
        currency: 'PKR',
        dateTime: dateTime,
        kind: TxnKind.spend,
        direction: TxnDirection.out,
        rawMerchant: '$marker$suffix',
        purpose: 'uncategorized',
        note: status == TxnStatus.needsReview ? 'bank alert body' : '',
        source: source,
        status: status,
        accountId: 'meezan',
      );

  test('bank-alert spend counts in its own month (current month)',
      () async {
    // The exact window Home uses: startOfMonthMs() (settings timezone)
    // through now. Rows are dated 5 minutes ago so they sit strictly
    // inside the window (a row dated "now" would land after a window
    // end captured microseconds earlier — in production the row
    // already exists when Home captures its `now`).
    final fromMs = appState.startOfMonthMs();
    final rowDate = DateTime.now().subtract(const Duration(minutes: 5));

    final before =
        await YaadDb.sumSpent(fromMs, DateTime.now().millisecondsSinceEpoch);

    // A notification-sourced spend, confirmed, dated today.
    await YaadDb.insertTxn(captureRow(
      amount: 8000,
      dateTime: rowDate,
      source: TxnSource.notification,
      status: TxnStatus.confirmed,
      suffix: ' NOTIF',
    ));
    expect(
        await YaadDb.sumSpent(
            fromMs, DateTime.now().millisecondsSinceEpoch),
        before + 8000,
        reason: 'a confirmed bank-alert spend must count like a manual one');

    // An SMS-sourced spend still awaiting review (medium confidence
    // in the drain) counts too: sums exclude only status=excluded.
    await YaadDb.insertTxn(captureRow(
      amount: 500,
      dateTime: rowDate,
      source: TxnSource.sms,
      status: TxnStatus.needsReview,
      suffix: ' SMS',
    ));
    expect(
        await YaadDb.sumSpent(
            fromMs, DateTime.now().millisecondsSinceEpoch),
        before + 8500,
        reason: 'needsReview is not excluded — it still counts');
  });

  test('a bank-alert spend dated LAST month does not pollute this '
      'month, and does count in its own month', () async {
    final loc = tz.getLocation(appState.settings.timezone);
    final nowTz = tz.TZDateTime.now(loc);
    // 28th of last month, midday in the user's timezone — the build-24
    // shape (28 Sep transfer viewed in October).
    final lastMonthRow =
        tz.TZDateTime(loc, nowTz.year, nowTz.month - 1, 28, 12);
    final lastMonthStart =
        tz.TZDateTime(loc, nowTz.year, nowTz.month - 1, 1);
    final thisMonthStart = tz.TZDateTime(loc, nowTz.year, nowTz.month, 1);
    final lastFrom = lastMonthStart.millisecondsSinceEpoch;
    final lastTo = thisMonthStart.millisecondsSinceEpoch - 1;

    final curFrom = appState.startOfMonthMs();
    final curTo = DateTime.now().millisecondsSinceEpoch;

    final curBefore = await YaadDb.sumSpent(curFrom, curTo);
    final lastBefore = await YaadDb.sumSpent(lastFrom, lastTo);

    await YaadDb.insertTxn(captureRow(
      amount: 8000,
      dateTime: DateTime.fromMillisecondsSinceEpoch(
          lastMonthRow.millisecondsSinceEpoch),
      source: TxnSource.notification,
      status: TxnStatus.confirmed,
      suffix: ' LASTMONTH',
    ));

    expect(await YaadDb.sumSpent(curFrom, curTo), curBefore,
        reason: 'a last-month bank alert must NOT inflate this month');
    expect(await YaadDb.sumSpent(lastFrom, lastTo), lastBefore + 8000,
        reason: '…and it must be fully counted in its own month');
  });
}
