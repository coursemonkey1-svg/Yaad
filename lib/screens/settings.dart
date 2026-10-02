import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/settings.dart';
import '../services/backup.dart';
import '../widgets/export_range_dialog.dart';
import '../services/importer.dart';
import '../services/pro.dart';
import '../services/sms_capture.dart';
import '../theme.dart';
import '../widgets/statement_import_wait.dart';
import 'accounts.dart';
import 'aliases.dart';
import 'import_preview.dart';
import 'pro.dart';

/// Settings: make Yaad yours. Defaults are Pakistan/PKR;
/// everything is adjustable. All data stays on this phone.
class SettingsScreen extends StatelessWidget {
  /// When provided (from the main shell), shows a "Take the tour" row
  /// that replays the first-run guided tour on demand.
  final VoidCallback? onTakeTour;

  const SettingsScreen({super.key, this.onTakeTour});

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

  static const _accents = ['teal', 'amber', 'violet', 'rose'];
  static String _accentLabel(String a) => const {
        'teal': 'Teal',
        'amber': 'Amber',
        'violet': 'Violet',
        'rose': 'Rose',
      }[a]!;

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
            padding: const EdgeInsets.all(Gap.x2),
            children: [
              _section(t.get('youAndMoney')),
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
                icon: Icons.palette_outlined,
                title: t.get('accentTheme'),
                value: _accentLabel(s.accentTheme),
                onTap: () => _pickAccent(context, s),
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
                subtitle: !_canUseAppLock(s)
                    ? Text(t.get('proFeature'))
                    : null,
                value: s.appLock && _canUseAppLock(s),
                onChanged: (v) {
                  if (v && !_canUseAppLock(s)) {
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const ProScreen()));
                    return;
                  }
                  appState.update(s.copyWith(appLock: v));
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.auto_awesome_outlined),
                title: Text(t.get('smartSuggestions')),
                subtitle: Text(t.get('smartSuggestionsSub')),
                value: s.smartSuggestions,
                onChanged: (v) => appState.update(
                    s.copyWith(smartSuggestions: v)),
              ),
              _section(t.get('autoCapture')),
              const _CaptureSection(),
              _section(t.get('namesAndImports')),
              ListTile(
                leading: const Icon(Icons.label_outline),
                title: Text(t.get('myNames')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AliasesScreen())),
              ),
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: Text(t.get('importStatement')),
                subtitle: Text(t.get('importStatementSub')),
                onTap: () => _importStatement(context),
              ),
              _section(t.get('yourData')),
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(t.get('myAccounts')),
                subtitle: Text(t.get('myAccountsSub')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AccountsScreen())),
              ),
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: Text(t.get('backup')),
                subtitle: Text(_proSuffix(t, t.get('backupSub'),
                    ProService.canUseBackup(s))),
                onTap: () => _gate(context,
                    ProService.canUseBackup(s), () => _backup(context)),
              ),
              ListTile(
                leading: const Icon(Icons.table_chart_outlined),
                title: Text(t.get('exportCsv')),
                subtitle: Text(_proSuffix(t, t.get('exportCsvSub'),
                    ProService.canUseExport(s))),
                onTap: () => _gate(context,
                    ProService.canUseExport(s), () => _exportCsv(context)),
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
                subtitle: Text(t.get('deleteAllSub')),
                onTap: () => _wipe(context),
              ),
              if (s.billingEnabled) ...[
                _section(t.get('yaadPro')),
                ListTile(
                  leading: const Icon(Icons.star_outline),
                  title: Text(t.get('yaadPro')),
                  subtitle: Text(s.proUnlocked
                      ? t.get('proActive')
                      : t.get('proGet')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const ProScreen())),
                ),
              ],
              _section(t.get('about')),
              if (onTakeTour != null)
                ListTile(
                  leading: const Icon(Icons.tour_outlined),
                  title: Text(t.get('tourReplay')),
                  subtitle: Text(t.get('tourReplaySub')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: onTakeTour,
                ),
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: Text(t.get('privacy')),
                subtitle: Text(t.get('privacyBody')),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Yaad 1.1.0'),
                subtitle: Text(t.get('appTagline')),
              ),
            ],
          ),
        );
      },
    );
  }

  static bool _canUseAppLock(AppSettings s) =>
      ProService.canUseAppLock(s);

  static String _proSuffix(Strings t, String sub, bool allowed) =>
      allowed ? sub : '$sub · ${t.get('proFeature')}';

  static void _gate(
      BuildContext context, bool allowed, VoidCallback action) {
    if (allowed) {
      action();
      return;
    }
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ProScreen()));
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

  Future<void> _pickAccent(BuildContext context, AppSettings s) async {
    final t = Strings(s.language);
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text(t.get('accentTheme')),
        children: _accents
            .map((a) => SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(a),
                  child: Row(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: YaadTheme.seedFor(a),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(_accentLabel(a)),
                      if (a == s.accentTheme)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Icon(Icons.check, size: 18),
                        ),
                      if (!ProService.canUseAccent(s, a))
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(t.get('proFeature'),
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary,
                                  fontSize: 12)),
                        ),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
    if (v == null || !context.mounted) return;
    if (!ProService.canUseAccent(s, v)) {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProScreen()));
      return;
    }
    await appState.update(s.copyWith(accentTheme: v));
  }

  Future<void> _importStatement(BuildContext context) async {
    final s = Strings(appState.settings.language);
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'xls', 'txt', 'tsv', 'pdf'],
      allowMultiple: false,
    );
    if (res == null || res.files.single.path == null) return;
    final path = res.files.single.path!;
    if (!context.mounted) return;

    // Cancellable progress + bounded parse: the user is never trapped on
    // an infinite spinner, and failures always land on a plain-language
    // message. Nothing reaches the database before the preview-screen
    // confirmation below.
    final result = await runStatementImport(
      context,
      path: path,
      strings: s,
      parse: StatementImporter().parseFile,
    );
    if (!context.mounted) return;
    appState.refresh();

    if (result.outcome == StatementImportOutcome.cancelled) return;
    if (result.outcome != StatementImportOutcome.ready ||
        result.statement == null) {
      await showImportReadFailedDialog(context, s);
      return;
    }
    final parsed = result.statement!;

    // Scanned/image PDF: no extractable text — guide, don't fail silently.
    if (parsed.pdfNoText) {
      if (!context.mounted) return;
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(s.get('pdfNoTextTitle')),
          content: SingleChildScrollView(
            child: Text(s.get('pdfNoTextBody')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.get('gotIt')),
            ),
          ],
        ),
      );
      return;
    }

    if (!context.mounted) return;
    final report = await Navigator.of(context).push<ImportReport>(
      MaterialPageRoute(
          builder: (_) => ImportPreviewScreen(statement: parsed)),
    );
    if (report == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s
            .get('importDone')
            .replaceFirst('{imported}', '${report.imported}')
            .replaceFirst('{duplicates}', '${report.duplicates}')
            .replaceFirst('{failed}', '${report.failed}'))));
    if (report.errors.isNotEmpty && context.mounted) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(s.get('importNotes')),
          content: Text(report.errors.join('\n')),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(s.get('ok')))
          ],
        ),
      );
    }
  }

  Future<void> _backup(BuildContext context) async {
    final path = await BackupService().exportJson();
    if (context.mounted) {
      await BackupService().shareFile(path, subject: 'Yaad backup');
    }
  }

  Future<void> _exportCsv(BuildContext context) async {
    final s = Strings(appState.settings.language);
    final range = await showExportRangeDialog(context);
    if (range == null || !context.mounted) return;
    final res = await BackupService().exportCsv(
      from: range.from,
      to: range.to,
      fileLabel: range.fileLabel,
      language: appState.settings.language,
    );
    if (!context.mounted) return;
    if (res.count == 0) {
      // Instructive, not silent: the range had nothing to export.
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(s.get('exportEmptyTitle')),
          content: Text(s.get('exportEmptyBody')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.get('ok')),
            ),
          ],
        ),
      );
      return;
    }
    await BackupService()
        .shareFile(res.path, subject: 'Yaad transactions CSV');
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
            .showSnackBar(SnackBar(content: Text(Strings(appState.settings.language).get('restoreFailed').replaceFirst('{e}', '$e'))));
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
            SnackBar(content: Text(Strings(appState.settings.language).get('allDataDeleted'))));
      }
    }
  }
}

