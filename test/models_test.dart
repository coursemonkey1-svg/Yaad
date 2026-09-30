import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/models/lending.dart';
import 'package:yaad/models/person.dart';
import 'package:yaad/models/alias.dart';
import 'package:yaad/models/settings.dart';

void main() {
  group('YaadTransaction', () {
    test('toMap/fromMap roundtrip preserves everything', () {
      final t = YaadTransaction(
        amount: 2450.5,
        currency: 'PKR',
        dateTime: DateTime(2026, 9, 30, 14, 30),
        direction: TxnDirection.out,
        rawMerchant: 'MEEZAN*AHMED STORE',
        purpose: 'groceries',
        note: 'weekly run',
        tags: ['home'],
        bankReference: 'MB123',
        source: TxnSource.share,
        status: TxnStatus.needsReview,
      );
      final back = YaadTransaction.fromMap(t.toMap());
      expect(back.id, t.id);
      expect(back.amount, 2450.5);
      expect(back.currency, 'PKR');
      expect(back.dateTime, t.dateTime);
      expect(back.direction, TxnDirection.out);
      expect(back.rawMerchant, 'MEEZAN*AHMED STORE');
      expect(back.purpose, 'groceries');
      expect(back.note, 'weekly run');
      expect(back.tags, ['home']);
      expect(back.bankReference, 'MB123');
      expect(back.source, TxnSource.share);
      expect(back.status, TxnStatus.needsReview);
    });

    test('copyWith updates only what changes', () {
      final t = YaadTransaction(amount: 100, dateTime: DateTime(2026, 1, 1));
      final c = t.copyWith(purpose: 'food', status: TxnStatus.confirmed);
      expect(c.purpose, 'food');
      expect(c.status, TxnStatus.confirmed);
      expect(c.amount, 100);
      expect(c.id, t.id);
    });

    test('fromMap tolerates missing/legacy fields', () {
      final t = YaadTransaction.fromMap({'id': 'x'});
      expect(t.amount, 0.0);
      expect(t.currency, 'PKR');
      expect(t.purpose, 'uncategorized');
      expect(t.status, TxnStatus.confirmed);
      expect(t.tags, isEmpty);
    });
  });

  group('LendingRecord + Repayment', () {
    test('repayment math: original - repaid = remaining', () {
      final l = LendingRecord(
        personId: 'p1',
        originalAmount: 10000,
        date: DateTime(2026, 9, 1),
        reason: 'helped out',
      );
      final repayments = [
        Repayment(lendingId: l.id, amount: 3000, date: DateTime(2026, 9, 10)),
        Repayment(lendingId: l.id, amount: 2000, date: DateTime(2026, 9, 20)),
      ];
      final repaid =
          repayments.fold<double>(0, (a, r) => a + r.amount);
      expect(l.originalAmount - repaid, 5000);
    });

    test('toMap/fromMap roundtrip', () {
      final l = LendingRecord(
        personId: 'p1',
        type: LendingType.sharedExpense,
        originalAmount: 1500,
        date: DateTime(2026, 9, 5),
        isOwedToMe: false,
        status: LendingStatus.partial,
      );
      final back = LendingRecord.fromMap(l.toMap());
      expect(back.personId, 'p1');
      expect(back.type, LendingType.sharedExpense);
      expect(back.originalAmount, 1500);
      expect(back.isOwedToMe, isFalse);
      expect(back.status, LendingStatus.partial);
    });
  });

  group('Person & MerchantAlias', () {
    test('Person roundtrip', () {
      final p = Person(name: 'Ahmed', phone: '03001234567', note: 'cousin');
      final back = Person.fromMap(p.toMap());
      expect(back.name, 'Ahmed');
      expect(back.phone, '03001234567');
      expect(back.note, 'cousin');
    });

    test('MerchantAlias.used bumps the count', () {
      final a =
          MerchantAlias(rawName: 'MEEZAN*X', alias: 'corner shop');
      final b = a.used();
      expect(b.usageCount, 2);
      expect(b.alias, 'corner shop');
      expect(MerchantAlias.fromMap(b.toMap()).usageCount, 2);
    });
  });

  group('AppSettings', () {
    test('defaults are Pakistan-centric', () {
      const s = AppSettings();
      expect(s.currency, 'PKR');
      expect(s.language, 'en');
      expect(s.defaultBank, 'meezan');
      expect(s.appLock, isFalse);
      expect(s.onboardingDone, isFalse);
    });

    test('toMap/fromMap roundtrip', () {
      const s = AppSettings(
          currency: 'USD', language: 'ur', theme: 'dark', appLock: true);
      final back = AppSettings.fromMap(s.toMap());
      expect(back.currency, 'USD');
      expect(back.language, 'ur');
      expect(back.theme, 'dark');
      expect(back.appLock, isTrue);
    });

    test('copyWith', () {
      const s = AppSettings();
      final c = s.copyWith(currency: 'AED', onboardingDone: true);
      expect(c.currency, 'AED');
      expect(c.onboardingDone, isTrue);
      expect(c.language, 'en');
    });
  });
}
