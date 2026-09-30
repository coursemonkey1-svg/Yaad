import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../main.dart';
import '../models/transaction.dart';
import '../services/capture_flow.dart';
import '../services/ocr.dart';
import '../theme.dart';
import 'borrow.dart';
import 'confirm.dart';
import 'lend.dart';

/// The 5-second capture: amount first, then intent (§4).
/// "I spent / I received / I lent / I borrowed" — four plain choices,
/// no toggles, no −/+.
class QuickCaptureSheet extends StatefulWidget {
  const QuickCaptureSheet({super.key});

  @override
  State<QuickCaptureSheet> createState() => _QuickCaptureSheetState();
}

class _QuickCaptureSheetState extends State<QuickCaptureSheet> {
  final _amountCtrl = TextEditingController();

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  double get _amount =>
      double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;

  void _goSpent() => _openConfirm(TxnKind.spend);
  void _goReceived() => _openConfirm(TxnKind.receive);

  void _openConfirm(TxnKind kind) {
    final amount = _amount;
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConfirmScreen(
        initialKind: kind,
        initial: amount > 0
            ? _AmountOnly(amount)
            : null,
      ),
    ));
  }

  void _goLent() {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LendScreen(initialAmount: _amountOrNull())));
  }

  void _goBorrowed() {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BorrowScreen(initialAmount: _amountOrNull())));
  }

  double? _amountOrNull() => _amount > 0 ? _amount : null;

  Future<void> _scanReceipt() async {
    Navigator.of(context).pop();
    final res = await FilePicker.platform
        .pickFiles(type: FileType.image, allowMultiple: false);
    if (res == null || res.files.single.path == null) return;
    if (!mounted) return;
    await captureImage(context, res.files.single.path!);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            Gap.x3, Gap.x1 + 4, Gap.x3, Gap.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: Gap.x2),
            // 1. Amount first — big, numeric, autofocused.
            TextField(
              controller: _amountCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              style: const TextStyle(
                  fontSize: 40, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                labelText: s.get('amount'),
                prefixText: '${appState.settings.currency} ',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Gap.x2),
            // 2. Four plain intents.
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 2,
              mainAxisSpacing: Gap.x1 + 4,
              crossAxisSpacing: Gap.x1 + 4,
              childAspectRatio: 2.2,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _IntentCard(
                  icon: Icons.north_east,
                  label: s.get('iSpent'),
                  color: cs.error,
                  onTap: _goSpent,
                ),
                _IntentCard(
                  icon: Icons.south_west,
                  label: s.get('iReceived'),
                  color: Colors.green,
                  onTap: _goReceived,
                ),
                _IntentCard(
                  icon: Icons.handshake_outlined,
                  label: s.get('iLent'),
                  color: cs.primary,
                  onTap: _goLent,
                ),
                _IntentCard(
                  icon: Icons.handshake_outlined,
                  label: s.get('iBorrowed'),
                  color: cs.secondary,
                  onTap: _goBorrowed,
                ),
              ],
            ),
            const SizedBox(height: Gap.x2),
            // 3. Scan receipt as the alternate path.
            OutlinedButton.icon(
              onPressed: _scanReceipt,
              icon: const Icon(Icons.document_scanner_outlined),
              label: Text(s.get('scanReceipt')),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
            ),
          ],
        ),
      ),
    );
  }
}

class _IntentCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _IntentCard(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radius.tile),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(Radius.tile),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: Gap.x1),
            Flexible(
              child: Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Carries a manually typed amount into the confirm screen.
class _AmountOnly extends OcrResult {
  _AmountOnly(double amount) : super(rawText: '', amount: amount);
}
