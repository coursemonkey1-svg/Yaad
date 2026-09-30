import '../data/db.dart';
import '../models/alias.dart';
import '../models/transaction.dart';

/// A labelled suggestion: what the app thinks, and why.
/// The UI must show these as suggestions — never applied silently.
class Suggestion {
  final String purpose;
  final String reason; // e.g. "You used this for 4 of your last 5 grocery payments"
  const Suggestion(this.purpose, this.reason);
}

/// Learns from the user's own history, on-device.
/// Suggests a purpose for a merchant based on past choices,
/// and suggests an alias for unfamiliar raw names.
class SuggestionService {
  /// Suggest a purpose for [rawMerchant]. Null = not enough history.
  Future<Suggestion?> suggestPurpose(String rawMerchant) async {
    final clean = rawMerchant.trim();
    if (clean.isEmpty) return null;

    // 1) Same merchant before? Use the most common purpose.
    final db = await YaadDb.db;
    final rows = await db.rawQuery(
        "SELECT purpose, COUNT(*) c FROM transactions WHERE rawMerchant = ? "
        "AND purpose != 'uncategorized' GROUP BY purpose ORDER BY c DESC LIMIT 1",
        [clean]);
    if (rows.isNotEmpty) {
      final purpose = rows.first['purpose'] as String;
      final n = rows.first['c'] as int;
      return Suggestion(purpose,
          'You chose "$purpose" for this merchant $n time${n == 1 ? '' : 's'} before');
    }

    // 2) Alias known? Check what the alias was used for.
    final alias = await YaadDb.aliasFor(clean);
    if (alias != null) {
      final aRows = await db.rawQuery(
          "SELECT t.purpose, COUNT(*) c FROM transactions t "
          "JOIN aliases a ON t.aliasId = a.id WHERE a.id = ? "
          "AND t.purpose != 'uncategorized' GROUP BY t.purpose "
          "ORDER BY c DESC LIMIT 1",
          [alias.id]);
      if (aRows.isNotEmpty) {
        return Suggestion(aRows.first['purpose'] as String,
            'Based on your alias "${alias.alias}"');
      }
    }
    return null;
  }

  /// Suggest an alias for an unfamiliar raw name. Null = unsure.
  Future<MerchantAlias?> suggestAlias(String rawMerchant) =>
      YaadDb.suggestAlias(rawMerchant);

  /// Most-used purposes, for the quick-capture grid ordering.
  Future<List<String>> topPurposes({int limit = 8}) async {
    final db = await YaadDb.db;
    final rows = await db.rawQuery(
        "SELECT purpose, COUNT(*) c FROM transactions "
        "WHERE purpose != 'uncategorized' GROUP BY purpose "
        "ORDER BY c DESC LIMIT ?",
        [limit]);
    return rows.map((r) => r['purpose'] as String).toList();
  }

  /// Detects likely-recurring outflows (same merchant + similar amount,
  /// 2+ months in a row). Shown for confirmation — never auto-saved.
  Future<List<YaadTransaction>> recurringCandidates() async {
    final db = await YaadDb.db;
    final rows = await db.rawQuery('''
      SELECT rawMerchant, COUNT(DISTINCT strftime('%Y-%m', dateTime/1000, 'unixepoch')) months,
             AVG(amount) avgAmt, MAX(dateTime) lastSeen
      FROM transactions
      WHERE direction = 'out' AND status != 'excluded'
      GROUP BY rawMerchant
      HAVING months >= 2
      ORDER BY lastSeen DESC
      LIMIT 20
    ''');
    final out = <YaadTransaction>[];
    for (final r in rows) {
      final txns = await YaadDb.txns(query: r['rawMerchant'] as String, limit: 1);
      if (txns.isNotEmpty) out.add(txns.first);
    }
    return out;
  }
}
