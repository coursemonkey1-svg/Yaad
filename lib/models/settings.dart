/// User-customizable app settings. Defaults are Pakistan-centric;
/// everything is adjustable. Stored in SharedPreferences (no account, no cloud).
class AppSettings {
  final String currency; // ISO code, default "PKR"
  final String timezone; // IANA name, default "Asia/Karachi"
  final String language; // "en" or "ur"
  final String theme; // "system" | "light" | "dark"
  final String dateFormat; // "dmy" | "mdy" | "ymd"
  final int firstDayOfWeek; // 1 = Monday ... 7 = Sunday
  final bool appLock; // require device auth on open
  final String defaultBank; // "meezan" or "other" — tunes OCR/import templates
  final bool smartSuggestions; // suggest purpose from history (labelled)
  final bool onboardingDone;
  final bool tourSeen; // first-run guided tour completed or skipped
  final bool smsCapture; // opt-in bank SMS parsing (off by default)
  final bool notificationCapture; // opt-in bank notification capture (off)
  final bool smsGuideSeen; // restricted-settings guide shown for SMS capture
  final bool notifGuideSeen; // restricted-settings guide shown for notif cap.
  final bool billingEnabled; // Play Billing switch (off until retention proves)
  final bool proUnlocked; // one-time yaad_pro purchase
  final bool appLockGrandfathered; // v1.0 users keep free app lock
  final String accentTheme; // "teal" free; others are Pro
  final String activityView; // "detailed" | "compact" — Activity list density
  final String period; // shared viewing period — see AppState.periodRangeMs
  final String defaultAccountId; // id of the default Account ("meezan")
  final bool showSavings; // Savings section visible on Home (default on)
  final bool notifOptInPending; // user is mid-trip to system settings to
  // grant notification access; resume/unlock passes complete the opt-in.
  // Transient flow state, persisted because the trip crosses process /
  // widget-tree death (app-lock Gate teardown). Never a user preference.

  /// Valid values for [activityView].
  static const String viewDetailed = 'detailed';
  static const String viewCompact = 'compact';

  /// Valid fixed values for [period]. A specific month is stored as
  /// 'month:YYYY-MM' (see [isPeriodValue]).
  static const String periodThisWeek = 'thisWeek';
  static const String periodThisMonth = 'thisMonth';
  static const String periodLastMonth = 'lastMonth';
  static const String periodThisYear = 'thisYear';
  static const String periodAllTime = 'allTime';

  /// Whether [v] is a storable period value: one of the fixed values
  /// above, or 'month:YYYY-MM' for a specific picked month.
  static bool isPeriodValue(String v) {
    switch (v) {
      case periodThisWeek:
      case periodThisMonth:
      case periodLastMonth:
      case periodThisYear:
      case periodAllTime:
        return true;
      default:
        return RegExp(r'^month:\d{4}-(0[1-9]|1[0-2])$').hasMatch(v);
    }
  }

  const AppSettings({
    this.currency = 'PKR',
    this.timezone = 'Asia/Karachi',
    this.language = 'en',
    this.theme = 'system',
    this.dateFormat = 'dmy',
    this.firstDayOfWeek = 1,
    this.appLock = false,
    this.defaultBank = 'meezan',
    this.smartSuggestions = true,
    this.onboardingDone = false,
    this.tourSeen = false,
    this.smsCapture = false,
    this.notificationCapture = false,
    this.smsGuideSeen = false,
    this.notifGuideSeen = false,
    this.billingEnabled = false,
    this.proUnlocked = false,
    this.appLockGrandfathered = false,
    this.accentTheme = 'teal',
    this.activityView = viewDetailed,
    this.period = periodThisMonth,
    this.defaultAccountId = 'meezan',
    this.showSavings = true,
    this.notifOptInPending = false,
  });

