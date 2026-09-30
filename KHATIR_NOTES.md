# Khatir APK — UX Research Notes

**Method:** Full apktool decode of `base_0_j0aj.apk` (package `com.aistudio.meezanfinance.pkrcp`, "Khatir", native Android / Jetpack Compose + Material 3). The decode of the app's own dex files partially failed (apktool hit an error saving its metadata file, so no smali for the app code), so screen structure was reconstructed from string tables, resources, the manifest, and class/method names in the dex files — not from decompiled layouts. Things I could **not** verify: animation/motion details (Compose transitions live in code), exact visual ordering on the dashboard, and keyboard behavior in the add form.

## 1. What Khatir does

Khatir is a Meezan-focused personal finance tracker for Pakistan: log spending fast (type, voice note, receipt scan, or pasted bank SMS), auto-parse Meezan receipts/SMS into clean merchant names and categories, and track money lent to / borrowed from people with per-person ledgers and repayment timelines. Its standout trait is **Pakistani specificity** — Lakh/Crore number formatting, Roman-Urdu voice notes, and Meezan receipt parsing are first-class, not afterthoughts.

## 2. Adoptable UX ideas (prioritized)

### P0 — The things that actually make it feel "professional"

**1. Pakistani number formatting (Lakh / Crore)**
- *What it is:* A `CurrencyFormatter` with compact forms — "PKR 1.5 Lakh", "PKR 2.3 Crore", "PKR 850 K" — plus full amounts grouped the Pakistani way ("PKR 1,50,000", not "PKR 150,000"). It's a user setting ("Use Pakistani Number Format"). The AI prompts even instruct Lakh/Crore conventions.
- *Where in Yaad:* Every amount display app-wide (home, Activity, Udhaar, ledgers, export).
- *Why it feels professional:* Nothing signals "built for me" faster. Western digit grouping on rupee amounts feels foreign; Lakh/Crore is how Pakistanis actually talk about money. Yaad currently has no Lakh/Crore formatting at all — this is a genuine gap.

**2. Home screen answers "who owes me what" at a glance**
- *What it is:* The dashboard is composed of: a net-position header ("TOTAL RECEIVABLE FROM X" / "YOU OWE Y", or the delightful **"Balance: Clean"** when everything is settled) → a row of `QuickActionChip`s → a list of `PersonLedgerMiniCard`s (per-person mini ledger cards with outstanding balances, right on the home screen) → a `TransactionFeedItem` recent-activity feed.
- *Where in Yaad:* `lib/screens/home.dart`. Yaad buries people balances inside the Udhaar tab; Khatir puts the per-person cards on the home screen itself.
- *Why it feels professional:* The app's core job — money lent to friends — is visible in one glance with zero navigation. A dashboard should answer the user's #1 question, not show charts.

**3. Instructive empty states everywhere (never a blank screen)**
- *What it is:* Every empty state tells the user what to do, with a concrete Pakistani example: "No contacts yet. Tap '+ New Person' to add Mother, Brother, etc." / "No merchant aliases created yet." / "No repayment entries recorded yet." / "No transactions logged yet. Tap a quick action to start." / "No active money lent". The review inbox's empty state is celebratory: **"Inbox Zero! All transactions have context."**
- *Where in Yaad:* All list screens, especially Activity filters and Udhaar (v1.2 work items 1–2).
- *Why it feels professional:* Empty screens are where cheap apps look broken. Khatir's never do — they teach. This is free to implement and high-impact.

**4. One-line feedback for every action**
- *What it is:* Every mutation gets an immediate confirmation line: "Alias removed", "Transaction deleted", "Loan record deleted", "Updated loan status", "Recorded repayment of PKR 5,000", "Added label '…'". Relative timestamps everywhere: "Just now", "Yesterday at …", "Today at …", then "dd MMM yyyy, hh:mm a".
- *Where in Yaad:* App-wide; pair with Yaad's existing snackbar patterns.
- *Why it feels professional:* The app feels alive and responsive. Silence after a tap is what makes an app feel "built in 10 minutes".

