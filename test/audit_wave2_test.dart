import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/account.dart';
import 'package:yaad/models/alias.dart';
import 'package:yaad/models/lending.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/services/app_state.dart';
import 'package:yaad/services/backup.dart';
import 'package:yaad/services/demo_data.dart';
import 'package:yaad/services/importer.dart';
import 'package:yaad/services/ocr.dart';
import 'package:yaad/services/suggest.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Wave-2 regression tests for the build-28 full-app audit: the
/// udhaar link cascades, backup/restore hardening, importer dedupe,
/// and the savings/amount definitions — each pins a defect found by
/// walking features in combination, not in isolation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    docsDir = await Directory.systemTemp.createTemp('yaad-audit-w2-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  setUp(() async {
    await YaadDb.wipeAll();
    await DemoData.clearOpeningsSnapshot();
    SharedPreferences.setMockInitialValues({});
    appState.settings = const AppSettings();
  });

  tearDown(() async {
    await DemoData.clearOpeningsSnapshot();
    appState.settings = const AppSettings();
  });

  YaadTransaction row({
    required String merchant,
    required double amount,
    TxnKind kind = TxnKind.spend,
    TxnDirection direction = TxnDirection.out,
    String? accountId,
    String? toAccountId,
    String? bankReference,
    String? linkedLendingId,
    String? personId,
    String? audioPath,
    TxnStatus status = TxnStatus.confirmed,
    DateTime? when,
  }) =>
      YaadTransaction(
        amount: amount,
        dateTime: when ?? DateTime.now(),
        kind: kind,
        direction: direction,
        rawMerchant: merchant,
        purpose: 'uncategorized',
        bankReference: bankReference,
        linkedLendingId: linkedLendingId,
        personId: personId,
        audioPath: audioPath,
        source: TxnSource.manual,
        status: status,
        accountId: accountId,
        toAccountId: toAccountId,
      );

  group('udhaar link cascades', () {
    test('deleteLending removes repay txns linked ONLY via '
        'linkedLendingId (the shape the UI actually writes)', () async {
      final p = Person(name: 'Ahmed Raza');
      await YaadDb.insertPerson(p);
      final loan = LendingRecord(
          personId: p.id,
          originalAmount: 20000,
          currency: 'PKR',
          date: DateTime(2026, 9, 1),
          reason: 'Bike repair',
          isOwedToMe: true);
      await YaadDb.insertLending(loan);
      // Exactly what RepayScreen wrote before build-28: the
      // REPAYMENT carries no transactionId; only the TRANSACTION
      // points back (linkedLendingId).
      await YaadDb.addRepayment(Repayment(
          lendingId: loan.id, amount: 8000, date: DateTime(2026, 9, 9)));
      await YaadDb.insertTxn(row(
        merchant: 'Ahmed Raza',
        amount: 8000,
        kind: TxnKind.repayIn,
        direction: TxnDirection.incoming,
        accountId: Account.seedMeezan,
        personId: p.id,
        linkedLendingId: loan.id,
        when: DateTime(2026, 9, 9),
      ));
      final before = await YaadDb.accountBalances();
      expect(before[Account.seedMeezan], 8000);

      await YaadDb.deleteLending(loan.id);

      expect(await YaadDb.txns(), isEmpty,
          reason: 'the "Paid back" row must not survive as phantom money');
      expect(await YaadDb.repaymentsFor(loan.id), isEmpty);
      expect((await YaadDb.accountBalances())[Account.seedMeezan], 0);
    });
  });

  group('findDuplicate kind scoping', () {
    test('a receive is not a duplicate of a same-day spend', () async {
      final today = DateTime(2026, 10, 1, 10);
      await YaadDb.insertTxn(row(
          merchant: 'DARAZ',
          amount: 500,
          kind: TxnKind.spend,
          direction: TxnDirection.out,
          accountId: Account.seedMeezan,
          when: today));
      // The refund of the same purchase: same amount, shop, day.
      final asReceive = await YaadDb.findDuplicate(
          amount: 500,
          rawMerchant: 'DARAZ',
          date: today,
          kind: TxnKind.receive);
      expect(asReceive, isNull);
      final asSpend = await YaadDb.findDuplicate(
          amount: 500,
          rawMerchant: 'daraz',
          date: today,
          kind: TxnKind.spend);
      expect(asSpend, isNotNull);
    });
  });

  group('txnCountsByAccount consistency', () {
    test('self-transfer counts once; excluded rows never count; '
        'a transfer counts for both legs', () async {
      await YaadDb.insertTxn(row(
          merchant: 'Self',
          amount: 100,
          kind: TxnKind.transfer,
          direction: TxnDirection.ownTransfer,
          accountId: Account.seedSavings,
          toAccountId: Account.seedSavings));
      await YaadDb.insertTxn(row(
          merchant: 'Ghost',
          amount: 100,
          accountId: Account.seedMeezan,
          status: TxnStatus.excluded));
      await YaadDb.insertTxn(row(
          merchant: 'Move',
          amount: 100,
          kind: TxnKind.transfer,
          direction: TxnDirection.ownTransfer,
          accountId: Account.seedMeezan,
          toAccountId: Account.seedSavings));
      final counts = await YaadDb.txnCountsByAccount();
      expect(counts[Account.seedSavings], 2,
          reason: 'self-move once + incoming move once');
      expect(counts[Account.seedMeezan], 1,
          reason: 'the excluded row must not count; the move out counts');
    });
  });

  group('deleteAccount guards', () {
    test('the last account cannot be deleted', () async {
      final d = await YaadDb.db;
      await d.delete('accounts',
          where: 'id != ?', whereArgs: [Account.seedMeezan]);
      expect(
          () => YaadDb.deleteAccount(Account.seedMeezan,
              reassignTo: Account.seedSavings),
          throwsStateError);
    });

    test('a nonexistent reassign target is refused', () async {
      expect(
          () => YaadDb.deleteAccount(Account.seedCash,
              reassignTo: 'no-such-account'),
          throwsArgumentError);
    });
  });

  group('backup restore hardening', () {
    Future<File> writeBackup(Map<String, Object?> data) async {
      final f = File('${docsDir.path}/test-backup-${DateTime.now().microsecondsSinceEpoch}.json');
      await f.writeAsString(jsonEncode(data));
      return f;
    }

    Map<String, Object?> baseBackup() => {
          'version': 1,
          'app': 'yaad',
          'people': <Object?>[],
          'aliases': <Object?>[],
          'customPurposes': <Object?>[],
          'accounts': <Object?>[],
          'transactions': <Object?>[],
          'lending': <Object?>[],
          'repayments': <Object?>[],
        };

    test('an alias rawName clash skips the alias, not the restore',
        () async {
      await YaadDb.upsertAlias('DARAZ', 'Daraz');
      final txn = row(
          merchant: 'DARAZ',
          amount: 750,
          accountId: Account.seedMeezan,
          when: DateTime(2026, 9, 15));
      final data = baseBackup();
      (data['aliases'] as List).add(MerchantAlias(
              id: 'a-different-id', rawName: 'DARAZ', alias: 'Daraz')
          .toMap());
      (data['transactions'] as List).add(txn.toMap());
      final f = await writeBackup(data);
      final summary = await BackupService().importJson(f.path);
      expect(summary.added, 1,
          reason: 'the transaction must import despite the alias clash');
      expect((await YaadDb.txns()).single.amount, 750);
    });

    test('restored settings never resurrect a transient opt-in flag',
        () async {
      final data = baseBackup();
      data['settings'] = const AppSettings()
          .copyWith(notifOptInPending: true, smsOptInPending: true)
          .toMap();
      final f = await writeBackup(data);
      await BackupService().importJson(f.path);
      final prefs = await SharedPreferences.getInstance();
      final restored = AppSettings.fromMap(Map<String, Object?>.from(
          jsonDecode(prefs.getString(AppState.prefsKey)!) as Map));
      expect(restored.notifOptInPending, isFalse);
      expect(restored.smsOptInPending, isFalse);
    });

    test('attachment paths pointing at missing files are stripped',
        () async {
      final txn = row(
          merchant: 'Voice',
          amount: 100,
          accountId: Account.seedMeezan,
          audioPath: '/no/such/phone/voice_notes/gone.m4a');
      final data = baseBackup();
      (data['transactions'] as List).add(txn.toMap());
      final f = await writeBackup(data);
      await BackupService().importJson(f.path);
      expect((await YaadDb.txns()).single.audioPath, isNull);
    });
  });

  group('demo data across devices', () {
    test('backup → fresh phone → remove demo restores the user openings',
        () async {
      // His real openings on phone A.
      await YaadDb.setOpeningBalance(Account.seedMeezan, 5000);
      await DemoData.addDemo();
      expect(await YaadDb.totalBalance(), greaterThan(100000));
      final backupPath = await BackupService().exportJson();

      // Phone B: nothing but seeds.
      await YaadDb.wipeAll();
      await DemoData.clearOpeningsSnapshot();
      await BackupService().importJson(backupPath);
      expect(await DemoData.hasDemo(), isTrue);

      await DemoData.removeDemo();
      expect(await YaadDb.totalBalance(), 5000,
          reason: 'his own 5,000 opening comes back — not the demo '
              '1,45,000 and not zero');
      expect(await YaadDb.txns(), isEmpty);
    });

    test('remove demo with NO snapshot zeroes the demo openings '
        '(backup from before snapshot export)', () async {
      // Simulate demo rows arriving without a snapshot: demo-flagged
      // rows + demo openings, prefs empty.
      await YaadDb.setOpeningBalance(Account.seedMeezan, 120000);
      await YaadDb.setOpeningBalance(Account.seedSavings, 20000);
      await YaadDb.insertTxn(YaadTransaction(
          amount: 100,
          dateTime: DateTime.now(),
          kind: TxnKind.spend,
          direction: TxnDirection.out,
          rawMerchant: 'Demo row',
          purpose: 'groceries',
          source: TxnSource.manual,
          accountId: Account.seedMeezan,
          isDemo: true));
      expect(await DemoData.hasDemo(), isTrue);
      await DemoData.removeDemo();
      expect(await YaadDb.totalBalance(), 0,
          reason: 'no phantom 1,40,000 may survive removal');
    });

    test('remove demo with no demo data leaves real openings alone',
        () async {
      await YaadDb.setOpeningBalance(Account.seedMeezan, 7000);
      await DemoData.removeDemo();
      expect(await YaadDb.totalBalance(), 7000);
    });
  });

  group('importer dedupe wave-2', () {
    test('a fresh reference does NOT bypass the amount match '
        '(stored copy lost its reference)', () async {
      final day = DateTime(2026, 9, 20, 9);
      // Stored copy from an older path: no reference recorded.
      await YaadDb.insertTxn(row(
          merchant: 'SHELL',
          amount: 3000,
          accountId: Account.seedMeezan,
          when: day));
      final report = await StatementImporter().commitRows([
        ParsedRow(
            date: day,
            merchant: 'SHELL',
            amount: 3000,
            kind: TxnKind.spend,
            reference: 'FT-NEW-1'),
      ], 'sig');
      expect(report.imported, 0);
      expect(report.duplicates, 1);
      expect((await YaadDb.txns()).length, 1);
    });

    test('a spend and a receive of the same amount do not consume '
        'each other', () async {
      final day = DateTime(2026, 9, 21, 9);
      final report = await StatementImporter().commitRows([
        ParsedRow(
            date: day, merchant: 'SHOP', amount: 500, kind: TxnKind.spend),
        ParsedRow(
            date: day,
            merchant: 'SHOP',
            amount: 500,
            kind: TxnKind.receive),
      ], 'sig');
      expect(report.imported, 2);
    });

    test('a forced duplicate imports anyway; currency is honoured',
        () async {
      final day = DateTime(2026, 9, 22, 9);
      await YaadDb.insertTxn(row(
          merchant: 'CHAI',
          amount: 100,
          accountId: Account.seedMeezan,
          when: day));
      final report = await StatementImporter().commitRows([
        ParsedRow(
            date: day,
            merchant: 'CHAI',
            amount: 100,
            kind: TxnKind.spend,
            isDuplicate: true,
            force: true),
      ], 'sig', currency: 'USD');
      expect(report.imported, 1);
      final stored = await YaadDb.txns();
      expect(stored.length, 2);
      expect(stored.map((t) => t.currency), contains('USD'));
    });

    test('a Dr/Cr indicator CSV parses directions from the indicator',
        () async {
      final f = File('${docsDir.path}/drcr.csv');
      await f.writeAsString('Date,Description,Amount,Dr/Cr\n'
          '2026-09-01,COFFEE SHOP,450,DR\n'
          '2026-09-02,SALARY ACME,150000,CR\n');
      final parsed = await StatementImporter().parseFile(f.path);
      expect(parsed.errors, isEmpty);
      expect(parsed.rows.length, 2);
      expect(parsed.rows[0].kind, TxnKind.spend);
      expect(parsed.rows[1].kind, TxnKind.receive);
    });
  });

  group('suggestions are kind-scoped and case-insensitive', () {
    test('spend history never suggests onto a receive (and back)',
        () async {
      await YaadDb.insertTxn(YaadTransaction(
          amount: 900,
          dateTime: DateTime.now(),
          kind: TxnKind.spend,
          direction: TxnDirection.out,
          rawMerchant: 'DARAZ',
          purpose: 'shopping',
          source: TxnSource.manual,
          accountId: Account.seedMeezan));
      final svc = SuggestionService();
      expect(await svc.suggestPurpose('daraz', kind: TxnKind.spend),
          isNotNull,
          reason: 'case-insensitive merchant match within the kind');
      expect(
          (await svc.suggestPurpose('DARAZ', kind: TxnKind.spend))!
              .purpose,
          'shopping');
      expect(await svc.suggestPurpose('DARAZ', kind: TxnKind.receive),
          isNull);
    });
  });

  group('amount sanity + OCR emptiness', () {
    test('isSaneAmount rejects infinity, NaN, zero and absurd values',
        () {
      expect(isSaneAmount(500), isTrue);
      expect(isSaneAmount(0), isFalse);
      expect(isSaneAmount(-5), isFalse);
      expect(isSaneAmount(double.infinity), isFalse);
      expect(isSaneAmount(double.nan), isFalse);
      expect(isSaneAmount(100000000), isFalse);
      // The exact parse that used to poison Udhaar:
      expect(isSaneAmount(double.tryParse('1e309')!), isFalse);
    });

    test('OCR result with only a bank name counts as empty', () {
      expect(const OcrResult(bank: 'Meezan Bank').isEmpty, isTrue);
      expect(
          const OcrResult(transactionType: 'IBFT', bank: 'Meezan')
              .isEmpty,
          isTrue);
      expect(const OcrResult(amount: 100).isEmpty, isFalse);
      expect(const OcrResult(merchant: 'SHOP').isEmpty, isFalse);
    });
  });

  group('wipe leftovers', () {
    test('deleteWipeLeftovers removes recordings, receipts and '
        'export files — and nothing else', () async {
      final voice = Directory('${docsDir.path}/voice_notes')
        ..createSync(recursive: true);
      File('${voice.path}/note1.m4a').writeAsStringSync('audio');
      final receipts = Directory('${docsDir.path}/receipts')
        ..createSync(recursive: true);
      File('${receipts.path}/r1.jpg').writeAsStringSync('img');
      File('${docsDir.path}/yaad-backup-123.json')
          .writeAsStringSync('{}');
      File('${docsDir.path}/yaad-transactions-9.csv')
          .writeAsStringSync('a,b');
      final keep = File('${docsDir.path}/unrelated.txt')
        ..writeAsStringSync('keep me');

      await BackupService.deleteWipeLeftovers();

      expect(voice.existsSync(), isFalse);
      expect(receipts.existsSync(), isFalse);
      expect(File('${docsDir.path}/yaad-backup-123.json').existsSync(),
          isFalse);
      expect(
          File('${docsDir.path}/yaad-transactions-9.csv').existsSync(),
          isFalse);
      expect(keep.existsSync(), isTrue);
    });
  });
}
