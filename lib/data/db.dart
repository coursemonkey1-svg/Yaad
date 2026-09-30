import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/transaction.dart';
import '../models/person.dart';
import '../models/lending.dart';
import '../models/alias.dart';

/// On-device SQLite database. Everything stays on the phone —
/// no account, no server, no sync. Free forever.
class YaadDb {
  static const _name = 'yaad.db';
  static const _version = 1;
  static Database? _db;

  static Future<Database> get db async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, _name),
      version: _version,
      onCreate: _create,
    );
    return _db!;
  }

  static Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        dateTime INTEGER NOT NULL,
        direction TEXT NOT NULL,
        rawMerchant TEXT NOT NULL,
        aliasId TEXT,
        purpose TEXT NOT NULL,
        note TEXT NOT NULL,
        tags TEXT NOT NULL,
        receiptPath TEXT,
        bankReference TEXT,
        source TEXT NOT NULL,
        status TEXT NOT NULL,
        personId TEXT,
        linkedLendingId TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )''');
    await db.execute(
        'CREATE INDEX idx_txn_date ON transactions(dateTime DESC)');
    await db.execute(
        'CREATE INDEX idx_txn_status ON transactions(status)');
    await db.execute(
        'CREATE INDEX idx_txn_ref ON transactions(bankReference)');

    await db.execute('''
      CREATE TABLE people(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        note TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )''');

    await db.execute('''
      CREATE TABLE lending(
        id TEXT PRIMARY KEY,
        personId TEXT NOT NULL,
        type TEXT NOT NULL,
        originalAmount REAL NOT NULL,
        currency TEXT NOT NULL,
        date INTEGER NOT NULL,
        reason TEXT NOT NULL,
        dueDate INTEGER,
        note TEXT NOT NULL,
        receiptPath TEXT,
        isOwedToMe INTEGER NOT NULL,
        status TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )''');
    await db.execute('CREATE INDEX idx_lending_person ON lending(personId)');

    await db.execute('''
      CREATE TABLE repayments(
        id TEXT PRIMARY KEY,
        lendingId TEXT NOT NULL,
        amount REAL NOT NULL,
        date INTEGER NOT NULL,
        note TEXT NOT NULL,
        transactionId TEXT
      )''');
    await db.execute(
        'CREATE INDEX idx_repay_lending ON repayments(lendingId)');

    await db.execute('''
      CREATE TABLE aliases(
        id TEXT PRIMARY KEY,
        rawName TEXT NOT NULL UNIQUE,
        alias TEXT NOT NULL,
        usageCount INTEGER NOT NULL,
        lastUsed INTEGER NOT NULL
      )''');

    // Append-only audit trail: every create/edit/link/unlink/delete.
    await db.execute('''
      CREATE TABLE audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at INTEGER NOT NULL,
        entity TEXT NOT NULL,
        entityId TEXT NOT NULL,
        action TEXT NOT NULL,
        detail TEXT NOT NULL
      )''');
  }

  // ---------- transactions ----------

  static Future<void> insertTxn(YaadTransaction t) async {
    final d = await db;
    await d.insert('transactions', t.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _audit(d, 'transaction', t.id, 'created', '${t.amount} ${t.currency}');
  }

  static Future<void> updateTxn(YaadTransaction t) async {
    final d = await db;
    final old = await d.query('transactions',
        where: 'id = ?', whereArgs: [t.id], limit: 1);
    await d.update('transactions', t.toMap(),
        where: 'id = ?', whereArgs: [t.id]);
    final detail = old.isEmpty
        ? 'updated'
        : 'amount ${old.first['amount']} -> ${t.amount}; '
            'purpose ${old.first['purpose']} -> ${t.purpose}';
    await _audit(d, 'transaction', t.id, 'updated', detail);
  }

  static Future<void> deleteTxn(String id) async {
    final d = await db;
    await d.delete('transactions', where: 'id = ?', whereArgs: [id]);
    await _audit(d, 'transaction', id, 'deleted', '');
  }

  static Future<List<YaadTransaction>> txns({
    int limit = 200,
    int offset = 0,
    String? status,
    String? query,
    String? purpose,
    String? personId,
    int? fromMs,
    int? toMs,
  }) async {
    final d = await db;
    final where = <String>[];
    final args = <Object?>[];
    if (status != null) {
      where.add('status = ?');
      args.add(status);
    }
    if (purpose != null) {
      where.add('purpose = ?');
      args.add(purpose);
    }
    if (personId != null) {
      where.add('personId = ?');
      args.add(personId);
    }
    if (fromMs != null) {
      where.add('dateTime >= ?');
      args.add(fromMs);
    }
    if (toMs != null) {
      where.add('dateTime <= ?');
      args.add(toMs);
    }
    if (query != null && query.trim().isNotEmpty) {
      where.add('(rawMerchant LIKE ? OR note LIKE ? OR purpose LIKE ?)');
      final q = '%${query.trim()}%';
      args.addAll([q, q, q]);
    }
    final rows = await d.query(
      'transactions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'dateTime DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(YaadTransaction.fromMap).toList();
  }

  static Future<YaadTransaction?> txnById(String id) async {
    final d = await db;
    final rows =
        await d.query('transactions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : YaadTransaction.fromMap(rows.first);
  }

  /// Duplicate check for imports: same bank reference, or same
  /// amount + merchant + calendar day.
  static Future<YaadTransaction?> findDuplicate({
    String? bankReference,
    required double amount,
    required String rawMerchant,
    required DateTime date,
  }) async {
    final d = await db;
    if (bankReference != null && bankReference.isNotEmpty) {
      final rows = await d.query('transactions',
          where: 'bankReference = ?', whereArgs: [bankReference], limit: 1);
      if (rows.isNotEmpty) return YaadTransaction.fromMap(rows.first);
    }
    final dayStart =
        DateTime(date.year, date.month, date.day).millisecondsSinceEpoch;
    final dayEnd = dayStart + 24 * 3600 * 1000 - 1;
    final rows = await d.query(
      'transactions',
      where: 'amount = ? AND rawMerchant = ? AND dateTime BETWEEN ? AND ?',
      whereArgs: [amount, rawMerchant, dayStart, dayEnd],
      limit: 1,
    );
    return rows.isEmpty ? null : YaadTransaction.fromMap(rows.first);
  }

  static Future<int> countByStatus(String status) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COUNT(*) c FROM transactions WHERE status = ?', [status]);
    return (rows.first['c'] as int?) ?? 0;
  }

  static Future<double> sumOut(int fromMs, int toMs) async {
    final d = await db;
    final rows = await d.rawQuery(
        "SELECT SUM(amount) s FROM transactions WHERE direction = 'out' "
        "AND status != 'excluded' AND dateTime BETWEEN ? AND ?",
        [fromMs, toMs]);
    return ((rows.first['s'] as num?) ?? 0).toDouble();
  }

  static Future<List<Map<String, Object?>>> sumByPurpose(
      int fromMs, int toMs) async {
    final d = await db;
    return d.rawQuery(
        "SELECT purpose, SUM(amount) total, COUNT(*) n FROM transactions "
        "WHERE direction = 'out' AND status != 'excluded' "
        "AND dateTime BETWEEN ? AND ? GROUP BY purpose ORDER BY total DESC",
        [fromMs, toMs]);
  }

  // ---------- people ----------

  static Future<void> insertPerson(Person person) async {
    final d = await db;
    await d.insert('people', person.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _audit(d, 'person', person.id, 'created', person.name);
  }

  static Future<List<Person>> people() async {
    final d = await db;
    final rows = await d.query('people', orderBy: 'name COLLATE NOCASE');
    return rows.map(Person.fromMap).toList();
  }

  static Future<Person?> personById(String id) async {
    final d = await db;
    final rows =
        await d.query('people', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Person.fromMap(rows.first);
  }

  static Future<Person> findOrCreatePerson(String name) async {
    final d = await db;
    final clean = name.trim();
    final rows = await d.query('people',
        where: 'LOWER(name) = ?', whereArgs: [clean.toLowerCase()], limit: 1);
    if (rows.isNotEmpty) return Person.fromMap(rows.first);
    final person = Person(name: clean);
    await insertPerson(person);
    return person;
  }

  // ---------- lending ----------

  static Future<void> insertLending(LendingRecord r) async {
    final d = await db;
    await d.insert('lending', r.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _audit(d, 'lending', r.id, 'created',
        '${r.originalAmount} ${r.currency} type=${r.type.name}');
  }

  static Future<void> updateLending(LendingRecord r) async {
    final d = await db;
    await d.update('lending', r.toMap(), where: 'id = ?', whereArgs: [r.id]);
    await _audit(d, 'lending', r.id, 'updated', 'status=${r.status.name}');
  }

  static Future<List<LendingRecord>> lendingForPerson(String personId) async {
    final d = await db;
    final rows = await d.query('lending',
        where: 'personId = ?', whereArgs: [personId], orderBy: 'date DESC');
    return rows.map(LendingRecord.fromMap).toList();
  }

  static Future<List<LendingRecord>> openLendingForPerson(String personId,
      {required bool owedToMe}) async {
    final d = await db;
    final rows = await d.query(
      'lending',
      where: 'personId = ? AND isOwedToMe = ? AND status IN (\'open\', \'partial\')',
      whereArgs: [personId, owedToMe ? 1 : 0],
      orderBy: 'date ASC',
    );
    return rows.map(LendingRecord.fromMap).toList();
  }

  static Future<List<LendingRecord>> allLending() async {
    final d = await db;
    final rows = await d.query('lending', orderBy: 'date DESC');
    return rows.map(LendingRecord.fromMap).toList();
  }

  static Future<List<Repayment>> repaymentsFor(String lendingId) async {
    final d = await db;
    final rows = await d.query('repayments',
        where: 'lendingId = ?', whereArgs: [lendingId], orderBy: 'date ASC');
    return rows.map(Repayment.fromMap).toList();
  }

  static Future<double> totalRepaid(String lendingId) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT SUM(amount) s FROM repayments WHERE lendingId = ?',
        [lendingId]);
    return ((rows.first['s'] as num?) ?? 0).toDouble();
  }

  /// Adds a repayment and auto-updates the lending status.
  /// Returns the new remaining balance.
  static Future<double> addRepayment(Repayment r) async {
    final d = await db;
    await d.insert('repayments', r.toMap());
    final rows = await d.query('lending',
        where: 'id = ?', whereArgs: [r.lendingId], limit: 1);
    if (rows.isEmpty) return 0;
    final lending = LendingRecord.fromMap(rows.first);
    final repaid = await totalRepaid(r.lendingId);
    final remaining = lending.originalAmount - repaid;
    final status = remaining <= 0.005
        ? LendingStatus.settled
        : (repaid > 0 ? LendingStatus.partial : LendingStatus.open);
    await d.update('lending', {'status': status.name, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [r.lendingId]);
    await _audit(d, 'lending', r.lendingId, 'repayment',
        '+${r.amount} repaid=$repaid remaining=$remaining');
    return remaining < 0 ? 0 : remaining;
  }

  static Future<void> deleteRepayment(String id) async {
    final d = await db;
    final rows = await d.query('repayments',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    final r = Repayment.fromMap(rows.first);
    await d.delete('repayments', where: 'id = ?', whereArgs: [id]);
    // Recompute status after unlink.
    final lendingRows = await d.query('lending',
        where: 'id = ?', whereArgs: [r.lendingId], limit: 1);
    if (lendingRows.isNotEmpty) {
      final lending = LendingRecord.fromMap(lendingRows.first);
      final repaid = await totalRepaid(r.lendingId);
      final remaining = lending.originalAmount - repaid;
      final status = remaining <= 0.005
          ? LendingStatus.settled
          : (repaid > 0 ? LendingStatus.partial : LendingStatus.open);
      await d.update('lending', {'status': status.name},
          where: 'id = ?', whereArgs: [r.lendingId]);
    }
    await _audit(d, 'lending', r.lendingId, 'repayment-removed',
        '-${r.amount}');
  }

  // ---------- aliases ----------

  static Future<void> upsertAlias(String rawName, String alias) async {
    final d = await db;
    final clean = rawName.trim();
    final rows = await d.query('aliases',
        where: 'rawName = ?', whereArgs: [clean], limit: 1);
    if (rows.isEmpty) {
      await d.insert(
          'aliases',
          MerchantAlias(rawName: clean, alias: alias.trim()).toMap());
    } else {
      final existing = MerchantAlias.fromMap(rows.first);
      final updated = MerchantAlias(
        id: existing.id,
        rawName: existing.rawName,
        alias: alias.trim(),
        usageCount: existing.usageCount,
        lastUsed: DateTime.now(),
      );
      await d.update('aliases', updated.toMap(),
          where: 'id = ?', whereArgs: [existing.id]);
    }
    await _audit(d, 'alias', clean, 'upserted', alias);
  }

  static Future<MerchantAlias?> aliasFor(String rawName) async {
    final d = await db;
    final rows = await d.query('aliases',
        where: 'rawName = ?', whereArgs: [rawName.trim()], limit: 1);
    return rows.isEmpty ? null : MerchantAlias.fromMap(rows.first);
  }

  static Future<List<MerchantAlias>> allAliases() async {
    final d = await db;
    final rows = await d.query('aliases', orderBy: 'lastUsed DESC');
    return rows.map(MerchantAlias.fromMap).toList();
  }

  /// Suggests an alias for a never-seen raw name using fuzzy match
  /// against known raw names. Returns null when unsure — never guesses.
  static Future<MerchantAlias?> suggestAlias(String rawName) async {
    final d = await db;
    final exact = await aliasFor(rawName);
    if (exact != null) return exact;
    final rows = await d.query('aliases');
    final needle = _norm(rawName);
    for (final row in rows) {
      final a = MerchantAlias.fromMap(row);
      final hay = _norm(a.rawName);
      if (hay.isEmpty || needle.isEmpty) continue;
      if (hay.contains(needle) || needle.contains(hay)) return a;
    }
    return null;
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();

  // ---------- audit / maintenance ----------

  static Future<void> _audit(Database d, String entity, String entityId,
      String action, String detail) async {
    await d.insert('audit', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'entity': entity,
      'entityId': entityId,
      'action': action,
      'detail': detail,
    });
  }

  static Future<void> wipeAll() async {
    final d = await db;
    for (final t in [
      'transactions',
      'people',
      'lending',
      'repayments',
      'aliases',
      'audit'
    ]) {
      await d.delete(t);
    }
  }
}