**5. First-person plain language instead of finance jargon**
- *What it is:* Loan direction is a choice between **"I Lent Money"** and **"I Borrowed Money"** (buttons: "Record Money Lent" / "Record Money Borrowed"). The loan dialog asks **"How is it being repaid?"** People are "Family & Friends Ledgers", not "counterparties".
- *Where in Yaad:* `lend.dart`, `borrow.dart`, `udhaar.dart`, and all button labels.
- *Why it feels professional:* Matches Inzimam's plain-words rule directly. Professional doesn't mean formal — it means the user never has to translate.

### P1 — Flows worth adopting

**6. "5s Quick Log": sign-prefixed amount entry**
- *What it is:* The add screen's amount field accepts **"+5000" (money in) / "-2500" (money out)** — direction comes from the sign, placeholder literally says "type +5000 or -2500". Plus a "Quick Amount Suggestions" chip row. The note field uses a Roman-Urdu example placeholder: "e.g. Ahsan ko lunch ke paise diye".
- *Where in Yaad:* `lib/screens/capture.dart`.
- *Why it feels professional:* One field instead of a type-toggle + amount field. Fewer taps, no mode confusion, and the placeholder teaches the trick inline.

**7. Capture has four doors, one destination**
- *What it is:* Quick capture offers: type it, **voice note** (mic → transcribed and auto-categorized: "Voice note transcribed & categorized"), **scan receipt** (OCR), **paste SMS** ("Paste Meezan SMS or text receipt"). The app also registers share-sheet handlers for images and text, so a Meezan receipt shared from WhatsApp ("Meezan Shared Receipt") lands straight in the app.
- *Where in Yaad:* `capture.dart` + Yaad's existing share-sheet/OCR plans; voice is a natural Pro-tier candidate.
- *Why it feels professional:* Meets the user where the data already is (WhatsApp receipts, bank SMS) instead of demanding manual typing. Note the privacy angle below before copying the implementation.

**8. Needs Review Inbox (the "confirm" pattern)**
- *What it is:* Anything auto-parsed (receipt, SMS, voice) lands with status `NEEDS_REVIEW` in a **"Needs Review Inbox"**. Each item card has one primary action — **"Confirm Context"** → **"Save Context in 1-Tap"**. Clearing it earns the "Inbox Zero!" empty state.
- *Where in Yaad:* `lib/screens/review.dart` (already exists — adopt the inbox framing + one-tap confirm).
- *Why it feels professional:* Turns the chore of fixing parsed data into a completable, almost game-like loop. The user trusts automation more when there's a visible checkpoint.

**9. Merchant aliases that learn by themselves**
- *What it is:* "Translate confusing Meezan bank titles into clear, friendly names." When a receipt is saved, the app offers **"Remember this alias for future Meezan receipts"**, and "aliases are learned automatically" — so "PSO SHAHRAH-E-FAISAL" becomes "PSO Petrol Pump" forever. The aliases screen is ordered by match count / recency.
- *Where in Yaad:* `lib/screens/aliases.dart` (exists — add the auto-learn offer at save time + friendly-name framing).
- *Why it feels professional:* The app visibly gets smarter with use. That's the "magical" feeling — and it's just a lookup table.

**10. Repayment timeline per loan (audit trail)**
- *What it is:* Tapping a loan opens a `RepaymentTimelineSheet`: "Audit Trail & Repayment Entries", "View Repayment Timeline", per-loan "Repaid: X / Remaining: Y", **"Mark Fully Settled"**, and an honest empty state ("No partial repayments recorded yet for this loan").
- *Where in Yaad:* `repay.dart` / `timeline.dart`.
- *Why it feels professional:* Partial repayments only feel trustworthy when every rupee has a visible trail. This is the feature that makes Udhaar feel like a real ledger, not a notepad.

