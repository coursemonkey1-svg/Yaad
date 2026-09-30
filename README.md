# Yaad — never forget what your money was for

A free, private, on-device personal finance companion for Android
(iOS later). Bank-agnostic, with Meezan Bank as the default profile.

**100% free** for users and for the developer: no backend, no paid SDKs,
no accounts, no ads, no tracking. Everything runs on the phone.

## What it does

- **5-second capture** — share a receipt from your bank app, snap a
  screenshot, type it manually, or dictate a note. Tap a purpose. Done.
- **Remembers context** — your own names for confusing bank labels
  ("corner grocery near home"), suggested next time.
- **Needs Review inbox** — unannotated imports wait for one tap; nothing
  is ever silently auto-saved.
- **People & balances** — lend money, log partial repayments, see original /
  repaid / remaining automatically. Repayments never count as income.
- **Statement import** — CSV / Excel / text with duplicate detection.
- **Spending summaries** — week/month totals by purpose.
- **Your data, your files** — JSON backup, CSV export, one-tap full delete.

## Why no automatic bank sync?

Pakistani banks (including Meezan) offer **no public API** for third-party
personal-finance apps — integrations exist only as contracted B2B
partnerships. So Yaad is built around user-initiated capture:

1. Android Share sheet (receipt text from the bank app)
2. On-device OCR (receipt screenshots)
3. Statement file import (CSV/Excel/text)
4. Fast manual entry

The architecture is ready to plug in an official API if SBP open banking
ever ships — without changing the data model.

## Build it (free)

```bash
flutter pub get
flutter analyze
flutter run
```

Push to `main` and GitHub Actions builds a debug APK and a release AAB
for free — no local Android SDK needed.

## Project layout

```
lib/
  main.dart            app shell, nav, share-intent receiver, app lock
  models/              transaction, person, lending, alias, settings, purposes
  data/db.dart         SQLite schema + queries (on-device)
  services/            app_state, ocr (ML Kit), importer, suggest, backup
  screens/             onboarding, home, capture, confirm, timeline,
                       review, summary, people, person_detail, lend,
                       aliases, settings
  widgets/             purpose_grid, note_field (voice dictation)
  l10n/strings.dart    English + Urdu strings
android/               manifest with share-receiver intent filters
.github/workflows/     free CI: APK + AAB on every push
```

## Publishing

See [PLAY_STORE_CHECKLIST.md](PLAY_STORE_CHECKLIST.md). The only
unavoidable cost in the whole project is Google's one-time $25 Play
developer registration. [PRIVACY_POLICY.md](PRIVACY_POLICY.md) is the
policy text for the store listing.
