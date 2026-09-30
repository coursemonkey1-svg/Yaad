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
      };

  factory AppSettings.fromMap(Map<String, Object?> m) => AppSettings(
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
      );
}