**11. Privacy presented as a feature (settings)**
- *What it is:* Settings leads with **"100% On-Device Financial Privacy"** as a header, then gives real choices: "Receipt Image Storage Privacy" (keep receipt photos locally vs delete right after parsing), "Save Audio Memo File" for voice notes, "Protect Recent Deletions" (a soft-delete guard), and **"Reset & Reload Sample Pakistani Data"** — realistic demo data (a PKR 10,000 loan, family ledgers, starter aliases) for trying the app.
- *Where in Yaad:* `lib/screens/settings.dart`.
- *Why it feels professional:* Privacy as a visible, choosable feature builds trust; sample data makes first-run and testing feel real instead of empty. (Keep sample data clearly labeled — see "don't copy" below.)

**12. Structured receipt parsing, shown back to the user**
- *What it is:* Receipt parsing extracts six labeled fields — amount, merchant/beneficiary, reference number, payment channel ("Meezan Raast", "1Link IBFT", "Meezan Debit Card", "Meezan Bill Pay"), suggested category, summary note — and shows them in a confirmation screen ("Extracted Meezan receipt: PKR …", "Bank Raw Title:" vs "Friendly Name:") before saving.
- *Where in Yaad:* `import_preview.dart` / `confirm.dart` (already exist — show the parsed fields as labeled rows, including the raw-vs-friendly name pair).
- *Why it feels professional:* Showing its work is what makes automation trustworthy. A spinner that says "Extracting PKR Amount & Merchant…" plus a field-by-field review beats a black box.

### P2 — Smaller polish

**13. Four-tab bottom nav; capture on an extended FAB.** Destinations are just HOME, PEOPLE, REVIEW, SETTINGS — spending summary and ledgers are pushed from content, not tabs. Yaad's five tabs could lose one.
**14. Quick-create dialogs without leaving context** ("Add Person", "Add Loan", "Add Label" dialogs open from wherever you are).
**15. Dedicated per-person ledger screen** ("Separate ledgers for family & friends with full audit trails", "Open Person Ledger") — Yaad's `person_detail.dart` is the right home; make sure it's reachable in one tap from the home mini-cards.
**16. Custom labels framed as "your family's tags"** ("Your custom transaction tags and family expense labels", presets listed first) — aligns with Yaad v1.2 item 2.

## 3. What NOT to copy

- **The cloud AI dependency.** Khatir sends receipt images and voice recordings to Google's Gemini cloud API (Firebase AI). Copying that would break Yaad's core promise — "your money data never leaves your phone" — and the no-backend monetization plan. Adopt the *UX* (transcribe → categorize → confirm); implement it on-device (ML Kit, local parsing) or make any cloud step strictly opt-in with a plain-words explanation.
- **Branding and identity.** The "Khatir" name, its green/amber palette, and its wallet-motif icon are its identity. Yaad has its own (deep teal). Take the patterns, never the look or the words — write Yaad's own microcopy.
- **No real Urdu localization.** Despite the audience, Khatir ships zero app-level Urdu strings (only library-provided ones) and no RTL work beyond the manifest flag. Yaad's EN+UR plan is already ahead — don't regress to Khatir's level here.
- **Prototype-grade security posture.** The APK is `debuggable=true` with `allowBackup=true`. That's an AI-tool prototype default, not a standard to match.
- **Sample data as a trap.** "Reset & Reload Sample Pakistani Data" is great as a labeled settings option; it must never be the default state or be confusable with the user's real money.
- **Vague feature toggles.** "Transcribe to Text Only (Lightweight)" is a confusing option — the kind of jargon-y setting Yaad should avoid. Every setting should explain itself in one plain line.
- **The 23MB native + Firebase weight.** Khatir drags in Firebase, Play Services, and Recaptcha for a local finance app. Yaad's lean offline-first build is the better architecture — keep it.

## Bottom line

Khatir doesn't feel professional because of visuals — it uses stock Material 3 with no custom fonts. It feels professional because it is **specific**: Lakh/Crore numbers, Roman-Urdu placeholders, Meezan receipt parsing, "Mother, Brother" in empty states. And because it is **responsive**: every screen has an empty state, every action has a confirmation, every automated step has a human checkpoint. For Yaad's quality reset, that's the real lesson: professionalism = specificity + feedback + plain words, not gradients.
