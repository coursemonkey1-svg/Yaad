import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/services/ocr.dart';

// NOTE: the "verbatim Meezan receipt" fixture below is RECONSTRUCTED from
// the receipt screenshot Inzimam shared (Transaction Successful /
// PKR 8,000 / Sep 28, 2026 | 5:07 PM / From Account: Ali Raza /
// 4501xxx2047 / To Account: Fatima Khan / 0324xxx6500 /
// Reference Number (STAN): 534946 / Transaction Type: 1LINK IBFT),
// not from live OCR output — line breaks follow the visual layout.

/// Reconstructed Meezan receipt (see note above).
const meezanReceipt = '''
Transaction Successful
PKR 8,000
Sep 28, 2026 | 5:07 PM
Meezan Bank
From Account:
Ali Raza
4501xxx2047
To Account:
Fatima Khan
0324xxx6500
Reference Number (STAN): 534946
Transaction Type: 1LINK IBFT
''';

void main() {
  final ocr = OcrService();

  group('parseText — Meezan-style receipt text', () {
    test('extracts amount, merchant, date, reference', () {
      const text = '''
Meezan Bank
Transaction Successful
To: Ahmed Store
Amount: Rs. 2,450.00
Date: 30-Sep-2026
Ref No: MB123456789
''';
      final r = ocr.parseText(text);
      expect(r.amount, 2450.0);
      expect(r.merchant, 'Ahmed Store');
      expect(r.date, DateTime(2026, 9, 30));
      expect(r.reference, 'MB123456789');
    });

    test('handles PKR prefix and d/m/y dates', () {
      const text = 'Paid PKR 500 to Corner Bakery on 29/09/2026 RRN 998877';
      final r = ocr.parseText(text);
      expect(r.amount, 500.0);
      expect(r.date, DateTime(2026, 9, 29));
      expect(r.reference, '998877');
    });

    test('empty text gives empty result — never guesses', () {
      final r = ocr.parseText('   ');
      expect(r.amount, isNull);
      expect(r.merchant, isNull);
      expect(r.date, isNull);
      expect(r.reference, isNull);
      expect(r.isEmpty, isTrue);
    });

    test('no amount present → null amount, rest still parsed', () {
      const text = 'To: Grocery\nDate: 01-10-2026';
      final r = ocr.parseText(text);
      expect(r.amount, isNull);
      expect(r.merchant, 'Grocery');
      expect(r.date, DateTime(2026, 10, 1));
    });
  });

  group('findDate', () {
    test('parses dd-MMM-yyyy', () {
      expect(ocr.findDate('30-Sep-2026'), DateTime(2026, 9, 30));
    });
    test('parses dd/mm/yyyy', () {
      expect(ocr.findDate('01/12/2025'), DateTime(2025, 12, 1));
    });
    test('parses yyyy-mm-dd', () {
      expect(ocr.findDate('2026-09-30'), DateTime(2026, 9, 30));
    });
    test('parses month-first "Sep 28, 2026"', () {
      expect(ocr.findDate('Sep 28, 2026'), DateTime(2026, 9, 28));
    });
    test('returns null when no date', () {
      expect(ocr.findDate('no date here'), isNull);
    });
  });

  group('v1.2 — Meezan receipt (reconstructed fixture)', () {
    test('full extraction', () {
      final r = ocr.parseText(meezanReceipt);
      expect(r.amount, 8000.0);
      expect(r.confidence['amount'], 0.90); // hero standalone line
      expect(r.date, DateTime(2026, 9, 28, 17, 7));
      expect(r.sender, 'Ali Raza');
      expect(r.senderAccount, '4501xxx2047');
      expect(r.recipient, 'Fatima Khan');
      expect(r.recipientAccount, '0324xxx6500');
      expect(r.merchant, 'Fatima Khan'); // legacy compat
      expect(r.reference, '534946');
      expect(r.transactionType, 'ibft');
      expect(r.transactionTypeRaw, '1LINK IBFT');
      expect(r.bank, 'meezan');
      expect(r.isEmpty, isFalse);
    });
  });

  group('v1.2 — Easypaisa SMS fee/balance trap (reconstructed)', () {
    test('amount is 500, not the fee or the balance', () {
      const sms = 'You have sent Rs 500 to 03458501830 on 28-Sep-2026. '
          'Fee Rs. 10 will apply. Your balance is Rs. 9,000.00';
      final r = ocr.parseText(sms);
      expect(r.amount, 500.0);
      expect(r.recipientAccount, '03458501830');
      expect(r.date, DateTime(2026, 9, 28));
    });
  });

  group('v1.2 — JazzCash TID (reconstructed)', () {
    test('12-digit TID captured as reference', () {
      const text = '''
JazzCash
Transaction Successful
TID: 123456789012
Amount: Rs. 1,200
Date: 28/09/2026
''';
      final r = ocr.parseText(text);
      expect(r.reference, '123456789012');
      expect(r.amount, 1200.0);
      expect(r.date, DateTime(2026, 9, 28));
      expect(r.bank, 'jazzcash');
    });
  });

  group('v1.2 — OCR noise (reconstructed)', () {
    test('digit-context noise is repaired', () {
      const text = '''
Transaction Successful
PKR 8,0O0
5ep 28, 2026 | 5;07 PM
From Account:
Ali Raza
STAN: 53494l
''';
      final r = ocr.parseText(text);
      expect(r.amount, 8000.0);
      expect(r.date, DateTime(2026, 9, 28, 17, 7));
      expect(r.reference, '534941');
      expect(r.sender, 'Ali Raza');
    });
  });

  group('v1.2 — relative dates', () {
    test('today / yesterday with injected now', () {
      final now = DateTime(2026, 9, 30, 12, 0);
      final t = ocr.parseText('Paid Rs 100 today', now: now);
      expect(t.date, DateTime(2026, 9, 30));
      final y = ocr.parseText('Paid Rs 100 yesterday', now: now);
      expect(y.date, DateTime(2026, 9, 29));
    });
  });

  group('v1.2 — garbage input', () {
    test('isEmpty, complete missingFields, never throws', () {
      final r = ocr.parseText('hello world this is not a receipt xyz');
      expect(r.isEmpty, isTrue);
      expect(r.missingFields,
          containsAll(['amount', 'date', 'merchant', 'reference']));
      expect(r.amount, isNull);
      expect(r.date, isNull);
      expect(r.merchant, isNull);
      expect(r.reference, isNull);
      expect(r.sender, isNull);
      expect(r.recipient, isNull);
      expect(r.transactionType, isNull);
    });

    test('parseText never throws on hostile input', () {
      for (final bad in [
        '',
        '   ',
        '\n\n\n',
        'Rs.',
        ':::',
        '99999999999999999999999999',
        '((((()))))',
      ]) {
        expect(() => ocr.parseText(bad), returnsNormally);
      }
    });
  });

  group('v1.2 — copyWith', () {
    test('preserves every new field', () {
      final r = ocr.parseText(meezanReceipt);
      final c = r.copyWith();
      expect(c.amount, r.amount);
      expect(c.date, r.date);
      expect(c.merchant, r.merchant);
      expect(c.reference, r.reference);
      expect(c.rawText, r.rawText);
      expect(c.recipient, r.recipient);
      expect(c.sender, r.sender);
      expect(c.recipientAccount, r.recipientAccount);
      expect(c.senderAccount, r.senderAccount);
      expect(c.transactionType, r.transactionType);
      expect(c.transactionTypeRaw, r.transactionTypeRaw);
      expect(c.bank, r.bank);
      expect(c.confidence, r.confidence);
      expect(c.isEmpty, r.isEmpty);
      expect(c.missingFields, r.missingFields);
    });

    test('overrides still work', () {
      final r = ocr.parseText(meezanReceipt);
      final c = r.copyWith(amount: 1.0, sender: 'Someone');
      expect(c.amount, 1.0);
      expect(c.sender, 'Someone');
      expect(c.recipient, r.recipient);
      expect(c.reference, r.reference);
    });
  });

  group('v1.5 — IBFT transfer receipts: names + note separation', () {
    // The user's live 1LINK IBFT scan (build-24): the recipient name
    // printed on the receipt came up EMPTY in the form, and the note
    // arrived pre-polluted with "Ref 534946 · 1LINK IBFT". These
    // fixtures pin the separation: reference → reference field,
    // printed name → recipient/merchant, rail label → nowhere in the
    // note, description (genuine, labeled) → description field only.
    test('reference and rail label never become a description', () {
      final r = ocr.parseText(meezanReceipt);
      expect(r.reference, '534946');
      expect(r.transactionTypeRaw, '1LINK IBFT');
      // No Description/Narration line on this receipt → the note
      // prefill source stays empty.
      expect(r.description, isNull);
    });

    test('a genuine labeled description is extracted', () {
      const text = '''
Transaction Successful
PKR 25,000
To Account:
Fatima Khan
0324xxx6500
Description: Monthly rent for October
Reference Number (STAN): 777001
Transaction Type: 1LINK IBFT
''';
      final r = ocr.parseText(text);
      expect(r.description, 'Monthly rent for October');
      expect(r.recipient, 'Fatima Khan');
      expect(r.reference, '777001');
    });

    test('a rail label in the description field is rejected as junk', () {
      const text = '''
PKR 1,000
Description: 1LINK IBFT Transfer
To: Corner Store
''';
      final r = ocr.parseText(text);
      expect(r.description, isNull);
    });

    test('stacked labels pair positionally (From name, then To name)',
        () {
      // ML Kit block order variant: both labels first, then both
      // names, then both accounts.
      const text = '''
Transaction Successful
PKR 8,000
Sep 28, 2026 | 5:07 PM
From Account:
To Account:
Ali Raza
Fatima Khan
4501xxx2047
0324xxx6500
Reference Number (STAN): 534946
Transaction Type: 1LINK IBFT
''';
      final r = ocr.parseText(text);
      expect(r.sender, 'Ali Raza');
      expect(r.recipient, 'Fatima Khan');
      expect(r.merchant, 'Fatima Khan');
      expect(r.reference, '534946');
    });

    test('account-first layout: name on the line after the account', () {
      const text = '''
Transaction Successful
PKR 3,500
To Account: 0324xxx6500
Fatima Khan
From Account: 4501xxx2047
Ali Raza
''';
      final r = ocr.parseText(text);
      expect(r.recipient, 'Fatima Khan');
      expect(r.recipientAccount, '0324xxx6500');
      expect(r.sender, 'Ali Raza');
      expect(r.senderAccount, '4501xxx2047');
    });

    test('Beneficiary Name: on one line extracts the bare name', () {
      const text = '''
Transfer Successful
Amount: PKR 2,000
Beneficiary Name: Fatima Khan
Bank: Meezan
''';
      final r = ocr.parseText(text);
      expect(r.recipient, 'Fatima Khan');
      expect(r.merchant, 'Fatima Khan');
    });

    test('Receiver Name with a bank-logo junk line still finds the name',
        () {
      const text = '''
Transfer Successful
PKR 1,500
Receiver Name:
JazzCash
Fatima Khan
''';
      final r = ocr.parseText(text);
      expect(r.recipient, 'Fatima Khan');
    });

    test('sender with no printed name does not steal the recipient name',
        () {
      const text = '''
Transaction Successful
PKR 8,000
From Account:
4501xxx2047
To Account:
Fatima Khan
0324xxx6500
''';
      final r = ocr.parseText(text);
      expect(r.sender, isNull);
      expect(r.senderAccount, '4501xxx2047');
      expect(r.recipient, 'Fatima Khan');
      expect(r.recipientAccount, '0324xxx6500');
    });

    test('received-from receipt: sender lands in the merchant field', () {
      const text =
          'You have received Rs 3,200.00 in your Easypaisa account from Ali Raza. TRX 44556677.';
      final r = ocr.parseText(text);
      expect(r.sender, 'Ali Raza');
      expect(r.merchant, 'Ali Raza');
    });
  });
}
