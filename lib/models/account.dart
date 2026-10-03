import 'package:uuid/uuid.dart';

import '../l10n/strings.dart';

const _uuid = Uuid();

/// A money account: Meezan, Savings, Cash, or one the user added.
/// Every transaction points at one — the tag on each card, the filter
/// in Activity, and (later) savings balances all build on this.
///
/// Seeded ids are stable ('meezan' / 'savings' / 'cash') so restores
/// and migrations always agree on the default. [customName] tracks
/// whether the user renamed a seeded account: seeded accounts get a
/// localised label ("میزان" in Urdu) until the user renames them.
class Account {
  static const seedMeezan = 'meezan';
  static const seedSavings = 'savings';
  static const seedCash = 'cash';

  final String id;
  final String name;
  final bool customName;
  final int createdAt;
  /// What the account held before Yaad started tracking it (v1.5).
  /// Balance = opening + every transaction leg, all time. Default 0;
  /// the user sets it when creating or editing the account.
  final double openingBalance;

  const Account({
    required this.id,
    required this.name,
    this.customName = false,
    required this.createdAt,
    this.openingBalance = 0,
  });

  /// A user-added account. User labels are always shown verbatim.
  factory Account.named(String name, {double openingBalance = 0}) => Account(
        id: _uuid.v4(),
        name: name.trim(),
        customName: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        openingBalance: openingBalance,
      );

  /// The three accounts every install starts with. Inserted with
  /// INSERT OR IGNORE so migrations and restores never duplicate them.
  static List<Account> seeds() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      Account(id: seedMeezan, name: 'Meezan', createdAt: now),
      Account(id: seedSavings, name: 'Savings', createdAt: now),
      Account(id: seedCash, name: 'Cash', createdAt: now),
    ];
  }

  /// What the user sees: the localised name for untouched seeds,
  /// the user's own label otherwise.
  String displayName(Strings s) {
    if (customName) return name;
    return s.find('accountName_$id') ?? name;
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'customName': customName ? 1 : 0,
        'createdAt': createdAt,
        'openingBalance': openingBalance,
      };

  factory Account.fromMap(Map<String, Object?> m) => Account(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        customName: ((m['customName'] as num?) ?? 0) != 0,
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
        openingBalance: (m['openingBalance'] as num?)?.toDouble() ?? 0,
      );
}

/// The effective default account id: the preferred one when it still
/// exists, otherwise the first account. There is always at least one
/// account — the last one cannot be deleted.
String resolveDefaultAccountId(
    List<Account> accounts, String preferredId) {
  if (accounts.any((a) => a.id == preferredId)) return preferredId;
  return accounts.first.id;
}

/// [id] unless it is the Savings stash, in which case the first
/// non-Savings account. Savings is where money is PARKED, not where
/// everyday money events happen; when Savings is the only account
/// there is no alternative and it is returned as-is.
String _orNonSavings(List<Account> accounts, String id) {
  if (id != Account.seedSavings) return id;
  for (final a in accounts) {
    if (a.id != Account.seedSavings) return a.id;
  }
  return id;
}

/// The account an app-booked money event belongs to when the user's
/// default would be wrong: their default account, unless the default
/// IS Savings (a state reachable by one accidental tap on the
/// Accounts row), in which case the first non-Savings account.
/// Used for udhaar settle-ups and repayments — real money in/out
/// that must never silently land in the savings stash.
String defaultMoneyAccountId(List<Account> accounts, String preferredId) =>
    _orNonSavings(accounts, resolveDefaultAccountId(accounts, preferredId));

/// The account a BANK event belongs to (an auto-captured bank alert,
/// a statement import): the seeded Meezan account when Meezan is the
/// user's bank — bank money is Meezan money regardless of the UI
/// default at the moment the event is processed — otherwise
/// [defaultMoneyAccountId]. Never Savings by accident: booking bank
/// spends into the stash corrupts its balance and Home's Left.
String bankEventAccountId(List<Account> accounts,
    {required String defaultBank, required String preferredId}) {
  if (defaultBank == 'meezan' &&
      accounts.any((a) => a.id == Account.seedMeezan)) {
    return Account.seedMeezan;
  }
  return defaultMoneyAccountId(accounts, preferredId);
}
