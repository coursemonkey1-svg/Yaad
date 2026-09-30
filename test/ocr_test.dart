import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/services/ocr.dart';

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
    test('returns null when no date', () {
      expect(ocr.findDate('no date here'), isNull);
    });
  });
}
