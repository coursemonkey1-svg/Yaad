import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/db.dart';
import '../l10n/strings.dart';
import '../main.dart';
import '../models/settings.dart';
import '../services/backup.dart';
import '../services/capture_inbox.dart';
import '../services/demo_data.dart';
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
            // Bottom padding clears the shell's floating Add button —
            // the last rows (incl. Delete all) can always scroll
            // fully above it.
            padding: const EdgeInsets.fromLTRB(
                Gap.x2, Gap.x2, Gap.x2, 96),
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
              SwitchListTile(
                secondary: const Icon(Icons.savings_outlined),
                title: Text(t.get('showSavings')),
                subtitle: Text(t.get('showSavingsSub')),
                value: s.showSavings,
                onChanged: (v) =>
                    appState.update(s.copyWith(showSavings: v)),
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
              _section(t.get('demoData')),
              const _DemoDataSection(),
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
                title: const Text('Yaad 1.5.0'),
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
      // A backup can carry settings too — reload them, not just data.
      await appState.load();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(Strings(appState.settings.language)
                .get('restoreDone')
                .replaceFirst('{added}', '${summary.added}')
                .replaceFirst('{skipped}', '${summary.skipped}'))));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(Strings(appState.settings.language).get('restoreFailed').replaceFirst('{e}', '$e'))));
      }
    }
  }

  Future<void> _wipe(BuildContext context) async {
    final s = Strings(appState.settings.language);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.get('deleteAllConfirmTitle')),
        content: Text(s.get('deleteAllConfirmBody')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.get('cancel'))),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(s.get('deleteEverything'))),
        ],
      ),
    );
    if (ok == true) {
      // Capture the messenger BEFORE the settings reset: resetting
      // flips onboardingDone off, YaadApp swaps the whole shell for
      // the onboarding screen, and this context unmounts — the
      // "all data deleted" confirmation raced that rebuild and was
      // sometimes never shown. The root messenger survives the swap.
      final messenger = ScaffoldMessenger.of(context);
      await YaadDb.wipeAll();
      // Factory reset of everything that lives OUTSIDE the database,
      // so "deleted" is deleted everywhere:
      // — settings back to full defaults (which also defaults the
      //   capture toggles and the default account to the re-seeded
      //   Meezan);
      // — the native capture flags off and the queued bank alerts
      //   deleted, so pre-wipe alerts can't be imported if capture
      //   is ever turned on again;
      // — the capture inbox emptied (its entries point at
      //   transactions that no longer exist);
      // — the demo openings snapshot dropped, so a later demo
      //   add/remove cycle can't resurrect pre-wipe balances.
      await appState.update(const AppSettings());
      try {
        await CaptureService.setSmsEnabled(false);
        await CaptureService.setNotificationEnabled(false);
      } catch (_) {
        // Native side unreachable (non-Android build): the settings
        // reset above already keeps capture off in-app.
      }
      await CaptureService.clearCaptureQueues();
      await CaptureInbox.instance.clear();
      await DemoData.clearOpeningsSnapshot();
      // And the FILES: voice-note recordings (spoken financial
      // details), saved receipt images, and every exported backup /
      // CSV (each a complete financial history) must not survive a
      // "delete all my data" either.
      await BackupService.deleteWipeLeftovers();
      appState.refresh();
      messenger.showSnackBar(
          SnackBar(content: Text(s.get('allDataDeleted'))));
    }
  }
}

/// "Add / Remove demo data" (v1.5). Shows exactly one of the two —
/// whichever applies. Adding fills every screen with sample figures
/// so a new user can see how Yaad works; removing deletes exactly
/// those sample rows (see services/demo_data.dart).
class _DemoDataSection extends StatefulWidget {
  const _DemoDataSection();

  @override
  State<_DemoDataSection> createState() => _DemoDataSectionState();
}