  AppSettings copyWith({
    String? currency,
    String? timezone,
    String? language,
    String? theme,
    String? dateFormat,
    int? firstDayOfWeek,
    bool? appLock,
    String? defaultBank,
    bool? smartSuggestions,
    bool? onboardingDone,
    bool? tourSeen,
    bool? smsCapture,
    bool? notificationCapture,
    bool? smsGuideSeen,
    bool? notifGuideSeen,
    bool? billingEnabled,
    bool? proUnlocked,
    bool? appLockGrandfathered,
    String? accentTheme,
    String? activityView,
    String? period,
    String? defaultAccountId,
    bool? showSavings,
    bool? notifOptInPending,
  }) =>
      AppSettings(
        currency: currency ?? this.currency,
        timezone: timezone ?? this.timezone,
        language: language ?? this.language,
        theme: theme ?? this.theme,
        dateFormat: dateFormat ?? this.dateFormat,
        firstDayOfWeek: firstDayOfWeek ?? this.firstDayOfWeek,
        appLock: appLock ?? this.appLock,
        defaultBank: defaultBank ?? this.defaultBank,
        smartSuggestions: smartSuggestions ?? this.smartSuggestions,
        onboardingDone: onboardingDone ?? this.onboardingDone,
        tourSeen: tourSeen ?? this.tourSeen,
        smsCapture: smsCapture ?? this.smsCapture,
        notificationCapture: notificationCapture ?? this.notificationCapture,
        smsGuideSeen: smsGuideSeen ?? this.smsGuideSeen,
        notifGuideSeen: notifGuideSeen ?? this.notifGuideSeen,
        billingEnabled: billingEnabled ?? this.billingEnabled,
        proUnlocked: proUnlocked ?? this.proUnlocked,
        appLockGrandfathered:
            appLockGrandfathered ?? this.appLockGrandfathered,
        accentTheme: accentTheme ?? this.accentTheme,
        activityView: activityView ?? this.activityView,
        period: period ?? this.period,
        defaultAccountId: defaultAccountId ?? this.defaultAccountId,
        showSavings: showSavings ?? this.showSavings,
        notifOptInPending: notifOptInPending ?? this.notifOptInPending,
      );

  Map<String, Object?> toMap() => {
        'currency': currency,
        'timezone': timezone,
        'language': language,
        'theme': theme,
        'dateFormat': dateFormat,
        'firstDayOfWeek': firstDayOfWeek,
        'appLock': appLock,
        'defaultBank': defaultBank,
        'smartSuggestions': smartSuggestions,
        'onboardingDone': onboardingDone,
        'tourSeen': tourSeen,
        'smsCapture': smsCapture,
        'notificationCapture': notificationCapture,
        'smsGuideSeen': smsGuideSeen,
        'notifGuideSeen': notifGuideSeen,
        'billingEnabled': billingEnabled,
        'proUnlocked': proUnlocked,
        'appLockGrandfathered': appLockGrandfathered,
        'accentTheme': accentTheme,
        'activityView': activityView,
        'period': period,
        'defaultAccountId': defaultAccountId,
        'showSavings': showSavings,
        'notifOptInPending': notifOptInPending,
      };

  factory AppSettings.fromMap(Map<String, Object?> m) {
    final view = m['activityView'] as String? ?? viewDetailed;
    final periodRaw = m['period'] as String? ?? periodThisMonth;
    return AppSettings(
        currency: m['currency'] as String? ?? 'PKR',
        timezone: m['timezone'] as String? ?? 'Asia/Karachi',
        language: m['language'] as String? ?? 'en',
        theme: m['theme'] as String? ?? 'system',
        dateFormat: m['dateFormat'] as String? ?? 'dmy',
        firstDayOfWeek: m['firstDayOfWeek'] as int? ?? 1,
        appLock: m['appLock'] as bool? ?? false,
        defaultBank: m['defaultBank'] as String? ?? 'meezan',
        smartSuggestions: m['smartSuggestions'] as bool? ?? true,
        onboardingDone: m['onboardingDone'] as bool? ?? false,
        tourSeen: m['tourSeen'] as bool? ?? false,
        smsCapture: m['smsCapture'] as bool? ?? false,
        notificationCapture: m['notificationCapture'] as bool? ?? false,
        smsGuideSeen: m['smsGuideSeen'] as bool? ?? false,
        notifGuideSeen: m['notifGuideSeen'] as bool? ?? false,
        billingEnabled: m['billingEnabled'] as bool? ?? false,
        proUnlocked: m['proUnlocked'] as bool? ?? false,
        appLockGrandfathered: m['appLockGrandfathered'] as bool? ?? false,
        accentTheme: m['accentTheme'] as String? ?? 'teal',
        activityView:
            (view == viewCompact) ? viewCompact : viewDetailed,
        period: isPeriodValue(periodRaw) ? periodRaw : periodThisMonth,
        defaultAccountId: m['defaultAccountId'] as String? ?? 'meezan',
        showSavings: m['showSavings'] as bool? ?? true,
        // Absent in settings/backups written before this field existed.
        notifOptInPending: m['notifOptInPending'] as bool? ?? false,
      );
  }
}
