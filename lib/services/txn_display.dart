import '../data/db.dart';
import '../l10n/strings.dart';
import '../models/account.dart';
import '../models/transaction.dart';

/// Display-ready names for a transaction row/detail: the user's own
/// merchant alias, the person's name, and the localised account tag.
/// Shared by the Activity rows and the read-only detail view so both
/// resolve the same labels the same way.
class TxnDisplayNames {
  final String? alias;
  final String? personName;
  final String accountLabel;
  const TxnDisplayNames({this.alias, this.personName, required this.accountLabel});
}

/// Resolves [TxnDisplayNames] for a transaction. A NULL accountId
/// (pre-v1.4 rows or raw inserts) reads as the default account — a
/// transaction is never shown without an account tag.
Future<TxnDisplayNames> loadTxnDisplayNames(
    YaadTransaction txn, Strings s) async {
  final alias = await YaadDb.aliasFor(txn.rawMerchant);
  String? personName;
  if (txn.personId != null) {
    personName = (await YaadDb.personById(txn.personId!))?.name;
  }
  final accountId = txn.accountId ?? Account.seedMeezan;
  final account = await YaadDb.accountById(accountId);
  return TxnDisplayNames(
    alias: (alias != null && alias.alias.isNotEmpty) ? alias.alias : null,
    personName:
        (personName != null && personName.isNotEmpty) ? personName : null,
    accountLabel: account?.displayName(s) ?? accountId,
  );
}