class _DemoDataSectionState extends State<_DemoDataSection> {
  bool? _hasDemo;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final has = await DemoData.hasDemo();
    if (mounted) setState(() => _hasDemo = has);
  }

  Future<void> _add() async {
    if (_busy) return;
    setState(() => _busy = true);
    final s = Strings(appState.settings.language);
    await DemoData.addDemo(currency: appState.settings.currency);
    appState.refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hasDemo = true;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s.get('demoAdded'))));
  }

  Future<void> _remove() async {
    if (_busy) return;
    final s = Strings(appState.settings.language);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.get('demoConfirmTitle')),
        content: Text(s.get('demoConfirmBody')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.get('cancel'))),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(s.get('removeDemoData'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await DemoData.removeDemo();
    appState.refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hasDemo = false;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s.get('demoRemoved'))));
  }

  @override
  Widget build(BuildContext context) {
    final t = Strings(appState.settings.language);
    final has = _hasDemo;
    if (has == null) {
      return const ListTile(
        leading: Icon(Icons.science_outlined),
        title: Text('…'),
      );
    }
    return ListTile(
      leading: const Icon(Icons.science_outlined),
      title: Text(has ? t.get('removeDemoData') : t.get('addDemoData')),
      subtitle:
          Text(has ? t.get('removeDemoDataSub') : t.get('addDemoDataSub')),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right),
      onTap: _busy ? null : (has ? _remove : _add),
    );
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
  /// True while THIS section has the user away in system settings for
  /// a notification opt-in it started. Only used to decide whether the
  /// 'notifAccessNeeded' nudge belongs to this screen on resume — the
  /// durable record of the pending opt-in is
  /// [AppSettings.notifOptInPending], which survives this State being
  /// disposed (the app-lock Gate tears the whole shell down on
  /// re-lock, which is what used to lose the opt-in entirely).
  bool _sentToNotifSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Reconcile the moment Settings opens, not just at shell
    // start/resume: if the OS-level grant was revoked outside the
    // app, the switches below must show the truth immediately
    // (the shell-level pass in main.dart covers start/resume; this
    // closes the "opened Settings directly" gap).
    CaptureService.reconcileCaptureFlags();
    // A capture opt-in that completed (elsewhere — Gate unlock or
    // shell drain) with the grant still missing owes the user its
    // explanation HERE: the Settings state that started the trip may
    // have been disposed by the Gate, so the miss is persisted in
    // settings and the fresh screen delivers the nudge.
    WidgetsBinding.instance.addPostFrameCallback((_) => _showMissedNudges());
  }

  Future<void> _showMissedNudges() async {
    if (!mounted) return;
    final st = Strings(appState.settings.language);
    final cur = appState.settings;
    if (cur.notifOptInMissed) {
      await appState
          .update(appState.settings.copyWith(notifOptInMissed: false));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(st.get('notifAccessNeeded')),
        action: SnackBarAction(
            label: st.get('openSettings'),
            onPressed: _retryNotifSettings),
      ));
    }
    if (appState.settings.smsOptInMissed) {
      await appState
          .update(appState.settings.copyWith(smsOptInMissed: false));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(st.get('smsPermissionDenied'))));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumeNotifOptIn();
      _resumeSmsOptIn();
    }
  }

  /// The user came back from the SMS permission dialog: finish the
  /// pending SMS opt-in (persisted flag; the shell's drain pass and
  /// the Gate's unlock pass run it too — first one wins). A miss is
  /// explained, never silent.
  Future<void> _resumeSmsOptIn() async {
    final outcome = await CaptureService.completePendingSmsOptIn();
    if (!mounted || outcome != SmsOptInOutcome.missing) return;
    // This screen delivered the explanation; consume the persisted
    // miss so a later fresh Settings doesn't repeat it.
    await appState
        .update(appState.settings.copyWith(smsOptInMissed: false));
    if (!mounted) return;
    final st = Strings(appState.settings.language);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(st.get('smsPermissionDenied'))));
  }

  /// The user came back from system settings: finish the pending
  /// notification opt-in (the persisted flag, completed by
  /// [CaptureService.completePendingNotifOptIn] — the shell's resume
  /// pass and the Gate's unlock pass call it too, first one wins).
  /// If the grant is still missing and it was this screen that sent
  /// the user away, nudge once with a retry.
  Future<void> _resumeNotifOptIn() async {
    final wasMine = _sentToNotifSettings;
    _sentToNotifSettings = false;
    final outcome = await CaptureService.completePendingNotifOptIn();
    if (!mounted) return;
    // Outcome may be `none` because the shell's resume pass resolved
    // the pending flag first; fall back to the visible truth.
    final enabled = outcome == NotifOptInOutcome.enabled ||
        appState.settings.notificationCapture;
    if (enabled || !wasMine) return;
    // This screen delivered the nudge; consume the persisted miss so
    // a later fresh Settings doesn't repeat it.
    await appState
        .update(appState.settings.copyWith(notifOptInMissed: false));
    if (!mounted) return;
    final st = Strings(appState.settings.language);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(st.get('notifAccessNeeded')),
      action: SnackBarAction(
          label: st.get('openSettings'),
          onPressed: _retryNotifSettings),
    ));
  }

  /// Snackbar retry: re-arm the pending opt-in and open system
  /// settings again — and if even that fails, say how to get there
  /// manually instead of doing nothing. A failed open also disarms
  /// the pending flag: the user never left the app, so no resume
  /// will ever complete it, and a stale pending flag freezes the
  /// notification channel out of reconciliation meanwhile.
  Future<void> _retryNotifSettings() async {
    await appState
        .update(appState.settings.copyWith(notifOptInPending: true));
    _sentToNotifSettings = true;
    if (!await _openNotifSettingsOrExplain()) {
      await appState
          .update(appState.settings.copyWith(notifOptInPending: false));
    }
  }

  /// Opens system notification settings; on failure shows the manual
  /// path ('notifOpenSettingsFailed'). A button that silently does
  /// nothing reads as a broken app. Returns whether settings opened.
  Future<bool> _openNotifSettingsOrExplain() async {
    final opened = await CaptureService.openNotificationSettings();
    if (!opened && mounted) {
      final st = Strings(appState.settings.language);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(st.get('notifOpenSettingsFailed'))));
    }
    return opened;
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

  /// Native capture-flag writes from this screen must never crash a
  /// toggle handler when the channel is unavailable (non-Android
  /// build): the settings flag is the in-app truth, and reconcile
  /// re-asserts the native side on the next pass.
  Future<void> _native(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {
      // See above.
    }
  }

  Future<void> _toggleSms(bool on) async {
    final s = Strings(appState.settings.language);
    if (!on) {
      await appState.update(appState.settings
          .copyWith(smsCapture: false, smsOptInPending: false));
      await _native(() => CaptureService.setSmsEnabled(false));
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
    // Persist the pending opt-in BEFORE the system permission
    // dialog: the trip can tear this screen down (the app-lock Gate
    // re-locks while the permission activity is up), and the old
    // code's `if (!mounted) return` after the request threw a
    // GRANTED permission away — the toggle stayed off, unexplained.
    // The persisted flag lets the completion pass (here, shell
    // drain, or Gate unlock — first one wins) finish the job.
    await appState
        .update(appState.settings.copyWith(smsOptInPending: true));
    await Permission.sms.request();
    final outcome = await CaptureService.completePendingSmsOptIn();
    if (!mounted) return;
    if (outcome == SmsOptInOutcome.missing) {
      await appState
          .update(appState.settings.copyWith(smsOptInMissed: false));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.get('smsPermissionDenied'))));
    }
  }

  Future<void> _toggleNotif(bool on) async {
    final st = Strings(appState.settings.language);
    if (!on) {
      await appState.update(appState.settings
          .copyWith(notificationCapture: false, notifOptInPending: false));
      await _native(() => CaptureService.setNotificationEnabled(false));
      return;
    }
    // Access already granted (turned on earlier in system settings,
    // or left over from a previous opt-in): turn capture straight on.
    // Checking this FIRST matters — the old flow showed the guide and
    // rationale dialog before ever checking, so a user who had
    // already granted access got the whole dialog loop again and the
    // toggle could never land.
    if (await CaptureService.isNotificationAccessGranted()) {
      await _enableNotif();
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
      // Persist the pending opt-in BEFORE leaving for system
      // settings: widget state would not survive the trip (the
      // app-lock Gate can tear this screen down on re-lock), the
      // settings flag does. Resume/unlock passes complete it. If
      // opening settings FAILS, the user never left — disarm the
      // flag again, or it would sit pending forever and freeze the
      // notification channel out of reconciliation.
      await appState
          .update(appState.settings.copyWith(notifOptInPending: true));
      _sentToNotifSettings = true;
      if (!await _openNotifSettingsOrExplain()) {
        await appState
            .update(appState.settings.copyWith(notifOptInPending: false));
      }
    }
  }

  Future<void> _enableNotif() async {
    await appState.update(appState.settings
        .copyWith(notificationCapture: true, notifOptInPending: false));
    await _native(() => CaptureService.setNotificationEnabled(true));
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
