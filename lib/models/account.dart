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

  const Account({
    required this.id,
    required this.name,
    this.customName = false,
    required this.createdAt,
  });

  /// A user-added account. User labels are always shown verbatim.
  factory Account.named(String name) => Account(
        id: _uuid.v4(),
        name: name.trim(),
        customName: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
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
      };

  factory Account.fromMap(Map<String, Object?> m) => Account(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        customName: ((m['customName'] as num?) ?? 0) != 0,
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
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
