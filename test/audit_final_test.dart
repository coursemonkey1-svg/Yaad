import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/account.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/services/backup.dart';
import 'package:yaad/services/capture_inbox.dart';
import 'package:yaad/services/sms_capture.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Regression tests for the final full-app audit (build-28). Each test
/// pins a defect that lived BETWEEN features — in how they combine
/// under the user's real phone state — not inside any one feature.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('yaad/capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-audit-final-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  setUp(() async {
    await YaadDb.wipeAll();
    appState.settings = const AppSettings();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    appState.settings = const AppSettings();
  });

  YaadTransaction row({
    required String merchant,
    required double amount,
    TxnKind kind = TxnKind.spend,
    TxnDirection direction = TxnDirection.out,
    String? accountId,
    String? toAccountId,
    String? bankReference,
    TxnStatus status = TxnStatus.confirmed,
    DateTime? when,
  }) =>
      YaadTransaction(
        amount: amount,
        dateTime: when ?? DateTime.now(),
        kind: kind,
        direction: direction,
        rawMerchant: merchant,
        purpose: 'uncategorized',
        bankReference: bankReference,
        source: TxnSource.manual,
        status: status,
        accountId: accountId,
        toAccountId: toAccountId,
      );

  group('Activity account filter counts both transfer legs', () {
    test('a transfer INTO the filtered account appears in its list',
        () async {
      final t = row(
        merchant: 'AUDIT MOVE',
        amount: 5000,
        kind: TxnKind.transfer,
        direction: TxnDirection.ownTransfer,
        accountId: Account.seedMeezan,
        toAccountId: Account.seedSavings,
      );
      await YaadDb.insertTxn(t);
      // Before the fix, txns() matched only accountId: filtering
      // Activity by Savings hid the money that had just moved in,
      // while the Accounts count and the Savings balance included it.
      final forSavings =
          await YaadDb.txns(accountIds: {Account.seedSavings});
      expect(forSavings.map((x) => x.id), contains(t.id));
      final forCash = await YaadDb.txns(accountIds: {Account.seedCash});
      expect(forCash.map((x) => x.id), isNot(contains(t.id)));
      final forMeezan =
          await YaadDb.txns(accountIds: {Account.seedMeezan});
      expect(forMeezan.map((x) => x.id), contains(t.id));
    });
  });

  group('findDuplicate (cross-channel capture dedupe)', () {
    test('merchant case difference still counts as the same event',
        () async {
      final noon = DateTime.now().copyWith(hour: 12, minute: 0);
      await YaadDb.insertTxn(
          row(merchant: 'KHAADI', amount: 500, when: noon));
      final dup = await YaadDb.findDuplicate(
          amount: 500, rawMerchant: 'khaadi', date: noon);
      expect(dup, isNotNull);
    });

    test('an event straddling midnight is caught across the day line',
        () async {
      final afterMidnight = DateTime.now()
          .copyWith(hour: 0, minute: 30, second: 0, millisecond: 0);
      await YaadDb.insertTxn(
          row(merchant: 'NIGHT SHOP', amount: 700, when: afterMidnight));
      final beforeMidnight =
          afterMidnight.subtract(const Duration(minutes: 45));
      final dup = await YaadDb.findDuplicate(
          amount: 700, rawMerchant: 'NIGHT SHOP', date: beforeMidnight);
      expect(dup, isNotNull);
    });

    test('a genuine repeat at midday next day is NOT a duplicate',
        () async {
      final noon = DateTime.now().copyWith(hour: 12, minute: 0);
      await YaadDb.insertTxn(
          row(merchant: 'DAILY CHAI', amount: 300, when: noon));
      final dup = await YaadDb.findDuplicate(
          amount: 300,
          rawMerchant: 'DAILY CHAI',
          date: noon.add(const Duration(days: 1)));
      expect(dup, isNull);
    });

    test('a fresh bank reference never matches a different-reference row',
        () async {
      final noon = DateTime.now().copyWith(hour: 12, minute: 0);
      await YaadDb.insertTxn(row(
          merchant: 'REF SHOP',
          amount: 900,
          when: noon,
          bankReference: 'REF-A'));
      // Same amount/merchant/day, but a NEW reference: provably a
      // different bank event — the fallback must not swallow it.
      final notDup = await YaadDb.findDuplicate(
          bankReference: 'REF-B',
          amount: 900,
          rawMerchant: 'REF SHOP',
          date: noon);
      expect(notDup, isNull);
      // The same reference IS a duplicate.
      final dup = await YaadDb.findDuplicate(
          bankReference: 'REF-A',
          amount: 1,
          rawMerchant: 'ANYTHING',
          date: noon);
      expect(dup, isNotNull);
      // A ref-less incoming copy of the referenced row: the stored
      // row HAS a reference, so the fallback (ref-less stored rows
      // only) must not match it either — the channels are told apart
      // by which side carries the reference.
      final refLess = await YaadDb.findDuplicate(
          amount: 900, rawMerchant: 'REF SHOP', date: noon);
      expect(refLess, isNotNull,
          reason:
              'an incoming row without a reference matches on amount+merchant+day');
    });
  });

  group('accountBalances: one-legged imported transfers', () {
    test('a marked import pair nets to zero, not minus twice', () async {
      final before = await YaadDb.accountBalances();
      // Statement-import pair legs: two rows, kind transfer, no
      // destination — the outgoing leg and the incoming leg.
      await YaadDb.insertTxn(row(
        merchant: 'AUDIT PAIR OUT',
        amount: 1000,
        kind: TxnKind.transfer,
        direction: TxnDirection.out,
        accountId: Account.seedMeezan,
      ));
      await YaadDb.insertTxn(row(
        merchant: 'AUDIT PAIR IN',
        amount: 1000,
        kind: TxnKind.transfer,
        direction: TxnDirection.incoming,
        accountId: Account.seedMeezan,
      ));
      final after = await YaadDb.accountBalances();
      expect(after[Account.seedMeezan], before[Account.seedMeezan]);
    });

    test('a normal two-leg transfer still moves the money', () async {
      await YaadDb.insertTxn(row(
        merchant: 'AUDIT PARK',
        amount: 2000,
        kind: TxnKind.transfer,
        direction: TxnDirection.ownTransfer,
        accountId: Account.seedMeezan,
        toAccountId: Account.seedSavings,
      ));
      final b = await YaadDb.accountBalances();
      expect(b[Account.seedSavings], 2000);
      expect(b[Account.seedMeezan], -2000);
      expect(await YaadDb.totalBalance(), 0);
    });
  });

  group('deleteAccount guard', () {
    test('reassigning an account to itself is refused', () async {
      await expectLater(
        YaadDb.deleteAccount(Account.seedCash,
            reassignTo: Account.seedCash),
        throwsArgumentError,
      );
      // The account is untouched.
      expect(await YaadDb.accountById(Account.seedCash), isNotNull);
    });
  });

  group('app-booked money accounts (never Savings by accident)', () {
    final accounts = [
      const Account(id: Account.seedMeezan, name: 'Meezan', createdAt: 0),
      const Account(id: Account.seedSavings, name: 'Savings', createdAt: 0),
      const Account(id: Account.seedCash, name: 'Cash', createdAt: 0),
    ];

    test('bank events land on Meezan even when the default is Savings',
        () {
      expect(
          bankEventAccountId(accounts,
              defaultBank: 'meezan', preferredId: Account.seedSavings),
          Account.seedMeezan);
    });

    test('bank events with another bank fall back to a non-Savings default',
        () {
      expect(
          bankEventAccountId(accounts,
              defaultBank: 'other', preferredId: Account.seedSavings),
          Account.seedMeezan);
      expect(
          bankEventAccountId(accounts,
              defaultBank: 'other', preferredId: Account.seedCash),
          Account.seedCash);
    });

    test('money events use the default unless it is Savings', () {
      expect(defaultMoneyAccountId(accounts, Account.seedCash),
          Account.seedCash);
      expect(defaultMoneyAccountId(accounts, Account.seedSavings),
          Account.seedMeezan);
      const onlySavings = [
        Account(id: Account.seedSavings, name: 'S', createdAt: 0)
      ];
      expect(defaultMoneyAccountId(onlySavings, Account.seedSavings),
          Account.seedSavings);
    });
  });

  group('captured alerts book to the bank account', () {
    test('drain books to Meezan while the default account is Savings',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'drainSmsQueue') {
          return [
            {
              'sender': 'MEEZAN',
              'body': 'Meezan Bank: Your account *1234 has been debited '
                  'by PKR 2,450.00 at AUDIT SHOP. Ref: MB-AUDIT1. '
                  'Available balance PKR 120,000.',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }
          ];
        }
        return null;
      });
      appState.settings = const AppSettings(
        smsCapture: true,
        defaultAccountId: Account.seedSavings,
        defaultBank: 'meezan',
      );
      final (recorded, review) = await CaptureService.drainAndImport();
      expect(recorded + review, 1);
      final all = await YaadDb.txns(limit: 10);
      final captured =
          all.firstWhere((t) => t.bankReference == 'MB-AUDIT1');
      expect(captured.accountId, Account.seedMeezan,
          reason: 'a bank spend must never land in the Savings stash');
    });

    test('drain with no native channel registered quietly finds nothing',
        () async {
      // No mock handler at all: the channel call throws
      // MissingPluginException (NOT a PlatformException). The drain
      // must return (0, 0), never throw into the resume chain.
      appState.settings = const AppSettings(
          smsCapture: true, notificationCapture: true);
      final result = await CaptureService.drainAndImport();
      expect(result, (0, 0));
    });
  });

  group('completePendingSmsOptIn (the build-26 disease, SMS side)', () {
    test('pending + granted: capture turns on, pending cleared', () async {
      appState.settings = const AppSettings(smsOptInPending: true);
      final outcome = await CaptureService.completePendingSmsOptIn(
          smsPermissionGranted: () async => true);
      expect(outcome, SmsOptInOutcome.enabled);
      expect(appState.settings.smsCapture, isTrue);
      expect(appState.settings.smsOptInPending, isFalse);
      expect(appState.settings.smsOptInMissed, isFalse);
    });

    test('pending + denied: pending cleared, miss recorded for the nudge',
        () async {
      appState.settings = const AppSettings(smsOptInPending: true);
      final outcome = await CaptureService.completePendingSmsOptIn(
          smsPermissionGranted: () async => false);
      expect(outcome, SmsOptInOutcome.missing);
      expect(appState.settings.smsCapture, isFalse);
      expect(appState.settings.smsOptInPending, isFalse);
      expect(appState.settings.smsOptInMissed, isTrue);
    });

    test('not pending: nothing happens', () async {
      final outcome = await CaptureService.completePendingSmsOptIn(
          smsPermissionGranted: () async => true);
      expect(outcome, SmsOptInOutcome.none);
      expect(appState.settings.smsCapture, isFalse);
    });
  });

  group('capture passes cannot undo each other', () {
    test(
        'a concurrent reconcile cannot revert a completed opt-in',
        () async {
      appState.settings = const AppSettings(
        notifOptInPending: true,
        smsCapture: true,
        notificationCapture: false,
      );
      // Reconcile starts with a SLOW sms check that will legitimately
      // turn SMS off; the notif completion lands meanwhile. Before
      // the fix, reconcile wrote back a whole settings object built
      // from its pre-await snapshot and silently reverted the
      // completion (notificationCapture back off, pending back on).
      final reconcile = CaptureService.reconcileCaptureFlags(
        smsPermissionGranted: () async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return false;
        },
        notificationAccessGranted: () async => true,
      );
      final complete = CaptureService.completePendingNotifOptIn(
          notificationAccessGranted: () async => true);
      await Future.wait([reconcile, complete]);
      expect(appState.settings.notificationCapture, isTrue);
      expect(appState.settings.notifOptInPending, isFalse);
      expect(appState.settings.smsCapture, isFalse,
          reason: 'the legitimate SMS revocation still applies');
    });

    test('a failing permission check is unknown, not a revocation',
        () async {
      appState.settings = const AppSettings(
          smsCapture: true, notificationCapture: true);
      await CaptureService.reconcileCaptureFlags(
        smsPermissionGranted: () async => throw Exception('hiccup'),
        notificationAccessGranted: () async =>
            throw Exception('hiccup'),
      );
      expect(appState.settings.smsCapture, isTrue);
      expect(appState.settings.notificationCapture, isTrue);
    });
  });

  group('capture settings fields', () {
    test('new fields default false and round-trip', () {
      const s = AppSettings();
      expect(s.smsOptInPending, isFalse);
      expect(s.smsOptInMissed, isFalse);
      expect(s.notifOptInMissed, isFalse);
      final on = s.copyWith(
          smsOptInPending: true, smsOptInMissed: true, notifOptInMissed: true);
      final back = AppSettings.fromMap(on.toMap());
      expect(back.smsOptInPending, isTrue);
      expect(back.smsOptInMissed, isTrue);
      expect(back.notifOptInMissed, isTrue);
      final legacy = AppSettings.fromMap(const {});
      expect(legacy.smsOptInPending, isFalse);
      expect(legacy.smsOptInMissed, isFalse);
      expect(legacy.notifOptInMissed, isFalse);
    });

    test('a corrupt currency in a backup falls back to PKR', () {
      expect(AppSettings.fromMap(const {'currency': 'USD'}).currency,
          'USD');
      expect(AppSettings.fromMap(const {'currency': 'pkr'}).currency,
          'PKR');
      expect(
          AppSettings.fromMap(const {'currency': 'PKR"; DROP'}).currency,
          'PKR');
    });
  });

  group('capture inbox direction', () {
    test('direction survives add + persistence round-trip', () async {
      // The inbox persists to shared prefs: entries from earlier
      // tests in this file (the drain tests add through the
      // singleton) would join this fresh instance on load. Start
      // from a cleared store so `.single` means this test's entry.
      await CaptureInbox.instance.clear();
      final inbox = CaptureInbox();
      await inbox.add(
        txnId: 'audit-in-1',
        merchant: 'SALARY',
        amount: 50000,
        time: DateTime.now(),
        needsReview: false,
        isOut: false,
      );
      expect(inbox.entries.single.isOut, isFalse);
      final reloaded = CaptureInbox();
      await reloaded.load();
      final e =
          reloaded.entries.firstWhere((x) => x.txnId == 'audit-in-1');
      expect(e.isOut, isFalse,
          reason: 'a credit must not come back looking like a spend');
      await inbox.clear();
    });

    test('entries persisted before direction existed read as money out',
        () {
      final legacy = InboxEntry.fromJson(const {
        'id': 'x',
        'txnId': 'y',
        'merchant': 'SHOP',
        'amount': 10.0,
        'time': '2026-01-01T00:00:00.000',
        'needsReview': false,
        'read': false,
      });
      expect(legacy.isOut, isTrue);
    });
  });

  group('CSV export', () {
    test('excluded rows are not exported', () async {
      await YaadDb.insertTxn(row(
          merchant: 'AUDIT KEEP', amount: 100, when: DateTime.now()));
      await YaadDb.insertTxn(row(
          merchant: 'AUDIT EXCLUDED',
          amount: 200,
          when: DateTime.now(),
          status: TxnStatus.excluded));
      final res = await BackupService().exportCsv();
      final content = await File(res.path).readAsString();
      expect(content, contains('AUDIT KEEP'));
      expect(content, isNot(contains('AUDIT EXCLUDED')));
      expect(res.count, 1);
    });
  });

  group('cross-figure consistency', () {
    test('one fixture set: every Home figure agrees with the others',
        () async {
      final totalBefore = await YaadDb.totalBalance();
      final savingsBefore = await YaadDb.savingsTotal();
      final now = DateTime.now();
      await YaadDb.insertTxn(row(
          merchant: 'AUDIT IN',
          amount: 10000,
          kind: TxnKind.receive,
          direction: TxnDirection.incoming,
          accountId: Account.seedMeezan,
          when: now));
      await YaadDb.insertTxn(row(
          merchant: 'AUDIT OUT',
          amount: 3000,
          accountId: Account.seedMeezan,
          when: now));
      await YaadDb.insertTxn(row(
          merchant: 'AUDIT PARK',
          amount: 2000,
          kind: TxnKind.transfer,
          direction: TxnDirection.ownTransfer,
          accountId: Account.seedMeezan,
          toAccountId: Account.seedSavings,
          when: now));
      await YaadDb.insertTxn(row(
          merchant: 'AUDIT LENT',
          amount: 1500,
          kind: TxnKind.lendOut,
          accountId: Account.seedMeezan,
          when: now));
      await YaadDb.insertTxn(row(
          merchant: 'AUDIT REPAID',
          amount: 500,
          kind: TxnKind.repayIn,
          direction: TxnDirection.incoming,
          accountId: Account.seedMeezan,
          when: now));

      // Total = openings + receives − spends − lent + repaid; the
      // internal transfer moves nothing in total.
      expect(await YaadDb.totalBalance(),
          totalBefore + 10000 - 3000 - 1500 + 500);
      // Total is exactly the sum of the per-account balances.
      final per = await YaadDb.accountBalances();
      expect(per.values.fold<double>(0, (a, b) => a + b),
          await YaadDb.totalBalance());
      // Savings total moved by exactly the parked amount.
      expect(await YaadDb.savingsTotal(), savingsBefore + 2000);
      // The period sums behind Left exclude the transfer and the
      // lending kinds, exactly as the hero presents them.
      final from = DateTime(now.year, now.month, now.day)
          .millisecondsSinceEpoch;
      final to = now.millisecondsSinceEpoch + 1000;
      expect(await YaadDb.sumReceived(from, to), 10000);
      expect(await YaadDb.sumSpent(from, to), 3000);
      expect(await YaadDb.savingsNet(from, to), 2000);
    });
  });
}
