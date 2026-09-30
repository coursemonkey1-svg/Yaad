import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../services/backup.dart';
import '../services/importer.dart';
import 'aliases.dart';

/// Settings: make Yaad yours. Defaults are Pakistan/PKR;
/// everything is adjustable. All data stays on this phone.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// Curated timezone list: Pakistan-first, then common expat / travel zones.
  static const _timezones = [
    'Asia/Karachi',
    'Asia/Dubai',
    'Asia/Riyadh',
    'Asia/Qatar',
    'Asia/Kolkata',
    'Asia/Dhaka',
    'Asia/Singapore',
    'Asia/Kuala_Lumpur',
    'Asia/Tokyo',
    'Australia/Sydney',
    'Europe/London',
    'Europe/Berlin',
    'America/New_York',
    'America/Toronto',
    'UTC',
  ];

  static String _weekdayLabel(int d) => const {
        1: 'Monday',
        2: 'Tuesday',
        3: 'Wednesday',
        4: 'Thursday',
        5: 'Friday',
        6: 'Saturday',
        7: 'Sunday',
      }[d]!;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final s = appState.settings;
        final t = Strings(s.language);
        return Scaffold(
          appBar: AppBar(title: Text(t.get('settings'))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _section('You & your money'),
              _tile(
                context,
                icon: Icons.attach_money,
                title: t.get('currency'),
                value: s.currency,
                onTap: () => _pick(context, 'Currency',
                    ['PKR', 'USD', 'EUR', 'GBP', 'AED', 'SAR', 'INR'],
                    s.currency,
                    (v) => appState.update(s.copyWith(currency: v))),
              ),
              _tile(
                context,
                icon: Icons.language,
                title: t.get('language'),
                value: s.language == 'ur' ? 'اردو' : 'English',
                onTap: () => _pick(context, 'Language', ['en', 'ur'],
                    s.language,
                    (v) => appState.update(s.copyWith(language: v)),
                    labels: const {'en': 'English', 'ur': 'اردو'}),
              ),
              _tile(
                context,
                icon: Icons.dark_mode_outlined,
                title: t.get('theme'),
                value: {'system': 'System', 'light': 'Light', 'dark': 'Dark'}[s.theme]!,
                onTap: () => _pick(context, 'Theme',
                    ['system', 'light', 'dark'], s.theme,
                    (v) => appState.update(s.copyWith(theme: v)),
                    labels: const {
                      'system': 'System',
                      'light': 'Light',
                      'dark': 'Dark'
                    }),
              ),
              _tile(
                context,
                icon: Icons.calendar_month_outlined,
                title: t.get('dateFormat'),
                value: {'dmy': '31/12/2026', 'mdy': '12/31/2026', 'ymd': '2026-12-31'}[s.dateFormat]!,
                onTap: () => _pick(context, 'Date format',
                    ['dmy', 'mdy', 'ymd'], s.dateFormat,
                    (v) => appState.update(s.copyWith(dateFormat: v)),
                    labels: const {
                      'dmy': '31/12/2026',
                      'mdy': '12/31/2026',
                      'ymd': '2026-12-31'
                    }),
              ),
              _tile(
                context,
                icon: Icons.public_outlined,
                title: t.get('timezone'),
                value: s.timezone,
                onTap: () => _pick(context, 'Timezone', _timezones,
                    s.timezone,
                    (v) => appState.update(s.copyWith(timezone: v))),
              ),
              _tile(
                context,
                icon: Icons.calendar_view_week_outlined,
                title: t.get('firstDayOfWeek'),
                value: _weekdayLabel(s.firstDayOfWeek),
                onTap: () => _pick(
                    context,
                    'Week starts on',
                    ['1', '2', '3', '4', '5', '6', '7'],
                    '${s.firstDayOfWeek}',
                    (v) => appState.update(s.copyWith(
                        firstDayOfWeek: int.parse(v))),
                    labels: {
                      for (var i = 1; i <= 7; i++) '$i': _weekdayLabel(i)
                    }),
              ),
              _tile(
                context,
                icon: Icons.account_balance_outlined,
                title: t.get('defaultBank'),
                value: s.defaultBank == 'meezan' ? 'Meezan Bank' : 'Other',
                onTap: () => _pick(context, 'My main bank',
                    ['meezan', 'other'], s.defaultBank,
                    (v) => appState.update(s.copyWith(defaultBank: v)),
                    labels: const {
                      'meezan': 'Meezan Bank',
                      'other': 'Other / multiple'
                    }),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.lock_outline),
                title: Text(t.get('appLock')),
                value: s.appLock,
                onChanged: (v) =>
                    appState.update(s.copyWith(appLock: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.auto_awesome_outlined),
                title: Text(t.get('smartSuggestions')),
                subtitle: Text(t.get('smartSuggestionsSub')),
                value: s.smartSuggestions,
                onChanged: (v) => appState.update(
                    s.copyWith(smartSuggestions: v)),
              ),
              _section('Names & imports'),
              ListTile(
                leading: const Icon(Icons.label_outline),
                title: const Text('My names for shops'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AliasesScreen())),
              ),
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: Text(t.get('importStatement')),
                subtitle:
                    const Text('CSV, Excel or text — duplicates skipped'),
                onTap: () => _importStatement(context),
              ),
              _section('Your data'),
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: Text(t.get('backup')),
                subtitle:
                    const Text('Full backup file — yours to keep'),
                onTap: () => _backup(context),
              ),
              ListTile(
                leading: const Icon(Icons.table_chart_outlined),
                title: Text(t.get('exportCsv')),
                subtitle: const Text('Open in Excel or Google Sheets'),
                onTap: () => _exportCsv(context),
              ),
              ListTile(
                leading: const Icon(Icons.restore_outlined),
                title: Text(t.get('restore')),
                onTap: () => _restore(context),
              ),
              ListTile(
                leading: Icon(Icons.delete_forever_outlined,
                    color: Theme.of(context).colorScheme.error),
                title: Text(t.get('deleteAll'),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
                subtitle:
                    const Text('Erases everything on this phone'),
                onTap: () => _wipe(context),
              ),
              _section('About'),
              const ListTile(
                leading: Icon(Icons.privacy_tip_outlined),
                title: Text('Privacy'),
                subtitle: Text(
                    'Yaad stores everything on this phone. No account, no servers, no ads, no tracking. Free forever.'),
              ),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Yaad 1.0.0'),
                subtitle: Text(
                    'Never forget what your money was for.'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
        child: Text(title,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14)),
      );

  Widget _tile(BuildContext context,
      {required IconData icon,
      required String title,
      required String value,
      required VoidCallback onTap}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: Theme.of(context).textTheme.bodyMedium),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }

  Future<void> _pick(
      BuildContext context,
      String title,
      List<String> options,
      String current,
      Future<void> Function(String) onPick,
      {Map<String, String>? labels}) async {
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text(title),
        children: options
            .map((o) => SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(o),
                  child: Row(
                    children: [
                      if (o == current)
                        const Icon(Icons.check, size: 18),
                      if (o == current) const SizedBox(width: 8),
                      Text(labels?[o] ?? o),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
    if (v != null) await onPick(v);
  }

  Future<void> _importStatement(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'xls', 'txt', 'tsv'],
      allowMultiple: false,
    );
    if (res == null || res.files.single.path == null) return;
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          const Center(child: CircularProgressIndicator()),
    );
    final report = await StatementImporter()
        .importFile(res.files.single.path!);
    appState.refresh();
    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Imported ${report.imported}, skipped ${report.duplicates} duplicates${report.failed > 0 ? ', ${report.failed} failed' : ''}.')));
      if (report.errors.isNotEmpty && context.mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Import notes'),
            content: Text(report.errors.join('\n')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('OK'))
            ],
          ),
        );
      }
    }
  }

  Future<void> _backup(BuildContext context) async {
    final path = await BackupService().exportJson();
    if (context.mounted) {
      await BackupService().shareFile(path, subject: 'Yaad backup');
    }
  }

  Future<void> _exportCsv(BuildContext context) async {
    final path = await BackupService().exportCsv();
    if (context.mounted) {
      await BackupService()
          .shareFile(path, subject: 'Yaad transactions CSV');
    }
  }

  Future<void> _restore(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: false,
    );
    if (res == null || res.files.single.path == null) return;
    try {
      final summary =
          await BackupService().importJson(res.files.single.path!);
      appState.refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Restored ${summary.added} records (${summary.skipped} already present).')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      }
    }
  }

  Future<void> _wipe(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete everything?'),
        content: const Text(
            'This permanently erases all transactions, people, balances and names on this phone. Export a backup first if you want to keep anything.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete everything')),
        ],
      ),
    );
    if (ok == true) {
      await YaadDb.wipeAll();
      appState.refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('All data deleted.')));
      }
    }
  }
}
