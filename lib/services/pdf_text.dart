import 'dart:convert';
import 'dart:io';

/// Minimal on-device PDF text extraction — no new dependencies (§7).
///
/// Handles the common case: content streams with FlateDecode and the
/// Tj / TJ / ' / " text-showing operators. Returns '' when the PDF has
/// no extractable text (scanned images, Identity-H subset fonts without
/// an extractable mapping) — the caller then shows the guidance dialog
/// with the Meezan CSV steps instead of failing silently.
Future<String> extractPdfText(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 5 ||
        String.fromCharCodes(bytes.take(5)) != '%PDF-') {
      return '';
    }
    return _extract(bytes);
  } catch (_) {
    return '';
  }
}

String _extract(List<int> bytes) {
  // Structure parsing on latin1: byte positions stay aligned.
  final raw = latin1.decode(bytes, allowInvalid: true);
  final out = StringBuffer();

  final objRe =
      RegExp(r'(\d+)\s+\d+\s+obj(.*?)endobj', dotAll: true);
  final streamRe = RegExp(r'stream\r?\n([\s\S]*?)\r?\nendstream');

  for (final obj in objRe.allMatches(raw)) {
    final objBody = obj.group(2)!;
    // Image (logo) streams carry binary, not text — skip them outright:
    // their bytes break the text readers below.
    if (RegExp(r'/Subtype\s*/Image').hasMatch(objBody)) continue;
    final streamMatch = streamRe.firstMatch(objBody);
    if (streamMatch == null) continue;
    if (!objBody.contains('FlateDecode') &&
        !objBody.contains('Fl') /* short name */) {
      // Uncompressed content stream — still try to read text from it.
      try {
        _readContentText(streamMatch.group(1)!, out);
      } catch (_) {
        continue; // garbled stream — skip, keep the rest
      }
      continue;
    }
    // Locate the raw stream bytes: latin1 keeps 1 char = 1 byte.
    // NOTE: obj.start points at the `N` in `N 0 obj`; objBody starts
    // AFTER the header, so anchor on the body start, not obj.start.
    final match0 = streamMatch.group(0)!;
    final streamStart = (obj.start + obj.group(0)!.indexOf(objBody)) +
        objBody.indexOf(match0) +
        match0.indexOf(streamMatch.group(1)!);
    // Find the end: 'endstream' in the raw string.
    final endIdx = raw.indexOf('endstream', streamStart);
    if (endIdx < 0) continue;
    var data = bytes.sublist(streamStart, endIdx);
    // Trim trailing CR/LF the regex consumed.
    while (data.isNotEmpty &&
        (data.last == 0x0A || data.last == 0x0D)) {
      data = data.sublist(0, data.length - 1);
    }
    try {
      final decoded = ZLibDecoder().convert(data);
      _readContentText(latin1.decode(decoded, allowInvalid: true), out);
    } catch (_) {
      continue; // not actually flate, or unreadable — skip, keep rest
    }
  }
  return out.toString();
}

/// Windows-1252 special range mapped onto latin1-decoded bytes.
String _winAnsi(String s) {
  const map = <int, String>{
    0x80: '€', 0x82: '‚', 0x83: 'ƒ', 0x84: '„', 0x85: '…',
    0x86: '†', 0x87: '‡', 0x88: 'ˆ', 0x89: '‰', 0x8A: 'Š',
    0x8B: '‹', 0x8C: 'Œ', 0x8E: 'Ž', 0x91: '‘', 0x92: '’',
    0x93: '“', 0x94: '”', 0x95: '•', 0x96: '–', 0x97: '—',
    0x98: '˜', 0x99: '™', 0x9A: 'š', 0x9B: '›', 0x9C: 'œ',
    0x9E: 'ž', 0x9F: 'Ÿ',
  };
  final buf = StringBuffer();
  for (final c in s.codeUnits) {
    buf.write(map[c] ?? String.fromCharCode(c));
  }
  return buf.toString();
}

