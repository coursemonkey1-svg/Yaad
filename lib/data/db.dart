import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/transaction.dart';
import '../models/account.dart';
import '../models/person.dart';
import '../models/lending.dart';
import '../models/alias.dart';
import '../models/custom_purpose.dart';
import '../models/purposes.dart';

/// On-device SQLite database. Everything stays on the phone —
/// no account, no server, no sync. Free forever.
class YaadDb {
  static const _name = 'yaad.db';
  static const _version = 8;
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
  /// v4 → v5: add the `accounts` table (Meezan / Savings / Cash seeds)
  /// and a nullable `accountId` column on transactions. Every existing
  /// row is backfilled to the default account ('meezan') — no row is
  /// ever left without an account.
  /// v5 → v6: add the nullable `toAccountId` column on transactions —
  /// the destination account of a transfer (e.g. Meezan → Savings).
  /// Existing rows keep working — the column is NULL for them.
  /// v6 → v7: add `isDemo` flag columns (0/1, default 0) to
  /// transactions, people, lending and custom_purposes — the marker
  /// "Remove demo data" uses to delete exactly the sample rows
  /// "Add demo data" created, and nothing real (v1.5).
  /// v7 → v8: add `openingBalance` to accounts — what an account held
  /// before Yaad started tracking it. Balance = opening + every
  /// transaction leg, all time (v1.5).
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
    if (oldVersion < 5) {
      // openingBalance is created WITH the table here (ahead of its
      // v8 step) because _seedAccounts inserts via Account.toMap(),
      // which carries the column — seeding before the column exists
      // would crash every upgrade from DB <= v4 inside onUpgrade and
      // the app could never open its database. The < 8 step below is
      // column-guarded, so it no-ops for these installs.
      await db.execute('''
        CREATE TABLE accounts(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          customName INTEGER NOT NULL DEFAULT 0,
          openingBalance REAL NOT NULL DEFAULT 0,
          createdAt INTEGER NOT NULL
        )''');
      await _seedAccounts(db);
      await db.execute('ALTER TABLE transactions ADD COLUMN accountId TEXT');
      await db.execute(
          "UPDATE transactions SET accountId = '${Account.seedMeezan}' "
          'WHERE accountId IS NULL');
      await db.execute(
          'CREATE INDEX idx_txn_account ON transactions(accountId)');
    }
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE transactions ADD COLUMN toAccountId TEXT');
    }
    if (oldVersion < 7) {
      // Guarded by table existence: production DBs always have all
      // four tables, but a defensive check costs nothing and keeps
      // partial/older replicas from crashing the upgrade.
      final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'");
      final existing = {for (final r in tables) r['name'] as String};
      for (final t in ['transactions', 'people', 'lending', 'custom_purposes']) {
        if (existing.contains(t)) {
          await db.execute(
              'ALTER TABLE $t ADD COLUMN isDemo INTEGER NOT NULL DEFAULT 0');
        }
      }
    }
    if (oldVersion < 8) {
      final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'");
      final existing = {for (final r in tables) r['name'] as String};
      if (existing.contains('accounts')) {
        // Column-guarded: upgrades passing through the < 5 step
        // already created accounts WITH this column (see there).
        final cols =
            await db.rawQuery('PRAGMA table_info(accounts)');
        if (!cols.any((c) => c['name'] == 'openingBalance')) {
          await db.execute(
              'ALTER TABLE accounts ADD COLUMN openingBalance REAL NOT NULL DEFAULT 0');
        }
      }
    }
  }

  /// Inserts the Meezan / Savings / Cash seeds. INSERT OR IGNORE:
  /// migrations and restores never duplicate them (matched by id).
  static Future<void> _seedAccounts(DatabaseExecutor db) async {
    for (final a in Account.seeds()) {
      await db.insert('accounts', a.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
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
        accountId TEXT,
        toAccountId TEXT,
        isDemo INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )''');
    await db.execute(
        'CREATE INDEX idx_txn_date ON transactions(dateTime DESC)');
    await db.execute(
        'CREATE INDEX idx_txn_status ON transactions(status)');
    await db.execute(
        'CREATE INDEX idx_txn_ref ON transactions(bankReference)');
    await db.execute(
        'CREATE INDEX idx_txn_account ON transactions(accountId)');

    await db.execute('''
      CREATE TABLE people(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        note TEXT NOT NULL,
        isDemo INTEGER NOT NULL DEFAULT 0,
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
        isDemo INTEGER NOT NULL DEFAULT 0,
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
        isDemo INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL
      )''');

    // Money accounts (Meezan / Savings / Cash + the user's own).
    // `customName` tracks seeded renames for localisation.
    await db.execute('''
      CREATE TABLE accounts(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        customName INTEGER NOT NULL DEFAULT 0,
        openingBalance REAL NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL
      )''');
    await _seedAccounts(db);

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
    Set<String>? accountIds,
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
    if (accountIds != null && accountIds.isNotEmpty) {
      where.add(
          'accountId IN (${List.filled(accountIds.length, '?').join(', ')})');
      args.addAll(accountIds);
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
  static Future<double> sumSpent(int fromMs, int toMs,
          {Set<String>? accountIds}) =>
      sumByKind(TxnKind.spend, fromMs, toMs, accountIds: accountIds);

  /// Money received: ONLY kind = 'receive'.
  static Future<double> sumReceived(int fromMs, int toMs,
          {Set<String>? accountIds}) =>
      sumByKind(TxnKind.receive, fromMs, toMs, accountIds: accountIds);

  static Future<double> sumByKind(TxnKind kind, int fromMs, int toMs,
      {Set<String>? accountIds}) async {
    final d = await db;
    final where = StringBuffer(
        "kind = ? AND status != 'excluded' AND dateTime BETWEEN ? AND ?");
    final args = <Object?>[kind.name, fromMs, toMs];
    if (accountIds != null && accountIds.isNotEmpty) {
      where.write(
          ' AND accountId IN (${List.filled(accountIds.length, '?').join(', ')})');
      args.addAll(accountIds);
    }
    final rows = await d.rawQuery(
        'SELECT SUM(amount) s FROM transactions WHERE ${where.toString()}',
        args);
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

  /// Net money parked in savings between two moments: transfers INTO
  /// the savings account minus transfers OUT of it. The two legs are
  /// summed INDEPENDENTLY — one transfer row carries both legs
  /// (accountId = from, toAccountId = to), and a row whose legs are
  /// both Savings (a self-transfer, e.g. one recorded while the
  /// default account was Savings itself) must net to exactly zero,
  /// never count as new parked money. A single WHEN/WHEN CASE gets
  /// that wrong: it matches the "in" leg first and invents savings.
  ///
  /// Transfers are kind 'transfer', never 'spend'/'receive', so
  /// [sumSpent]/[sumReceived] stay clean no matter how much moves.
  static Future<double> savingsNet(int fromMs, int toMs) async {
    final d = await db;
    final sid = Account.seedSavings;
    final rows = await d.rawQuery('''
      SELECT
        SUM(CASE WHEN toAccountId = ? THEN amount ELSE 0 END) +
        SUM(CASE WHEN accountId = ? THEN -amount ELSE 0 END) s
      FROM transactions
      WHERE kind = 'transfer' AND status != 'excluded'
        AND (accountId = ? OR toAccountId = ?)
        AND dateTime BETWEEN ? AND ?
    ''', [sid, sid, sid, sid, fromMs, toMs]);
    return ((rows.first['s'] as num?) ?? 0).toDouble();
  }

  /// Everything ever parked in savings (in − out, all time).
  static Future<double> savingsTotal() =>
      savingsNet(0, DateTime.now().millisecondsSinceEpoch);

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

  /// Recomputes a lending record's status from its repayments:
  /// settled when nothing remains, partial when some is repaid,
  /// open otherwise. Called after any edit that changes the amounts
  /// (editing a lend/borrow amount, editing a repayment) so the
  /// person's outstanding figures are always derived, never stale.
  static Future<void> refreshLendingStatus(String lendingId) async {
    final d = await db;
    final rows = await d.query('lending',
        where: 'id = ?', whereArgs: [lendingId], limit: 1);
    if (rows.isEmpty) return;
    final lending = LendingRecord.fromMap(rows.first);
    if (lending.status == LendingStatus.writtenOff ||
        lending.status == LendingStatus.gift) {
      return; // terminal states an amount edit must not resurrect
    }
    final repaid = await totalRepaid(lendingId);
    final remaining = lending.originalAmount - repaid;
    final status = remaining <= 0.005
        ? LendingStatus.settled
        : (repaid > 0 ? LendingStatus.partial : LendingStatus.open);
    await d.update(
        'lending',
        {'status': status.name, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [lendingId]);
  }

  /// Updates a repayment (amount / date / note) and keeps everything
  /// derived in step: the parent lending status, and the repayment's
  /// linked transaction amount/date when one exists.
  static Future<void> updateRepayment(Repayment r) async {
    final d = await db;
    await d.update('repayments', r.toMap(),
        where: 'id = ?', whereArgs: [r.id]);
    if (r.transactionId != null) {
      await d.update(
          'transactions',
          {
            'amount': r.amount,
            'dateTime': r.date.millisecondsSinceEpoch,
            'note': r.note,
          },
          where: 'id = ?',
          whereArgs: [r.transactionId]);
    }
    await refreshLendingStatus(r.lendingId);
    await _audit(d, 'lending', r.lendingId, 'repayment-updated',
        '${r.amount}');
  }

  /// Deletes a lending record and everything hanging off it: its
  /// repayments and the transactions those repayments created (via
  /// Repayment.transactionId). The lend/borrow entry itself has no
  /// transaction in the current model — the Lend/Borrow screens write
  /// only the record — so nothing else needs cleanup.
  static Future<void> deleteLending(String id) async {
    final d = await db;
    await d.transaction((txn) async {
      final reps = await txn.query('repayments',
          where: 'lendingId = ?', whereArgs: [id]);
      for (final r in reps) {
        final tid = r['transactionId'] as String?;
        if (tid != null && tid.isNotEmpty) {
          await txn.delete('transactions',
              where: 'id = ?', whereArgs: [tid]);
        }
      }
      await txn.delete('repayments',
          where: 'lendingId = ?', whereArgs: [id]);
      await txn.delete('lending', where: 'id = ?', whereArgs: [id]);
    });
    await _audit(d, 'lending', id, 'deleted', 'with repayments');
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

  // ---------- accounts ----------

  /// All money accounts, oldest first. Included in backup/restore.
  static Future<List<Account>> accounts() async {
    final d = await db;
    final rows = await d.query('accounts', orderBy: 'createdAt ASC');
    return rows.map(Account.fromMap).toList();
  }

  static Future<Account?> accountById(String id) async {
    final d = await db;
    final rows = await d.query('accounts',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Account.fromMap(rows.first);
  }

  /// Whether an account name (case-insensitive) is already taken.
  static Future<bool> accountNameExists(String name) async {
    final d = await db;
    final rows = await d.query('accounts',
        where: 'LOWER(name) = ?',
        whereArgs: [name.trim().toLowerCase()],
        limit: 1);
    return rows.isNotEmpty;
  }

  /// Adds a user account. Throws [StateError] when the name is taken.
  static Future<Account> insertAccount(String name,
      {double openingBalance = 0}) async {
    final d = await db;
    final clean = name.trim();
    if (await accountNameExists(clean)) {
      throw StateError('Account "$clean" already exists');
    }
    final a = Account.named(clean, openingBalance: openingBalance);
    await d.insert('accounts', a.toMap());
    await _audit(d, 'account', a.id, 'created', clean);
    return a;
  }

  /// Sets an account's opening balance (what it held before Yaad).
  static Future<void> setOpeningBalance(String id, double amount) async {
    final d = await db;
    await d.update('accounts', {'openingBalance': amount},
        where: 'id = ?', whereArgs: [id]);
    await _audit(d, 'account', id, 'opening-balance', '$amount');
  }

  /// Balance per account id: opening balance + every transaction leg,
  /// all time. Sign rules mirror the month sums exactly — money-in
  /// kinds (receive / borrowIn / repayIn) add, money-out kinds (spend
  /// / lendOut / repayOut) subtract, and a transfer subtracts from its
  /// from-account and adds to its to-account, so parking in savings
  /// raises the Savings balance and taking back lowers it again.
  /// 'excluded' rows never count (same as the sums). Pure lending
  /// records are not transactions, so they don't move balances —
  /// exactly how the month sums treat them; their repayment
  /// transactions do. Every account appears, even with no rows.
  static Future<Map<String, double>> accountBalances() async {
    final d = await db;
    final balances = <String, double>{
      for (final a in await accounts()) a.id: a.openingBalance
    };
    final rows = await d.rawQuery('''
      SELECT accountId, toAccountId, kind, SUM(amount) s
      FROM transactions
      WHERE status != 'excluded'
      GROUP BY accountId, toAccountId, kind''');
    bool isIn(String kind) =>
        kind == 'receive' || kind == 'borrowIn' || kind == 'repayIn';
    for (final r in rows) {
      final kind = (r['kind'] as String?) ?? '';
      final amt = ((r['s'] as num?) ?? 0).toDouble();
      final from = r['accountId'] as String?;
      final to = r['toAccountId'] as String?;
      if (kind == 'transfer') {
        if (from != null && balances.containsKey(from)) {
          balances[from] = balances[from]! - amt;
        }
        if (to != null && balances.containsKey(to)) {
          balances[to] = balances[to]! + amt;
        }
      } else if (from != null && balances.containsKey(from)) {
        balances[from] = balances[from]! + (isIn(kind) ? amt : -amt);
      }
    }
    return balances;
  }

  /// Total across all accounts (openings + all legs).
  static Future<double> totalBalance() async {
    final Map<String, double> b = await accountBalances();
    var total = 0.0;
    for (final v in b.values) {
      total += v;
    }
    return total;
  }

  /// Renames an account. Seeded accounts keep their id; the rename is
  /// remembered (`customName`) so the localised label is no longer used.
  /// Throws [StateError] when the name is taken by another account.
  static Future<void> renameAccount(String id, String name) async {
    final d = await db;
    final clean = name.trim();
    final clash = await d.query('accounts',
        where: 'LOWER(name) = ? AND id != ?',
        whereArgs: [clean.toLowerCase(), id],
        limit: 1);
    if (clash.isNotEmpty) {
      throw StateError('Account "$clean" already exists');
    }
    await d.update('accounts', {'name': clean, 'customName': 1},
        where: 'id = ?', whereArgs: [id]);
    await _audit(d, 'account', id, 'renamed', clean);
  }

  /// Deletes an account. Its transactions are NEVER orphaned or
  /// deleted — they move to [reassignTo] (the default account, or the
  /// new default when the deleted one was default). Transfer rows
  /// pointing at it as a destination move too. The last account
  /// cannot be deleted — callers check [accounts] first.
  static Future<void> deleteAccount(String id,
      {required String reassignTo}) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.update('transactions', {'accountId': reassignTo},
          where: 'accountId = ?', whereArgs: [id]);
      await txn.update('transactions', {'toAccountId': reassignTo},
          where: 'toAccountId = ?', whereArgs: [id]);
      await txn.delete('accounts', where: 'id = ?', whereArgs: [id]);
    });
    await _audit(d, 'account', id, 'deleted',
        'transactions reassigned to $reassignTo');
  }

  /// Transaction counts per account id (for the manage screen).
  /// A transfer touches TWO accounts — it leaves one and arrives in
  /// the other — so it counts for both legs (before build-26 only the
  /// from-leg was counted, and a savings account that had only ever
  /// RECEIVED transfers showed "0 transactions"). Every other row
  /// counts once, for its own account. A NULL accountId keeps the
  /// legacy '' key.
  static Future<Map<String, int>> txnCountsByAccount() async {
    final d = await db;
    final rows = await d.rawQuery('''
      SELECT leg, COUNT(*) n FROM (
        SELECT COALESCE(accountId, '') leg FROM transactions
        UNION ALL
        SELECT toAccountId leg FROM transactions
          WHERE toAccountId IS NOT NULL
      ) GROUP BY leg''');
    return {
      for (final r in rows)
        (r['leg'] as String? ?? ''): (r['n'] as int?) ?? 0
    };
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

  /// "Delete all my data" — a factory reset of everything the user
  /// put in, in one transaction. The accounts table goes too:
  /// opening balances are user data (v1.5), and a wipe that left
  /// them behind still showed the user's money on the Home Balance
  /// card after everything else read zero. Exactly the three seed
  /// accounts are restored (opening balance 0) via the same seeding
  /// path as DB creation, so the app is never left without accounts.
  static Future<void> wipeAll() async {
    final d = await db;
    await d.transaction((txn) async {
      for (final t in [
        'transactions',
        'people',
        'lending',
        'repayments',
        'aliases',
        'custom_purposes',
        'audit',
        'accounts'
      ]) {
        await txn.delete(t);
      }
      await _seedAccounts(txn);
    });
    await refreshCustomPurposeRegistry();
  }
}
