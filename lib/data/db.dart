import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/transaction.dart';
import '../models/person.dart';
import '../models/lending.dart';
import '../models/alias.dart';
import '../models/custom_purpose.dart';
import '../models/purposes.dart';

/// On-device SQLite database. Everything stays on the phone —
/// no account, no server, no sync. Free forever.
class YaadDb {
  static const _name = 'yaad.db';
  static const _version = 4;
  static Database? _db;

  static Future<Database> get db async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, _name),
      version: _version,
      onCreate: _create,
      onUpgrade: _upgrade,
    );
    return _db!;
  }

  /// v1 → v2: add the `kind` column and backfill it from
  /// purpose + direction (see [YaadTransaction.migrateKindName]).
  /// Lending rows become lendOut/borrowIn/repayOut/repayIn so they
  /// are never counted as spending again.
  /// v2 → v3: add the `custom_purposes` table (user-created purposes).
  /// v3 → v4: add nullable `audioPath` + `voiceNote` columns for voice
  /// notes (v1.3). Existing rows keep working — both columns are NULL.
  static Future<void> _upgrade(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE transactions ADD COLUMN kind TEXT');
      await db.execute('''
        UPDATE transactions SET kind =
          CASE
            WHEN purpose = 'loan' AND direction = 'out' THEN 'lendOut'
            WHEN purpose = 'loan' THEN 'borrowIn'
            WHEN purpose = 'repaymentIn' AND direction = 'out' THEN 'repayOut'
            WHEN purpose = 'repaymentIn' THEN 'repayIn'
            WHEN purpose = 'gift' AND direction = 'out' THEN 'spend'
            WHEN purpose = 'gift' THEN 'receive'
            WHEN direction = 'out' THEN 'spend'
            WHEN direction = 'incoming' THEN 'receive'
            WHEN direction = 'ownTransfer' THEN 'transfer'
            ELSE 'spend'
          END
      ''');
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE custom_purposes(
          id TEXT PRIMARY KEY,
          label TEXT NOT NULL,
          createdAt INTEGER NOT NULL
        )''');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE transactions ADD COLUMN audioPath TEXT');
      await db.execute('ALTER TABLE transactions ADD COLUMN voiceNote TEXT');
    }
  }

  static Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        dateTime INTEGER NOT NULL,
        direction TEXT NOT NULL,
        kind TEXT,
        rawMerchant TEXT NOT NULL,
        aliasId TEXT,
        purpose TEXT NOT NULL,
        note TEXT NOT NULL,
        tags TEXT NOT NULL,
        receiptPath TEXT,
        audioPath TEXT,
        voiceNote TEXT,
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

    // User-created purposes (spend side). Deleting one reassigns its
    // transactions to 'uncategorized' — see deleteCustomPurpose.
    await db.execute('''
      CREATE TABLE custom_purposes(
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        createdAt INTEGER NOT NULL
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

  /// Deleting a transaction also deletes its voice recording file,
  /// if one was saved — no orphaned audio.
  static Future<void> deleteTxn(String id) async {
    final d = await db;
    final rows = await d.query('transactions',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isNotEmpty) {
      final audio = rows.first['audioPath'] as String?;
      if (audio != null && audio.isNotEmpty) {
        try {
          await File(audio).delete();
        } catch (_) {
          // Missing already is fine.
        }
      }
    }
    await d.delete('transactions', where: 'id = ?', whereArgs: [id]);
    await _audit(d, 'transaction', id, 'deleted', '');
  }

  static Future<List<YaadTransaction>> txns({
    int limit = 200,
    int offset = 0,
    String? status,
    String? query,
    Set<String>? purposes,
    TxnKind? kind,
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
    if (purposes != null && purposes.isNotEmpty) {
      where.add(
          'purpose IN (${List.filled(purposes.length, '?').join(', ')})');
      args.addAll(purposes);
    }
    if (kind != null) {
      where.add('kind = ?');
      args.add(kind.name);
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

  /// Money spent: ONLY kind = 'spend'. Lending is never spending.
  static Future<double> sumSpent(int fromMs, int toMs) =>
      sumByKind(TxnKind.spend, fromMs, toMs);

  /// Money received: ONLY kind = 'receive'.
  static Future<double> sumReceived(int fromMs, int toMs) =>
      sumByKind(TxnKind.receive, fromMs, toMs);

  static Future<double> sumByKind(TxnKind kind, int fromMs, int toMs) async {
    final d = await db;
    final rows = await d.rawQuery(
        "SELECT SUM(amount) s FROM transactions WHERE kind = ? "
        "AND status != 'excluded' AND dateTime BETWEEN ? AND ?",
        [kind.name, fromMs, toMs]);
    return ((rows.first['s'] as num?) ?? 0).toDouble();
  }

  static Future<List<Map<String, Object?>>> sumByPurpose(
      int fromMs, int toMs) async {
    final d = await db;
    return d.rawQuery(
        "SELECT purpose, SUM(amount) total, COUNT(*) n FROM transactions "
        "WHERE kind = 'spend' AND status != 'excluded' "
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

  // ---------- custom purposes ----------

  /// All user-created purposes, oldest first. Included in backup/restore.
  static Future<List<CustomPurpose>> customPurposes() async {
    final d = await db;
    final rows =
        await d.query('custom_purposes', orderBy: 'createdAt ASC');
    return rows.map(CustomPurpose.fromMap).toList();
  }

  /// id → label map, used to rebuild the in-memory registry that
  /// purposeLabel()/purposeIcon() consult.
  static Future<Map<String, String>> customPurposeLabelMap() async {
    final customs = await customPurposes();
    return {for (final c in customs) c.id: c.label};
  }

  /// Rebuilds the in-memory registry after the set of custom purposes
  /// changed (app start, create, delete).
  static Future<void> refreshCustomPurposeRegistry() async {
    registerCustomPurposes(await customPurposeLabelMap());
  }

  /// Inserts a custom purpose; makes the id unique when the slug collides.
  static Future<CustomPurpose> insertCustomPurpose(String label) async {
    final d = await db;
    final clean = label.trim();
    var id = CustomPurpose.idFor(clean);
    var n = 2;
    while ((await d.query('custom_purposes',
            where: 'id = ?', whereArgs: [id], limit: 1))
        .isNotEmpty) {
      id = '${CustomPurpose.idFor(clean)}_$n';
      n++;
    }
    final cp = CustomPurpose(
        id: id, label: clean, createdAt: DateTime.now().millisecondsSinceEpoch);
    await d.insert('custom_purposes', cp.toMap());
    await _audit(d, 'custom_purpose', id, 'created', clean);
    await refreshCustomPurposeRegistry();
    return cp;
  }

  /// Whether a label (case-insensitive) already exists — fixed or custom.
  static Future<bool> purposeLabelExists(String label) async {
    final needle = label.trim().toLowerCase();
    if (needle.isEmpty) return false;
    for (final p in kSpendPurposes) {
      if (p.label.toLowerCase() == needle) return true;
    }
    for (final p in kReceiveSources) {
      if (p.label.toLowerCase() == needle) return true;
    }
    for (final c in await customPurposes()) {
      if (c.label.toLowerCase() == needle) return true;
    }
    return false;
  }

  /// Deletes a custom purpose. Transactions already using it are NEVER
  /// orphaned — they are reassigned to 'uncategorized' ("Other"), the
  /// same neutral default new captures start with.
  static Future<void> deleteCustomPurpose(String id) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn
          .delete('custom_purposes', where: 'id = ?', whereArgs: [id]);
      await txn.update('transactions', {'purpose': 'uncategorized'},
          where: 'purpose = ?', whereArgs: [id]);
    });
    await _audit(d, 'custom_purpose', id, 'deleted',
        'transactions reassigned to uncategorized');
    await refreshCustomPurposeRegistry();
  }

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
