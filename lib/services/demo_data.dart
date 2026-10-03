import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';
import '../models/account.dart';
import '../models/custom_purpose.dart';
import '../models/lending.dart';
import '../models/person.dart';
import '../models/transaction.dart';

/// Sample data for "Add demo data" (v1.5).
///
/// A first-time buyer opening an empty app can't tell what Yaad does.
/// One tap fills every screen with realistic Pakistani daily-life
/// figures; one tap on "Remove demo data" takes exactly those rows
/// back out. Every demo row carries `isDemo = 1` (DB v7), so removal
/// is precise — real rows are never touched, even when they share a
/// person name or a purpose with a demo row.
///
/// Dates are relative to *today*, so the current month always shows
/// non-trivial Spent / Received / Left, and the previous month has
/// history for Activity and the month summary.
class DemoData {
  DemoData._();

  /// SharedPreferences key holding the pre-demo opening balances, so
  /// Remove restores them exactly (demo sets its own openings to make
  /// the balances look real; the user's own openings must survive).
  static const _kOpeningsKey = 'yaad_demo_opening_balances_v1';

  /// Drops the saved pre-demo opening balances (factory wipe): after
  /// a wipe there are no "user's own openings" to restore, and a
  /// stale snapshot would resurrect pre-wipe balances on the next
  /// demo add/remove cycle.
  static Future<void> clearOpeningsSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kOpeningsKey);
  }

  /// The openings the demo runs with: a believable month-start state.
  static const _demoOpenings = {
    Account.seedMeezan: 120000.0,
    Account.seedSavings: 20000.0,
    Account.seedCash: 5000.0,
  };

  /// True when any demo row exists (Settings shows Remove instead of
  /// Add; Add is a no-op while demo data is present).
  static Future<bool> hasDemo() async {
    final d = await YaadDb.db;
    for (final t in ['transactions', 'lending', 'people', 'custom_purposes']) {
      final rows = await d.rawQuery(
          'SELECT COUNT(*) c FROM $t WHERE isDemo = 1');
      if (((rows.first['c'] as int?) ?? 0) > 0) return true;
    }
    return false;
  }

  /// A moment in [monthOffset] months from now (0 = this month,
  /// -1 = last month), on [day] clamped to the month's length and
  /// never in the future.
  static DateTime _when(int monthOffset, int day, {int hour = 12}) {
    final now = DateTime.now();
    final first = DateTime(now.year, now.month + monthOffset, 1);
    final lastDay = DateTime(first.year, first.month + 1, 0).day;
    final d = day.clamp(1, lastDay);
    var t = DateTime(first.year, first.month, d, hour, 15);
    if (t.isAfter(now)) t = now.subtract(const Duration(hours: 2));
    return t;
  }

  /// Adds the full sample dataset. Returns false (and changes
  /// nothing) when demo data is already present — adding twice would
  /// double every figure and break the "remove restores exactly"
  /// promise.
  static Future<bool> addDemo({String currency = 'PKR'}) async {
    if (await hasDemo()) return false;
    final d = await YaadDb.db;

    // Opening balances: snapshot the user's own first (once), then
    // set the demo's so every balance looks lived-in.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kOpeningsKey) == null) {
      final current = await YaadDb.accounts();
      await prefs.setString(
          _kOpeningsKey,
          jsonEncode(
              {for (final a in current) a.id: a.openingBalance}));
    }
    for (final e in _demoOpenings.entries) {
      await YaadDb.setOpeningBalance(e.key, e.value);
    }

    YaadTransaction txn({
      required double amount,
      required TxnKind kind,
      required DateTime at,
      String merchant = '',
      String purpose = 'uncategorized',
      String note = '',
      String accountId = Account.seedMeezan,
      String? toAccountId,
      String? personId,
    }) =>
        YaadTransaction(
          amount: amount,
          currency: currency,
          dateTime: at,
          direction: kind == TxnKind.receive || kind == TxnKind.repayIn
              ? TxnDirection.incoming
              : kind == TxnKind.transfer
                  ? TxnDirection.ownTransfer
                  : TxnDirection.out,
          kind: kind,
          rawMerchant: merchant,
          purpose: purpose,
          note: note,
          source: TxnSource.manual,
          accountId: accountId,
          toAccountId: toAccountId,
          personId: personId,
          isDemo: true,
        );

    // A custom purpose of his own — the demo shows that too.
    // (If the user already made one with this label, theirs wins and
    // the demo rows simply use it; removal then leaves it alone.)
    var gymId = CustomPurpose.idFor('Gym');
    final existingPurposes = await YaadDb.customPurposes();
    if (!existingPurposes.any((c) => c.id == gymId)) {
      final cp = CustomPurpose(
        id: gymId,
        label: 'Gym',
        createdAt: _when(0, 2).millisecondsSinceEpoch,
        isDemo: true,
      );
      await d.insert('custom_purposes', cp.toMap());
      await YaadDb.refreshCustomPurposeRegistry();
    } else {
      gymId = existingPurposes.firstWhere((c) => c.id == gymId).id;
    }

    final rows = <YaadTransaction>[
      // ---- this month ----
      txn(
        amount: 185000,
        kind: TxnKind.receive,
        at: _when(0, 1, hour: 10),
        merchant: 'Office salary',
        purpose: 'salary',
        note: 'Monthly salary',
      ),
      txn(
        amount: 25000,
        kind: TxnKind.transfer,
        at: _when(0, 2, hour: 11),
        purpose: 'savings',
        note: 'Backup savings',
        toAccountId: Account.seedSavings,
      ),
      txn(
        amount: 18450,
        kind: TxnKind.spend,
        at: _when(0, 3, hour: 19),
        merchant: 'Carrefour',
        purpose: 'groceries',
        note: 'Weekly groceries — atta, rice, cooking oil',
      ),
      txn(
        amount: 12340,
        kind: TxnKind.spend,
        at: _when(0, 4, hour: 9),
        merchant: 'LESCO',
        purpose: 'bills',
        note: 'Electricity bill',
      ),
      txn(
        amount: 7000,
        kind: TxnKind.spend,
        at: _when(0, 5, hour: 18),
        merchant: 'PSO petrol pump',
        purpose: 'transport',
        note: 'Fuel for the car',
      ),
      txn(
        amount: 1000,
        kind: TxnKind.spend,
        at: _when(0, 6, hour: 13),
        merchant: 'Jazz',
        purpose: 'mobile',
        note: 'Monthly mobile bundle',
      ),
      txn(
        amount: 4850,
        kind: TxnKind.spend,
        at: _when(0, 7, hour: 21),
        merchant: 'Desi Dhaba',
        purpose: 'food',
        note: 'Dinner with family',
      ),
      txn(
        amount: 10000,
        kind: TxnKind.transfer,
        at: _when(0, 8, hour: 10),
        purpose: 'savings',
        note: 'A little more aside',
        toAccountId: Account.seedSavings,
      ),
      txn(
        amount: 10000,
        kind: TxnKind.transfer,
        at: _when(0, 8, hour: 12),
        note: 'Cash for the week',
        toAccountId: Account.seedCash,
      ),
      txn(
        amount: 9999,
        kind: TxnKind.spend,
        at: _when(0, 9, hour: 17),
        merchant: 'Packages Mall',
        purpose: 'shopping',
        note: 'New shoes',
      ),
      txn(
        amount: 5000,
        kind: TxnKind.transfer,
        at: _when(0, 10, hour: 9),
        purpose: 'savings',
        note: 'Bike repair — took some savings back',
        accountId: Account.seedSavings,
        toAccountId: Account.seedMeezan,
      ),
      txn(
        amount: 3500,
        kind: TxnKind.spend,
        at: _when(0, 10, hour: 7),
        merchant: 'Fitness club',
        purpose: gymId,
        note: 'Monthly gym fee',
      ),
      txn(
        amount: 650,
        kind: TxnKind.spend,
        at: _when(0, 11, hour: 14),
        merchant: 'Office canteen',
        purpose: 'food',
        note: 'Chai and snacks',
        accountId: Account.seedCash,
      ),
      txn(
        amount: 400,
        kind: TxnKind.spend,
        at: _when(0, 11, hour: 18),
        merchant: 'Rickshaw',
        purpose: 'transport',
        note: 'Ride home',
        accountId: Account.seedCash,
      ),
      // ---- last month ----
      txn(
        amount: 185000,
        kind: TxnKind.receive,
        at: _when(-1, 1, hour: 10),
        merchant: 'Office salary',
        purpose: 'salary',
        note: 'Monthly salary',
      ),
      txn(
        amount: 45000,
        kind: TxnKind.spend,
        at: _when(-1, 3, hour: 11),
        merchant: 'House rent',
        purpose: 'rent',
        note: 'Monthly rent',
      ),
      txn(
        amount: 15000,
        kind: TxnKind.transfer,
        at: _when(-1, 5, hour: 11),
        purpose: 'savings',
        note: 'Backup savings',
        toAccountId: Account.seedSavings,
      ),
      txn(
        amount: 15200,
        kind: TxnKind.spend,
        at: _when(-1, 12, hour: 19),
        merchant: 'Carrefour',
        purpose: 'groceries',
        note: 'Monthly groceries',
      ),
      txn(
        amount: 9870,
        kind: TxnKind.spend,
        at: _when(-1, 15, hour: 9),
        merchant: 'LESCO',
        purpose: 'bills',
        note: 'Electricity bill',
      ),
    ];
    for (final t in rows) {
      await YaadDb.insertTxn(t);
    }

    // ---- Udhaar: money out with a friend, part of it back already;
    // and a small amount borrowed. Mirrors exactly what the Lend /
    // Borrow / Repay screens write, so every Udhaar screen behaves
    // the same as with real entries. ----
    final ahmed = Person(name: 'Ahmed Raza', isDemo: true);
    await YaadDb.insertPerson(ahmed);
    final loan = LendingRecord(
      personId: ahmed.id,
      originalAmount: 20000,
      currency: currency,
      date: _when(0, 5, hour: 16),
      reason: 'Bike repair',
      isOwedToMe: true,
      isDemo: true,
    );
    await YaadDb.insertLending(loan);
    // Partial repayment: 8,000 of 20,000 back → 12,000 outstanding.
    await YaadDb.addRepayment(Repayment(
      lendingId: loan.id,
      amount: 8000,
      date: _when(0, 9, hour: 15),
    ));
    await YaadDb.insertTxn(YaadTransaction(
      amount: 8000,
      currency: currency,
      dateTime: _when(0, 9, hour: 15),
      kind: TxnKind.repayIn,
      direction: TxnDirection.incoming,
      rawMerchant: 'Ahmed Raza',
      purpose: 'uncategorized',
      note: 'Bike repair',
      personId: ahmed.id,
      source: TxnSource.manual,
      accountId: Account.seedMeezan,
      isDemo: true,
    ));

    final usman = Person(name: 'Usman Tariq', isDemo: true);
    await YaadDb.insertPerson(usman);
    await YaadDb.insertLending(LendingRecord(
      personId: usman.id,
      originalAmount: 6000,
      currency: currency,
      date: _when(0, 6, hour: 20),
      reason: 'Dinner split — he covered it',
      isOwedToMe: false,
      isDemo: true,
    ));
    return true;
  }

  /// Removes exactly the demo rows. Real rows are untouched — even a
  /// real transaction that uses the demo custom purpose (it is
  /// reassigned to "Other", never deleted), and a demo person is only
  /// deleted once nothing references them any more.
  static Future<void> removeDemo() async {
    final d = await YaadDb.db;
    await d.transaction((txn) async {
      // Repayments hanging off demo lending first (FK order).
      await txn.rawDelete('''
        DELETE FROM repayments
        WHERE lendingId IN (SELECT id FROM lending WHERE isDemo = 1)''');
      await txn.delete('lending', where: 'isDemo = 1');
      await txn.delete('transactions', where: 'isDemo = 1');
      // A real transaction may use the demo purpose: keep the
      // transaction, move it to "Other" — same rule as deleting any
      // custom purpose.
      await txn.rawUpdate('''
        UPDATE transactions SET purpose = 'uncategorized'
        WHERE purpose IN (SELECT id FROM custom_purposes WHERE isDemo = 1)''');
      await txn.delete('custom_purposes', where: 'isDemo = 1');
      // Demo people go only when nothing (real or demo) points at
      // them any more.
      await txn.rawDelete('''
        DELETE FROM people
        WHERE isDemo = 1
          AND id NOT IN (SELECT personId FROM lending)
          AND id NOT IN (
            SELECT personId FROM transactions WHERE personId IS NOT NULL)''');
    });
    await YaadDb.refreshCustomPurposeRegistry();
    // Opening balances back to exactly what they were before Add.
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kOpeningsKey);
    if (raw != null) {
      final snapshot =
          Map<String, Object?>.from(jsonDecode(raw) as Map);
      for (final e in snapshot.entries) {
        await YaadDb.setOpeningBalance(
            e.key, (e.value as num?)?.toDouble() ?? 0);
      }
      await prefs.remove(_kOpeningsKey);
    }
  }
}
