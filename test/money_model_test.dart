import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/models/transaction.dart';

void main() {
  group('money buckets never mix', () {
    test('seven kinds exist, including transfer', () {
      expect(TxnKind.values.length, 7);
      expect(TxnKind.values, contains(TxnKind.transfer));
    });

    test('kind labels are plain words, never debit/credit/outflow', () {
      for (final k in TxnKind.values) {
        final label = kindLabel(k).toLowerCase();
        expect(label, isNot(contains('debit')));
        expect(label, isNot(contains('credit')));
        expect(label, isNot(contains('outflow')));
        expect(label, isNotEmpty);
      }
    });

    test('kind derives from legacy direction when not supplied', () {
      YaadTransaction t(String d) => YaadTransaction(
            amount: 100,
            dateTime: DateTime(2026, 1, 1),
            direction: TxnDirection.values
                .firstWhere((e) => e.name == d),
          );
      expect(t('out').kind, TxnKind.spend);
      expect(t('incoming').kind, TxnKind.receive);
      expect(t('ownTransfer').kind, TxnKind.transfer);
    });

    test('explicit kind survives a toMap/fromMap roundtrip', () {
      final t = YaadTransaction(
        amount: 5000,
        dateTime: DateTime(2026, 2, 2),
        direction: TxnDirection.out,
        kind: TxnKind.lendOut,
      );
      final back = YaadTransaction.fromMap(t.toMap());
      expect(back.kind, TxnKind.lendOut);
    });

    test('kind names are stable for DB storage', () {
      expect(TxnKind.spend.name, 'spend');
      expect(TxnKind.receive.name, 'receive');
      expect(TxnKind.lendOut.name, 'lendOut');
      expect(TxnKind.borrowIn.name, 'borrowIn');
      expect(TxnKind.repayOut.name, 'repayOut');
      expect(TxnKind.repayIn.name, 'repayIn');
      expect(TxnKind.transfer.name, 'transfer');
    });
  });
}
