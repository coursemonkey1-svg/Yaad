# Yaad — Play Store Publishing Checklist

Everything below is free except the one-time **$25 Play developer
registration fee** (paid to Google, unavoidable for Play Store listing).
Direct APK distribution and F-Droid remain completely free alternatives.

## 1. One-time setup (owner: Inzimam)

- [ ] Create a Google Play developer account at
      https://play.google.com/console ($25 one-time, identity verification required)
- [ ] In Play Console: **Create app** → name "Yaad", default language English,
      app type: App, free, category: Finance
- [ ] Enable **Play App Signing** (Google manages the upload key — recommended)
- [ ] Build the release AAB (see CI below) and upload to an **internal testing**
      track first; promote to production after testing

## 2. Required store-listing assets

- [ ] App icon 512×512 PNG (no alpha)
- [ ] Feature graphic 1024×500 PNG
- [ ] 2–8 phone screenshots (min 1080px)
- [ ] Short description (≤80 chars): "Never forget what your money was for."
- [ ] Full description: what Yaad does, on-device privacy, free forever
- [ ] Privacy policy URL — host `PRIVACY_POLICY.md` (in this repo) as a page,
      e.g. GitHub Pages, and paste the link (Play **requires** this for finance apps)
- [ ] Data safety form (Play Console → App content):
      - Data collected: **none** transmitted off-device. Location: no. Personal info: no.
      - The app processes financial records **on-device only**.
      - Optional: files the user explicitly shares out (backup/export via Android share sheet)
      - Encryption in transit: N/A (no network transmission of user data)
      - Account deletion: in-app "Delete all my data" (Settings)

## 3. Policy notes specific to Yaad

- **No bank credentials.** The app never asks for, stores, or transmits any
  bank username, password, PIN, or OTP. Say this in the listing.
- **No background SMS/call-log reading.** Receipt capture is user-initiated
  (Share button / image picker / statement file picker).
- **RECORD_AUDIO** is declared for the optional voice-note mic on the note
  field. It is only activated by tapping the mic button. Explain this in the
  listing and in the data-safety form.
- Target audience: general; no gambling/crypto claims; Islamic-finance friendly
  (no interest-based features).

## 4. Builds (free CI)

Push to `main` → GitHub Actions builds:
- `yaad-debug-apk` — install directly on a phone for testing
- `yaad-release-aab` — upload to Play Console

For the very first production upload, use the AAB from CI, then let
Play App Signing handle all future signing.

## 5. Free alternatives to the Play Store

- **Direct APK:** share the debug/release APK link; users enable
  "Install unknown apps" once.
- **F-Droid:** submit the repo; review is free, updates via their build server.
