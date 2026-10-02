import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaad/main.dart';
import 'package:yaad/models/settings.dart';
import 'package:yaad/screens/capture.dart';

/// Fake file_picker platform: returns one fake image path.
class _FakeFilePicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    return FilePickerResult([
      PlatformFile(
          name: 'fake_receipt.jpg', size: 0, path: '/tmp/fake_receipt.jpg'),
    ]);
  }
}

/// Regression test for the receipt-scan silent-death bug: _scanReceipt used
/// to pop its own sheet and then check `mounted` after the async file
/// picker. The popped sheet is always unmounted by then, so EVERY image
/// pick was swallowed and the user landed back in the app with nothing
/// happening. The fix keeps the Navigator (whose context outlives the
/// sheet) and never consults the dead sheet's `mounted`.
///
/// The test mocks file_picker to return a fake image path. ML Kit has no
/// platform side in tests, so captureImage takes its failure path and must
/// show the "couldn't read it" dialog — proving the flow proceeded instead
/// of dying silently.
void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('scan receipt: picking an image proceeds (no silent death)',
      (tester) async {
    // Fake the file picker: returns one image path (no platform channels).
    FilePicker.platform = _FakeFilePicker();

    appState.settings = const AppSettings();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Builder(
              builder: (sheetContext) => ElevatedButton(
                onPressed: () => showModalBottomSheet(
                  context: sheetContext,
                  builder: (_) => const QuickCaptureSheet(),
                ),
                child: const Text('open sheet'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    expect(find.byType(QuickCaptureSheet), findsOneWidget);

    final scanButton = find.text('Scan receipt');
    await tester.ensureVisible(scanButton);
    await tester.tap(scanButton);
    // Manual pumps, not pumpAndSettle: the OCR progress dialog spins a
    // CircularProgressIndicator forever, so "settle" would time out.
    await tester.pump(); // sheet pops
    await tester.pump(const Duration(milliseconds: 200)); // picker returns
    await tester.pump(const Duration(milliseconds: 200)); // OCR fails in tests
    await tester.pump(const Duration(milliseconds: 200)); // dialog shows

    // The sheet is gone (it pops itself before picking)…
    expect(find.byType(QuickCaptureSheet), findsNothing);
    // …but the flow must have proceeded: ML Kit throws in tests, so the
    // failure dialog ("couldn't read it" + manual entry) must be showing.
    // Before the fix, nothing appeared at all.
    expect(find.byType(AlertDialog), findsWidgets);
  });
}
