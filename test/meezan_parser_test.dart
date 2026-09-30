import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/models/transaction.dart';
import 'package:yaad/services/meezan_parser.dart';

// Synthetic sample mirroring the real Meezan FOP layout: one long glued
// line per page, `Booking Date…` header marker, rows glued
// date-to-balance, `<pageno><timestamp>` footer at each page end.
// All names/numbers are invented — never the real statement.
const _page1 = 'Account Statement'
    'Account TitleTEST USER'
    'Account Number12340123456789'
    'IBANPK00MEZN00000000000000'
    'CurrencyPakistan Rupee(PKR)'
    'From Date01 Mar 2026'
    'To Date31 Mar 2026'
    'Opening BalancePKR50,000.00'
    'Closing BalancePKR52,624.25'
    'AddressScan Code'
    'Booking DateDescriptionCreditDebitAvailable Balance'
    '01 Mar 2026'
    'Raast P2P Fund transfer to ALI RAZA'
    'PK00MEZNxxxx1234'
    'AMEZNPKKA12345678901234567890123'
    '- PKR5,000.00'
    'PKR45,000.00'
    '02 Mar 2026'
    'OnlinePurchaseDARAZ STAN882311'
    '- PKR2,350.75'
    'PKR42,649.25'
    '02 Mar 2026'
    '1-Link Fee STAN882311'
    '- PKR25.00'
    'PKR42,624.25'
    '130 Mar 2026, 09:41';

const _page2 = 'Account Statement'
    'Booking DateDescriptionCreditDebitAvailable Balance'
    '03 Mar 2026'
    'Cash Deposit Branch 0421>Counter'
    '+ PKR10,000.00'
    'PKR52,624.25'
    '230 Mar 2026, 09:41';

const _sample = '$_page1\n$_page2\n';

void main() {
  group('MeezanParser.looksLike', () {
    test('recognizes the Meezan FOP layout', () {
      expect(MeezanParser.looksLike(_sample), isTrue);
    });

    test('rejects unrelated text', () {
      expect(MeezanParser.looksLike('just some random text'), isFalse);
    });
  });

  group('MeezanParser.parse', () {
    late MeezanStatement st;
    setUpAll(() => st = MeezanParser.parse(_sample));

    test('parses every row across both pages', () {
      expect(st.rows, hasLength(4));
    });

    test('produces no warnings on clean input', () {
      expect(st.warnings, isEmpty);
    });

    test('row 1: spend with Raast RRN reference', () {
      final r = st.rows[0];
      expect(r.date, DateTime(2026, 3, 1));
      expect(r.amount, 5000.00);
      expect(r.kind, TxnKind.spend);
      expect(r.balance, 45000.00);
      expect(r.reference, 'AMEZNPKKA12345678901234567890123');
      expect(r.suggestedPurpose, 'uncategorized');
      expect(r.description, contains('Raast P2P Fund transfer to ALI RAZA'));
    });

    test('row 2: wrapped description cleaned, qualified STAN', () {
      final r = st.rows[1];
      expect(r.date, DateTime(2026, 3, 2));
      expect(r.amount, 2350.75);
      expect(r.kind, TxnKind.spend);
      // lowercase→Uppercase boundaries get spaces.
      expect(r.description, 'Online Purchase DARAZ STAN882311');
      // STAN repeats on the next row, so it is qualified with the amount.
      expect(r.reference, 'STAN882311:2350.75');
      expect(r.suggestedPurpose, 'shopping');
    });

    test('row 3: fee sharing the STAN gets its own qualified reference', () {
      final r = st.rows[2];
      expect(r.amount, 25.00);
      expect(r.kind, TxnKind.spend);
      expect(r.reference, 'STAN882311:25.00');
      expect(r.reference, isNot(st.rows[1].reference));
      expect(r.suggestedPurpose, 'uncategorized');
    });

    test('row 4: receive, footer-glued, arrow byte cleaned', () {
      final r = st.rows[3];
      expect(r.date, DateTime(2026, 3, 3));
      expect(r.amount, 10000.00);
      expect(r.kind, TxnKind.receive);
      expect(r.balance, 52624.25);
      expect(r.description, 'Cash Deposit Branch 0421 → Counter');
      expect(r.reference, isNull);
      expect(r.suggestedPurpose, isNull);
    });

    test('balance chain validates across the page break', () {
      // Opening 50,000 → 45,000 → 42,649.25 → 42,624.25 → 52,624.25.
      // Any break would have produced a warning; also check directly.
      expect(st.rows[3].balance, st.header.closingBalance);
    });

    test('header metadata parsed from page 1', () {
      final h = st.header;
      expect(h.accountTitle, 'TEST USER');
      expect(h.accountNumber, '12340123456789');
      expect(h.from, DateTime(2026, 3, 1));
      expect(h.to, DateTime(2026, 3, 31));
      expect(h.openingBalance, 50000.00);
      expect(h.closingBalance, 52624.25);
    });

    test('pages without the header marker are skipped with a warning', () {
      final st2 = MeezanParser.parse('no header here\n$_page1\n');
      expect(st2.rows, hasLength(3));
      expect(st2.warnings, isNotEmpty);
    });
  });
}
