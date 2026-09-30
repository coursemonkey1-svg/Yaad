import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/transaction.dart';
import '../services/ocr.dart';
import 'confirm.dart';
import 'lend.dart';

/// The 5-second capture sheet: the five entry points, each one tap.
class QuickCaptureSheet extends StatelessWidget {
  const QuickCaptureSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Theme.of(context).dividerColor,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),
            _Action(
              icon: Icons.share_outlined,
              label: s.get('shareReceipt'),
              sub: 'From your bank app, or a screenshot',
              onTap: () async {
                Navigator.of(context).pop();
                final res = await FilePicker.platform.pickFiles(
                    type: FileType.image, allowMultiple: false);
                if (res == null || res.files.single.path == null) return;
                final path = res.files.single.path!;
                final ocr = OcrService();
                final result =
                    (await ocr.fromImage(path)).copyWith(imagePath: path);
                ocr.dispose();
                if (!context.mounted) return;
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ConfirmScreen(initial: result)));
              },
            ),
            _Action(
              icon: Icons.edit_note_outlined,
              label: s.get('noteOnLatest'),
              sub: 'Add context to your most recent payment',
              onTap: () async {
                Navigator.of(context).pop();
                final latest =
                    await _latestNeedingNote(context);
                if (latest != null && context.mounted) {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          ConfirmScreen(editing: latest)));
                }
              },
            ),
            _Action(
              icon: Icons.keyboard_outlined,
              label: s.get('recordManually'),
              sub: 'Under 10 seconds',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ConfirmScreen()));
              },
            ),
            _Action(
              icon: Icons.handshake_outlined,
              label: s.get('iLentMoney'),
              sub: 'Track who owes you',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const LendScreen()));
              },
            ),
            _Action(
              icon: Icons.payments_outlined,
              label: s.get('someoneRepaidMe'),
              sub: 'Log a repayment against a balance',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const LendScreen(isRepayment: true)));
              },
            ),
          ],
        ),
      ),
    );
  }
}

Future<YaadTransaction?> _latestNeedingNote(BuildContext context) async {
  // Most recent transaction, whatever its status.
  final txns = await YaadDb.txns(limit: 1);
  if (txns.isEmpty && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No transactions yet.')));
    return null;
  }
  return txns.isEmpty ? null : txns.first;
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label, sub;
  final VoidCallback onTap;
  const _Action(
      {required this.icon,
      required this.label,
      required this.sub,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
          backgroundColor:
              Theme.of(context).colorScheme.primaryContainer,
          child: Icon(icon,
              color: Theme.of(context).colorScheme.onPrimaryContainer)),
      title: Text(label,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(sub),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
    );
  }
}
