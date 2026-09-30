import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/services/sms_parse.dart';

void main() {
  group('parseAlert', () {
    test('Meezan debit SMS -> spend, high confidence', () {
      final r = parseAlert('MEEZAN',
          'Meezan Bank: Your account *1234 has been debited by PKR 2,450.00 at KHAADI LAHORE. Ref: MB-88213. Available balance PKR 120,000.');
      expect(r.confidence, AlertConfidence.high);
      expect(r.isOut, isTrue);
      expect(r.amount, 2450.00);
      expect(r.bank, 'meezan');
      expect(r.merchant, contains('KHAADI'));
      expect(r.reference, isNotNull);
    });

    test('Meezan credit SMS -> received', () {
      final r = parseAlert('MEEZAN',
          'Meezan Bank: Your account *1234 has been credited with PKR 50,000.00. Ref: MB-99100.');
      expect(r.confidence, AlertConfidence.high);
      expect(r.isOut, isFalse);
      expect(r.amount, 50000.00);
      expect(r.bank, 'meezan');
    });

    test('JazzCash sent SMS -> spend', () {
      final r = parseAlert('JAZZCASH',
          'You have sent Rs 1,500.00 to 03001234567 from your JazzCash account. Txn ID 99887766.');
      expect(r.isOut, isTrue);
      expect(r.amount, 1500.00);
      expect(r.bank, 'jazzcash');
    });

    test('Easypaisa received SMS -> received', () {
      final r = parseAlert('EASYPAISA',
          'You have received Rs 3,200.00 in your Easypaisa account from 03459876543. TRX 11223344.');
      expect(r.isOut, isFalse);
      expect(r.amount, 3200.00);
      expect(r.bank, 'easypaisa');
    });

    test('HBL ATM withdrawal -> spend', () {
      final r = parseAlert('HBL',
          'HBL: Cash withdrawal of PKR 20,000.00 from ATM DHA Lahore. Available balance PKR 80,000.');
      expect(r.isOut, isTrue);
      expect(r.amount, 20000.00);
      expect(r.bank, 'hbl');
    });

    test('missing amount -> no confidence', () {
      final r = parseAlert('MEEZAN',
          'Meezan Bank: thank you for using our service.');
      expect(r.confidence, AlertConfidence.none);
      expect(r.amount, isNull);
    });

    test('ambiguous direction -> no confidence', () {
      final r = parseAlert('MEEZAN',
          'Meezan Bank: PKR 5,000.00 transaction alert on your account.');
      expect(r.confidence, AlertConfidence.none);
    });

    test('empty body -> no confidence', () {
      final r = parseAlert('MEEZAN', '   ');
      expect(r.confidence, AlertConfidence.none);
    });

    test('unknown sender still parses when body is clear', () {
      final r = parseAlert('1234',
          'Your account has been debited by PKR 750.00 at METRO STORE.');
      expect(r.isOut, isTrue);
      expect(r.amount, 750.00);
      expect(r.bank, 'unknown');
      expect(r.confidence, isNot(AlertConfidence.none));
    });
  });
}
