import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/services/pdf_text.dart';

/// Regression tests for the pdf_text fixes behind the Meezan import:
/// the stream-offset miscalculation (which made zlib throw and dropped
/// EVERY stream, yielding ''), image streams breaking the text reader,
/// and readHex throwing on non-hex bytes.
void main() {
  test('extracts text from a minimal zlib PDF, skips image streams',
      () async {
    final textObj = ZLibEncoder().convert(utf8.encode('(Hello) Tj\n'));
    // If this ever leaked into the output, the image skip is broken.
    final imgObj =
        ZLibEncoder().convert(utf8.encode('(IMAGEPOLLUTION) Tj\n'));

    final buf = BytesBuilder();
    void w(String s) => buf.add(utf8.encode(s));
    w('%PDF-1.4\n');
    w('1 0 obj\n<< /Type /Catalog >>\nendobj\n');
    w('2 0 obj\n<< /Length ${textObj.length} /Filter /FlateDecode >>\n'
        'stream\n');
    buf.add(textObj);
    w('\nendstream\nendobj\n');
    w('3 0 obj\n<< /Type /XObject /Subtype /Image /Width 1 /Height 1 '
        '/Length ${imgObj.length} /Filter /FlateDecode >>\nstream\n');
    buf.add(imgObj);
    w('\nendstream\nendobj\n');
    // Uncompressed stream with non-hex bytes inside < >: readHex must not
    // throw (old code: int.parse threw, whole extraction returned '').
    w('4 0 obj\n<< /Length 20 >>\nstream\n<zz> Tj\nendstream\nendobj\n');

    final file =
        File('${Directory.systemTemp.path}/yaad_pdf_text_test.pdf');
    await file.writeAsBytes(buf.toBytes());
    try {
      final text = await extractPdfText(file.path);
      expect(text, contains('Hello'));
      expect(text, isNot(contains('IMAGEPOLLUTION')));
    } finally {
      await file.delete();
    }
  });

  test('returns empty for non-PDF input', () async {
    final file =
        File('${Directory.systemTemp.path}/yaad_pdf_text_notpdf.txt');
    await file.writeAsString('not a pdf');
    try {
      expect(await extractPdfText(file.path), isEmpty);
    } finally {
      await file.delete();
    }
  });
}
