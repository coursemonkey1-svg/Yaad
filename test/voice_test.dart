import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/models/transaction.dart';

/// Voice notes (v1.3): the model round-trips audioPath/voiceNote, the
/// transcript stays in its own field apart from the typed note, the
/// v3 → v4 migration adds the new columns without touching rows, and
/// deleting a transaction deletes its recording file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('model', () {
    test('audioPath and voiceNote round-trip through toMap/fromMap', () {
      final t = YaadTransaction(
        amount: 250,
        dateTime: DateTime(2026, 9, 30),
        note: 'typed note',
        audioPath: '/docs/voice_notes/voice_1.m4a',
        voiceNote: 'doodh lena hai',
      );
      final back = YaadTransaction.fromMap(t.toMap());
      expect(back.audioPath, '/docs/voice_notes/voice_1.m4a');
      expect(back.voiceNote, 'doodh lena hai');
      expect(back.note, 'typed note');
    });

    test('typed note and voice transcript are stored in separate fields', () {
      final t = YaadTransaction(
        amount: 100,
        dateTime: DateTime.now(),
        note: 'typed by hand',
        voiceNote: 'spoken words',
      );
      final m = t.toMap();
      expect(m['note'], 'typed by hand');
      expect(m['voiceNote'], 'spoken words');
      expect(m['note'], isNot(equals(m['voiceNote'])));
    });

    test('copyWith can clear the voice fields to null, keeps them by default',
        () {
      final t = YaadTransaction(
        amount: 1,
        dateTime: DateTime.now(),
        audioPath: '/x.m4a',
        voiceNote: 'hi',
      );
      final cleared = t.copyWith(audioPath: null, voiceNote: null);
      expect(cleared.audioPath, isNull);
      expect(cleared.voiceNote, isNull);
      final kept = t.copyWith(note: 'changed');
      expect(kept.audioPath, '/x.m4a');
      expect(kept.voiceNote, 'hi');
    });

    test('rows without voice data read as null (old DB rows)', () {
      final t = YaadTransaction(amount: 5, dateTime: DateTime.now());
      final back = YaadTransaction.fromMap(t.toMap());
      expect(back.audioPath, isNull);
      expect(back.voiceNote, isNull);
    });
  });

  group('database', () {
    /// Faithful replica of the v3 transactions schema (pre-v1.3):
    /// has `kind`, no voice columns.
    Future<String> freshV3Db() async {      final dir = await getDatabasesPath();
      final path = p.join(dir, 'yaad.db');
      try {
        await File(path).delete();
      } catch (_) {}
      final db = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 3,
            onCreate: (db, v) async {},
          ));
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
          bankReference TEXT,
          source TEXT NOT NULL,
          status TEXT NOT NULL,
          personId TEXT,
          linkedLendingId TEXT,
          createdAt INTEGER NOT NULL,
          updatedAt INTEGER NOT NULL
        )''');
      await db.execute('''
        CREATE TABLE custom_purposes(
          id TEXT PRIMARY KEY,
          label TEXT NOT NULL,
          createdAt INTEGER NOT NULL
        )''');
      await db.execute('''
        CREATE TABLE audit(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          at INTEGER NOT NULL,
          entity TEXT NOT NULL,
          entityId TEXT NOT NULL,
          action TEXT NOT NULL,
          detail TEXT NOT NULL
        )''');
      await db.insert('transactions', {
        'id': 'old-row-1',
        'amount': 120.0,
        'currency': 'PKR',
        'dateTime': DateTime(2026, 9, 28).millisecondsSinceEpoch,
        'direction': 'out',
        'kind': 'spend',
        'rawMerchant': 'corner shop',
        'purpose': 'groceries',
        'note': 'old note',
        'tags': '',
        'source': 'manual',
        'status': 'confirmed',
        'createdAt': 1,
        'updatedAt': 1,
      });
      await db.close();
      return path;
    }

    test('v3 -> v4 adds audioPath/voiceNote columns, existing rows intact',
        () async {
      await freshV3Db();
      final d = await YaadDb.db; // triggers the real onUpgrade to v4
      final cols = await d.rawQuery('PRAGMA table_info(transactions)');
      final names = {for (final c in cols) c['name'] as String};
      expect(names.contains('audioPath'), isTrue);
      expect(names.contains('voiceNote'), isTrue);

      final t = await YaadDb.txnById('old-row-1');
      expect(t, isNotNull);
      expect(t!.amount, 120.0);
      expect(t.note, 'old note');
      expect(t.kind, TxnKind.spend);
      expect(t.audioPath, isNull);
      expect(t.voiceNote, isNull);
    });

    // The v3 layout above lives at the shared test-DB path, which every
    // DB test file uses — and it lacks the people/lending/repayments/
    // aliases tables. Heal it to the full schema here so a leftover
    // partial file can never break another file's setUp with
    // "no such table". (Deleting the file instead is NOT safe: this
    // isolate's later tests keep writing through YaadDb's cached
    // connection, and SQLite refuses writes once its file is moved.)
    tearDown(() async {
      final d = await YaadDb.db;
      for (final ddl in [
        '''CREATE TABLE IF NOT EXISTS people(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          phone TEXT,
          note TEXT NOT NULL,
          createdAt INTEGER NOT NULL
        )''',
        '''CREATE TABLE IF NOT EXISTS lending(
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
        )''',
        '''CREATE TABLE IF NOT EXISTS repayments(
          id TEXT PRIMARY KEY,
          lendingId TEXT NOT NULL,
          amount REAL NOT NULL,
          date INTEGER NOT NULL,
          note TEXT NOT NULL,
          transactionId TEXT
        )''',
        '''CREATE TABLE IF NOT EXISTS aliases(
          id TEXT PRIMARY KEY,
          rawName TEXT NOT NULL UNIQUE,
          alias TEXT NOT NULL,
          usageCount INTEGER NOT NULL,
          lastUsed INTEGER NOT NULL
        )''',
      ]) {
        await d.execute(ddl);
      }
    });

    test('deleteTxn deletes the attached audio file', () async {
      final d = await YaadDb.db;
      expect(d, isNotNull);
      final dir = await getDatabasesPath();
      final audio = File(p.join(dir, 'voice_del_test.m4a'));
      await audio.writeAsString('fake-audio');
      final t = YaadTransaction(
        amount: 50,
        dateTime: DateTime.now(),
        audioPath: audio.path,
        voiceNote: 'test transcript',
      );
      await YaadDb.insertTxn(t);
      expect(await YaadDb.txnById(t.id), isNotNull);

      await YaadDb.deleteTxn(t.id);
      expect(await audio.exists(), isFalse);
      expect(await YaadDb.txnById(t.id), isNull);
    });

    test('deleteTxn tolerates a missing audio file', () async {
      final t = YaadTransaction(
        amount: 60,
        dateTime: DateTime.now(),
        audioPath: '/does/not/exist.m4a',
      );
      await YaadDb.insertTxn(t);
      await YaadDb.deleteTxn(t.id); // must not throw
      expect(await YaadDb.txnById(t.id), isNull);
    });
  });
}
