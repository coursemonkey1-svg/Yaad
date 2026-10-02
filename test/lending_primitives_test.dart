import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaad/data/db.dart';
import 'package:yaad/models/lending.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/transaction.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// DB primitives behind editable Udhaar history (v1.5):
/// refreshLendingStatus, updateRepayment, deleteLending. These are
/// what the person-screen edit/delete flows call; the person's
/// outstanding figures must always be derivable afterwards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final docsDir =
        await Directory.systemTemp.createTemp('yaad-lending-edit-test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  Future<void> clear() async {
    final d = await YaadDb.db;
    for (final t in ['transactions', 'people', 'lending', 'repayments']) {
      await d.delete(t);
    }
  }

  Future<LendingRecord> seedLoan({
    double amount = 10000,
    double repaid = 0,
    bool withTxn = false,
  }) async {
    final person = Person(name: 'Test Person');
    await YaadDb.insertPerson(person);
    final loan = LendingRecord(
      personId: person.id,
      originalAmount: amount,
      date: DateTime(2026, 9, 10),
      reason: 'Test loan',
      isOwedToMe: true,
    );
    await YaadDb.insertLending(loan);
    if (repaid > 0) {
      String? txnId;
      if (withTxn) {
        final t = YaadTransaction(
          amount: repaid,
          dateTime: DateTime(2026, 9, 20),
          kind: TxnKind.repayIn,
          direction: TxnDirection.incoming,
          rawMerchant: 'Test Person',
          personId: person.id,
        );
        txnId = t.id;
        await YaadDb.insertTxn(t);
      }
      await YaadDb.addRepayment(Repayment(
        lendingId: loan.id,
        amount: repaid,
        date: DateTime(2026, 9, 20),
        transactionId: txnId,
      ));
    }
    return loan;
  }

  test('editing a lend amount recomputes status via refresh', () async {
    await clear();
    final loan = await seedLoan(amount: 10000, repaid: 4000);
    var rows = await YaadDb.lendingForPerson(loan.personId);
    expect(rows.single.status, LendingStatus.partial);
    // Raise the amount: still partial, remaining grows.
    await YaadDb.updateLending(
        rows.single.copyWith(originalAmount: 15000));
    await YaadDb.refreshLendingStatus(loan.id);
    rows = await YaadDb.lendingForPerson(loan.personId);
    expect(rows.single.status, LendingStatus.partial);
    // Lower it to exactly what was repaid: settles.
    await YaadDb.updateLending(rows.single.copyWith(originalAmount: 4000));
    await YaadDb.refreshLendingStatus(loan.id);
    rows = await YaadDb.lendingForPerson(loan.personId);
    expect(rows.single.status, LendingStatus.settled);
  });

  test('updateRepayment moves totals, status and the linked txn',
      () async {
    await clear();
    final loan = await seedLoan(amount: 10000, repaid: 4000, withTxn: true);
    final reps = await YaadDb.repaymentsFor(loan.id);
    expect(reps.length, 1);
    final rep = reps.single;
    await YaadDb.updateRepayment(Repayment(
      id: rep.id,
      lendingId: rep.lendingId,
      amount: 10000,
      date: DateTime(2026, 9, 25),
      note: rep.note,
      transactionId: rep.transactionId,
    ));
    expect(await YaadDb.totalRepaid(loan.id), 10000);
    final rows = await YaadDb.lendingForPerson(loan.personId);
    expect(rows.single.status, LendingStatus.settled);
    final txn = await YaadDb.txnById(rep.transactionId!);
    expect(txn!.amount, 10000);
    expect(txn.dateTime, DateTime(2026, 9, 25));
  });

  test('deleteLending cascades repayments and their transactions',
      () async {
    await clear();
    final loan = await seedLoan(amount: 10000, repaid: 4000, withTxn: true);
    final rep = (await YaadDb.repaymentsFor(loan.id)).single;
    await YaadDb.deleteLending(loan.id);
    expect(await YaadDb.lendingForPerson(loan.personId), isEmpty);
    expect(await YaadDb.repaymentsFor(loan.id), isEmpty);
    expect(await YaadDb.txnById(rep.transactionId!), isNull);
    // The person survives — only the loan went away.
    expect(await YaadDb.personById(loan.personId), isNotNull);
  });

  test('deleting a repayment reopens a settled loan', () async {
    await clear();
    final loan = await seedLoan(amount: 5000, repaid: 5000);
    var rows = await YaadDb.lendingForPerson(loan.personId);
    expect(rows.single.status, LendingStatus.settled);
    final rep = (await YaadDb.repaymentsFor(loan.id)).single;
    await YaadDb.deleteRepayment(rep.id);
    rows = await YaadDb.lendingForPerson(loan.personId);
    expect(rows.single.status, LendingStatus.open);
    expect(await YaadDb.totalRepaid(loan.id), 0);
  });
}
