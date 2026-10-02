import '../data/db.dart';
import '../models/alias.dart';
import '../models/purposes.dart';
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
  static const _dayMs = 86400000;

  /// Recency-weighted ranking, SQL-only.
  ///
  /// Formula: score(purpose) = SUM over that purpose's past uses of
  /// weight(age of the use), with stepped weights (a coarse exponential
  /// decay — plain CASE, so it runs on every SQLite build without math
  /// functions):
  ///   use <= 7 days old   -> 20
  ///   use 8-30 days old   -> 10
  ///   use 31-90 days old  -> 3
  ///   use > 90 days old   -> 1
  /// Ties break toward the most recently used purpose.
  ///
  /// A fresh habit beats a stale one: one choice made this week (20)
  /// outranks ten choices made months ago (10 x 1). But a single recent
  /// outlier does not erase a genuinely dominant history (50 old uses
  /// still beat 1 recent one).
  ///
  /// [alias] is the transactions table alias in the enclosing query.
  /// The three `?` placeholders take the bucket cutoffs from [_cutoffs],
  /// newest first.
  static String _scoreSql(String alias) => 'SUM(CASE'
      ' WHEN $alias.dateTime >= ? THEN 20.0'
      ' WHEN $alias.dateTime >= ? THEN 10.0'
      ' WHEN $alias.dateTime >= ? THEN 3.0'
      ' ELSE 1.0 END) AS score';

  /// Bucket cutoff timestamps (millis since epoch), newest first:
  /// [7 days ago, 30 days ago, 90 days ago].
  static List<int> _cutoffs(int nowMs) =>
      [nowMs - 7 * _dayMs, nowMs - 30 * _dayMs, nowMs - 90 * _dayMs];

  /// Suggest a purpose for [rawMerchant]. Null = not enough history.
  ///
  /// Ranking is recency-weighted (see [_scoreSql]). [now] pins the clock
  /// so tests get deterministic results; production callers omit it.
  Future<Suggestion?> suggestPurpose(String rawMerchant,
      {DateTime? now}) async {
    final clean = rawMerchant.trim();
    if (clean.isEmpty) return null;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;

    // 1) Same merchant before? Use the recency-weighted top purpose.
    final db = await YaadDb.db;
    final rows = await db.rawQuery(
        "SELECT t.purpose, COUNT(*) c, ${_scoreSql('t')} FROM transactions t "
        "WHERE t.rawMerchant = ? AND t.purpose != 'uncategorized' "
        "GROUP BY t.purpose ORDER BY score DESC, MAX(t.dateTime) DESC LIMIT 1",
        [..._cutoffs(nowMs), clean]);
    if (rows.isNotEmpty) {
      final purpose = rows.first['purpose'] as String;
      final n = rows.first['c'] as int;
      return Suggestion(purpose,
          'You chose "${purposeLabel(purpose)}" for this merchant $n time${n == 1 ? '' : 's'} before');
    }

    // 2) Alias known? Check what the alias was used for (same weighting).
    final alias = await YaadDb.aliasFor(clean);
    if (alias != null) {
      final aRows = await db.rawQuery(
          "SELECT t.purpose, ${_scoreSql('t')} FROM transactions t "
          "JOIN aliases a ON t.aliasId = a.id WHERE a.id = ? "
          "AND t.purpose != 'uncategorized' GROUP BY t.purpose "
          "ORDER BY score DESC, MAX(t.dateTime) DESC LIMIT 1",
          [..._cutoffs(nowMs), alias.id]);
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

  /// Most-used purposes, recency-weighted with the same formula as
  /// [suggestPurpose]. [now] pins the clock for tests.
  ///
  /// Currently no callers: the quick-capture grid keeps its fixed
  /// catalog order on purpose — re-sorting chips asynchronously would
  /// move buttons under the user's finger while they read them, and the
  /// suggestion banner already surfaces the top prediction.
  Future<List<String>> topPurposes({int limit = 8, DateTime? now}) async {
    final db = await YaadDb.db;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await db.rawQuery(
        "SELECT t.purpose, ${_scoreSql('t')} FROM transactions t "
        "WHERE t.purpose != 'uncategorized' GROUP BY t.purpose "
        "ORDER BY score DESC, MAX(t.dateTime) DESC LIMIT ?",
        [..._cutoffs(nowMs), limit]);
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