/// The two opt-in capture toggles (§6). Both default OFF; enabling shows
/// a rationale first, then the system permission / settings step.
/// Everything stays on this phone — the native side only queues when
/// the in-app flag is on.
class _CaptureSection extends StatefulWidget {
  const _CaptureSection();

  @override
  State<_CaptureSection> createState() => _CaptureSectionState();
}

class _CaptureSectionState extends State<_CaptureSection>
    with WidgetsBindingObserver {
  bool _awaitingNotifReturn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingNotifReturn) {
      _awaitingNotifReturn = false;
      _finishNotifOptIn();
    }
  }

  /// First-run guide for the restricted-settings wall on sideloaded
  /// builds: the phone blocks SMS / notification capture until the user
  /// allows restricted settings once on the app's system page. Shown once
  /// per capture type, before the normal rationale / permission flow.
  /// Returns true to continue turning the toggle on.
  Future<bool> _showPermGuide({required bool forSms}) async {
    final cur = appState.settings;
    if (forSms ? cur.smsGuideSeen : cur.notifGuideSeen) return true;
    final s = Strings(cur.language);
    final open = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.get('permGuideTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.get('permGuideBody')),
            const SizedBox(height: Gap.x1),
            Text('1. ${s.get('permGuideStep1')}'),
            const SizedBox(height: Gap.x1 / 2),
            Text('2. ${s.get('permGuideStep2')}'),
            const SizedBox(height: Gap.x1 / 2),
            Text('3. ${s.get('permGuideStep3')}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(s.get('notNow')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(s.get('permGuideOpen')),
          ),
        ],
      ),
    );
    // The guide shows once, however it was dismissed.
    await appState.update(cur.copyWith(
      smsGuideSeen: forSms || cur.smsGuideSeen,
      notifGuideSeen: !forSms || cur.notifGuideSeen,
    ));
    if (open == true && mounted) {
      // App-info page, where ⋮ → "Allow restricted settings" lives.
      await openAppSettings();
    }
    // The toggle stays off; the user flips it again after allowing.
    return false;
  }

  Future<void> _toggleSms(bool on) async {
    final s = Strings(appState.settings.language);
    if (!on) {
      await appState.update(
          appState.settings.copyWith(smsCapture: false));
      await CaptureService.setSmsEnabled(false);
      return;
    }
    // Restricted-settings guide on first enable (sideloaded builds).
    if (!await _showPermGuide(forSms: true)) return;
    // Rationale first.
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.get('smsRationaleTitle')),
        content: Text(s.get('smsRationaleBody')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.get('notNow'))),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(s.get('turnOn'))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final status = await Permission.sms.request();
    if (!mounted) return;
    if (status.isGranted) {
      await appState.update(
          appState.settings.copyWith(smsCapture: true));
      await CaptureService.setSmsEnabled(true);
      // Drain anything already queued.
      await CaptureService.drainAndImport();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('smsPermissionDenied'))));
    }
  }

  Future<void> _toggleNotif(bool on) async {
    final st = Strings(appState.settings.language);
    if (!on) {
      await appState.update(
          appState.settings.copyWith(notificationCapture: false));
      await CaptureService.setNotificationEnabled(false);
      return;
    }
    // Restricted-settings guide on first enable (sideloaded builds).
    if (!await _showPermGuide(forSms: false)) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(st.get('notifRationaleTitle')),
        content: Text(st.get('notifRationaleBody')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(st.get('notNow'))),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(st.get('openSettings'))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    if (await CaptureService.isNotificationAccessGranted()) {
      await _enableNotif();
    } else {
      _awaitingNotifReturn = true;
      await CaptureService.openNotificationSettings();
    }
  }

  Future<void> _finishNotifOptIn() async {
    final st = Strings(appState.settings.language);
    if (await CaptureService.isNotificationAccessGranted()) {
      await _enableNotif();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(st.get('notifAccessNeeded')),
          action: SnackBarAction(
              label: st.get('openSettings'),
              onPressed: () =>
                  CaptureService.openNotificationSettings()),
        ));
      }
    }
  }

  Future<void> _enableNotif() async {
    await appState.update(
        appState.settings.copyWith(notificationCapture: true));
    await CaptureService.setNotificationEnabled(true);
    await CaptureService.drainAndImport();
  }

  @override
  Widget build(BuildContext context) {
    final settings = appState.settings;
    final t = Strings(settings.language);
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.sms_outlined),
          title: Text(t.get('smsCapture')),
          subtitle: Text(t.get('smsCaptureSub')),
          value: settings.smsCapture,
          onChanged: _toggleSms,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.notifications_outlined),
          title: Text(t.get('notifCapture')),
          subtitle: Text(t.get('notifCaptureSub')),
          value: settings.notificationCapture,
          onChanged: _toggleNotif,
        ),
      ],
    );
  }
}