/// Reads text-showing operators from one content stream.
void _readContentText(String content, StringBuffer out) {
  int i = 0;
  final n = content.length;
  String current = '';

  void flush({bool newline = false}) {
    if (current.isNotEmpty) {
      out.write(_winAnsi(current));
      current = '';
    }
    if (newline) out.write('\n');
  }

  String readString() {
    // content[i] == '(' — handles nesting + escapes.
    final buf = StringBuffer();
    int depth = 0;
    i++; // skip '('
    while (i < n) {
      final c = content[i];
      if (c == '\\' && i + 1 < n) {
        final e = content[i + 1];
        switch (e) {
          case 'n':
            buf.write('\n');
            break;
          case 'r':
            buf.write('\r');
            break;
          case 't':
            buf.write('\t');
            break;
          case '(':
            buf.write('(');
            break;
          case ')':
            buf.write(')');
            break;
          case '\\':
            buf.write('\\');
            break;
          default:
            // octal escapes \ddd
            if (RegExp(r'[0-7]').hasMatch(e)) {
              var oct = '';
              var j = i + 1;
              while (j < n &&
                  j < i + 4 &&
                  RegExp(r'[0-7]').hasMatch(content[j])) {
                oct += content[j];
                j++;
              }
              buf.writeCharCode(int.parse(oct, radix: 8));
              i = j - 1;
            } else {
              buf.write(e);
            }
        }
        i += 2;
        continue;
      }
      if (c == '(') {
        depth++;
        buf.write(c);
        i++;
        continue;
      }
      if (c == ')') {
        if (depth == 0) {
          i++;
          break;
        }
        depth--;
        buf.write(c);
        i++;
        continue;
      }
      buf.write(c);
      i++;
    }
    return buf.toString();
  }

  String readHex() {
    // content[i] == '<'
    final buf = StringBuffer();
    i++; // skip '<'
    var hex = '';
    while (i < n && content[i] != '>') {
      final c = content[i];
      // Binary garbage (e.g. from a non-skipped image stream) can land
      // here — keep only real hex digits instead of throwing.
      if (RegExp(r'[0-9a-fA-F]').hasMatch(c)) hex += c;
      i++;
    }
    if (i < n) i++; // skip '>'
    if (hex.length.isOdd) hex += '0';
    for (var k = 0; k < hex.length; k += 2) {
      final v = int.tryParse(hex.substring(k, k + 2), radix: 16);
      if (v != null) buf.writeCharCode(v);
    }
    return buf.toString();
  }

  while (i < n) {
    final c = content[i];
    if (c == '(') {
      final s = readString();
      // Look ahead: is this followed by a text-showing operator?
      var j = i;
      while (j < n && RegExp(r'\s').hasMatch(content[j])) {
        j++;
      }
      if (content.startsWith('Tj', j) ||
          content.startsWith("'", j) ||
          content.startsWith('"', j)) {
        current += s;
        i = j + (content.startsWith('Tj', j) ? 2 : 1);
        if (content.startsWith("'", j) || content.startsWith('"', j)) {
          flush(newline: true);
        }
      }
      continue;
    }
    if (c == '<' && i + 1 < n && content[i + 1] != '<') {
      final s = readHex();
      var j = i;
      while (j < n && RegExp(r'\s').hasMatch(content[j])) {
        j++;
      }
      if (content.startsWith('Tj', j)) {
        current += s;
        i = j + 2;
      }
      continue;
    }
    if (c == '[') {
      // TJ array: [ (str) -123 (str2) ] TJ
      final parts = <String>[];
      i++;
      var k = i;
      while (k < n && content[k] != ']') {
        if (content[k] == '(') {
          i = k;
          parts.add(readString());
          k = i;
        } else if (content[k] == '<' &&
            k + 1 < n &&
            content[k + 1] != '<') {
          i = k;
          parts.add(readHex());
          k = i;
        } else {
          // number (kerning) — large negative gaps often mean spaces
          final numMatch =
              RegExp(r'-?\d+\.?\d*').matchAsPrefix(content, k);
          if (numMatch != null) {
            final v = double.tryParse(numMatch.group(0)!) ?? 0;
            if (v < -120) parts.add(' ');
            k = numMatch.end;
          } else {
            k++;
          }
        }
      }
      i = k + 1; // skip ']'
      var j = i;
      while (j < n && RegExp(r'\s').hasMatch(content[j])) {
        j++;
      }
      if (content.startsWith('TJ', j)) {
        current += parts.join('');
        i = j + 2;
      }
      continue;
    }
    // Line positioning operators end the current text line.
    if ((c == 'T' && i + 1 < n && content[i + 1] == '*') ||
        (c == 'T' &&
            i + 2 < n &&
            (content.substring(i, i + 2) == 'Td' ||
                content.substring(i, i + 2) == 'TD'))) {
      flush(newline: true);
      i += 2;
      continue;
    }
    i++;
  }
  flush(newline: true);
}
