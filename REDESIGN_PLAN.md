# Yaad v1.1 — Redesign Plan

**Status:** DRAFT — awaiting Inzimam's approval. Code freeze is in effect; no
implementation until he explicitly says "go".
**Author:** Muse · **Date:** 2026-09-30
**Inputs:** device testing feedback (build-13), market/UX deep research
(`research_notes/finance-app-market-research-20260930-0941/`), monetization
deep research (`research_notes/app-monetization-research-20260930-0953/`).

## 0. Goals

1. **Minimum time in app** — both feeding transactions and understanding them.
   Every screen answers "this is for this" in plain words at a glance.
2. **Immediately understandable money** — Spent / Received / Lent / Borrowed /
   Paid back, never mixed, no accountant vocabulary, no unexplained −/+ signs.
3. **Professional, attractive UI** — the bar is "designed by a professional UI
   designer", not "functional".
4. **Privacy-first monetization** — free core + one-time Pro unlock; no ad SDK,
   no tracking, no backend. (Decisions ratified with Inzimam 2026-09-30.)
5. **Pakistan-first, world-ready** — win locally; currency/bank-agnostic
   architecture so international is a marketing decision, not a rewrite.

Non-goals for v1.1: iOS, cloud sync, budgets/goals engine, multi-currency
wallets, official bank API integration (none exists for Meezan publicly).

---

## 1. Information architecture

Bottom nav keeps 4 tabs, renamed and clarified:

| Tab | Label | Contents |
|-----|-------|----------|
| 1 | **Home** | Glanceable dashboard (§3) |
| 2 | **Activity** | All transactions, searchable, filterable |
| 3 | **Udhaar** | People + lent/borrowed ledger (§5) |
| 4 | **Settings** | Preferences, import/export, Pro, About |

Capture: remove the `centerDocked` large FAB (it overlaps Activity/People —
confirmed bug). Replace with a standard extended FAB at `endFloat` labeled
**"Add"** with a `+` icon. Thumb-reachable, never overlapping.

Every screen gets a plain-words empty state explaining its purpose
("This is where …"), per Inzimam's "this is for this" requirement.

## 2. Money model — the critical fix

Root cause of the confusion: lending movements are stored as ordinary
transactions (`direction: out`, `purpose: 'loan'`) and `sumOut()` counts them
as spending. Lending is **not** spending.

New transaction **kinds** (stored on the txn, replacing direction-only logic):

- `spend` — money spent (was: direction out, non-lending purpose)
- `receive` — money received (was: direction in, non-lending purpose)
- `lendOut` — I lent money to someone
- `borrowIn` — someone lent money to me
- `repayOut` — I paid someone back
- `repayIn` — someone paid me back

Rules:

- **Spending totals count only `spend`.** `receive` totals count only `receive`.
- Lending kinds never appear in spending charts/totals; they live in Udhaar.
- Display language is fixed: **Spent**, **Received**, **Lent**, **Borrowed**,
  **Paid back** (direction of repayment resolved per-person in Udhaar:
  "Ahmed paid you back" / "You paid Sara back"). The words "debit", "credit",
  "outflow" are banned from UI. `−`/`+` signs may appear only as secondary
  affordances, never as the primary communicator.
- `LendScreen._save()` is rewritten to write the correct kind instead of
  direction+purpose hacks.

## 3. Home dashboard — one question per glance

Layout (top to bottom):

1. **Hero card** — "Spent in September" + big amount; sub-line "Received
   Rs X". Taps through to the spending breakdown. Lending excluded (§2).
2. **Two plain cards:**
   - "People owe you — Rs 5,000 · 3 people" → opens Udhaar
   - "You owe — Rs 2,000 · 1 person" → opens Udhaar
   (Each hidden when zero, so the screen stays calm.)
3. **"Needs your eye" card** — only when the review queue is non-empty:
   "3 transactions need a quick check — tap to fix." Plain explanation of
   *why* each item is there.
4. **Recent activity** (5 latest, any kind, with kind-appropriate wording).

No BI clutter: no charts on first paint. (Spending-by-purpose breakdown stays
one tap away on the Summary screen.)

## 4. Capture — the "Add" flow

Primary path (target: under 10 seconds, ~3 taps):

**Add sheet → big amount first → 4 plain choices → details → Save.**

The 4 choices (large, tappable, plain words — no toggles):

1. **I spent** → amount, category grid (~10–12 life-shaped categories,
   incl. local presets: Bijli, Gas, Mobile load, Rickshaw, Mess bill…),
   optional note/voice.
2. **I received** → amount, source (Salary, Gift, Other…), optional note.
3. **I lent** → opens the Lend screen (§5): who + amount + optional reason.
4. **I borrowed** → opens the Borrow screen (§5): who + amount + optional reason.

Secondary entry points (all funnel into the same Confirm screen):

- **Share from bank app** (text) → parse → Confirm. Must *never* fail
  silently: if parsing yields nothing, still open Confirm prefilled empty with
  the shared text attached as the note.
- **Receipt photo / gallery image** → OCR with visible progress → Confirm.
  On OCR failure: plain error + "enter it manually" path with the image kept.
  (Fixes confirmed silent-fail bug.)
- **Voice note** → fix the dead mic: `RECORD_AUDIO` is already in the
  manifest; the bug is the missing **runtime** permission flow. Request at
  tap-time with a one-line explanation; if denied, guide to app settings.
  Never a dead button again.
- **SMS auto-capture** (§6).

The old 5-item QuickCaptureSheet ("share receipt / note on latest / record
manually / I lent / someone repaid me") is replaced by the amount-first sheet
above. Repayments move into Udhaar person detail (§5), where they belong.

## 5. Udhaar — the lending & borrowing ledger

Tab renamed **People → "Udhaar"** (subtitle: "Lent & borrowed"). This is the
differentiator; it gets its own polished home.

- **Person list:** each row shows net balance in plain words —
  "Ahmed owes you Rs 2,000", "You owe Sara Rs 500", "Settled with Bilal".
  Search at top. "Add person" affordance.
- **Person detail:** full history (lends, borrows, repayments with dates),
  remaining balance, and four explicit actions — **never a toggle**:
  - "Lend again" (I lent)
  - "Borrow again" (They lent me)
  - "They paid me" (repayment in, links to open balance with one-tap confirm)
  - "I paid them" (repayment out)
  - "Settle up" when a small remainder is left (one-tap final repayment).
- Partial repayments, link suggestions (user always confirms), and per-loan
  reason/date stay as they are — that logic is good.
- **Statement of account** (shareable text summary per person) → **Pro**
  feature (it's an export power-tool).

The confusing "They owe me / I owe them" segmented toggle on the
"I lent money" screen is deleted. Borrowing gets its own first-class screen
titled **"I borrowed money"**.

## 6. SMS / notification capture (zero-entry path)

- **Bank SMS parsing** (opt-in, off by default): `RECEIVE_SMS` permission,
  on-device parsers for Meezan/HBL/UBL/Easypaisa/JazzCash templates.
  - Uncertain parses → review queue ("Needs your eye"), never auto-applied.
  - A plain-words rationale screen precedes the permission request.
  - Play policy note: SMS permissions are restricted; declaration must frame
    it as core financial functionality. If Play rejects, fall back to
    notification-listener only.
- **Notification listener** (opt-in, off by default): captures bank app
  transaction notifications on-device. Same review-queue rule.
- No cloud, no exceptions. Both are pure on-device.

## 7. Statement import + PDF strategy

- Keep CSV/Excel/text import with column-mapping memory, preview-and-confirm,
  dedupe, and self-transfer pairing (transfers between the user's own accounts
  must not become spend + income).
- **PDF (fixes "can't select PDFs" bug):** add `pdf` to the picker's allowed
  extensions. Attempt on-device text extraction; bank PDFs are often scanned
  images, so extraction frequently fails — when it does, say so plainly and
  guide the user: "Your bank app can export CSV — here's how for Meezan"
  (steps in-app). Never a silent dead-end. No cloud OCR, ever.

## 8. Confirmed bug fixes (all in v1.1)

1. FAB overlaps bottom nav → endFloat extended "Add" FAB (§1).
2. Share-receipt image flow silently fails → progress + errors + manual
   fallback (§4).
3. Mic button dead → runtime `RECORD_AUDIO` permission flow (§4). (Manifest
   entry already present — verified 2026-09-30.)
4. Statement picker can't see PDFs → allow + graceful extraction (§7).
5. Bank share "works somewhat" → **open question**: Inzimam to clarify what he
   expected vs what happened; fix confirmed in the v1.1 test pass.

## 9. Visual design system — "professional UI designer" bar

- **Material 3**, coherent design tokens: 8pt spacing grid, a proper type
  scale, one primary identity color (teal evolves into a more distinctive
  deep-teal + warm accent pair), first-class dark mode.
- **Motion with meaning:** subtle transitions on Add sheet, number
  count-ups on Home, nothing gratuitous.
- **States designed, not defaulted:** loading skeletons, empty states with
  guidance ("No spending recorded yet — tap Add, it takes 10 seconds"),
  error states with a next step.
- **Onboarding rewrite** (3 slides, plain words):
  1. "Your money, remembered." — what Yaad is for.
  2. "Recording takes 10 seconds." — Add → amount → done.
  3. "Udhaar, handled." — lend/borrow tracking; "Private: everything stays
     on this phone."
- **Typography & polish pass** on every existing screen (Timeline, Review,
  Summary, Aliases, Person detail, Settings) to the same standard.

## 10. Language & localization

- **English default, professional, global-ready.** No Roman-Urdu UI
  (Inzimam's call 2026-09-30: full Roman Urdu would look local-only and cap
  the ceiling).
- **Complete the Urdu (اردو) translation** — the setting exists, ~15 strings
  are translated, the rest fall back to English. v1.1 ships full Urdu.
- Local flavor where it charms: category presets (Bijli, Rickshaw…),
  "Udhaar" as the ledger's brand name.

## 11. Free vs Pro + monetization (ratified 2026-09-30)

**Free forever (the magic — unlimited):** manual capture, SMS/notification
capture, Udhaar ledger + repayments, Home dashboard, review queue, statement
import (CSV/Excel/text), share/OCR capture, voice notes, Urdu + themes…

wait — themes: decided Pro earlier ("themes" listed under Pro in chat).
Correction: **light/dark/system stays free**; *accent color themes* → Pro.

**Pro — one-time ~Rs 500–1,000 (final price at launch):** app lock, automatic
backup, statement-of-account + CSV export, custom categories, accent themes.

Rules:

- Nobody hits a paywall while falling in love with the app. Pro is power
  tools for month three, not week one.
- **No ad SDK. No tracking. No backend.** (Monetization research 2026-09-30:
  AdMob voids the privacy claim; Pakistan eCPMs too weak to justify it.)
- **Billing plumbing from day one, switch off until retention validates:**
  integrate `in_app_purchase`, one-time non-consumable `yaad_pro`; gate with
  a remote-config-free local flag. Enable post-launch when retention signals
  are healthy (Inzimam decides the moment).
- **Grandfathering:** app lock is free in build-13. Existing installs keep it
  free (local flag set on first run of v1.1 if app lock was ever enabled).
  Play policy forbids bait-and-switch; this keeps us clean.
- **About screen reword:** "Free forever" → "Free forever for the essentials.
  No ads, no tracking — your data never leaves this phone." (Current text
  promises "Free forever" unconditionally; Pro must not contradict it.)

## 12. Data migration (v1.0 → v1.1)

- Add `kind` column to transactions; migrate: purpose in
  {loan, repaymentIn…} + direction → `lendOut`/`repayIn`/etc.; everything
  else → `spend`/`receive` by direction.
- Recompute nothing else; sums change automatically via the §2 rules.
- Grandfather flags: `pro_grandfathered_app_lock`, `billing_enabled=false`.

## 13. Testing

- `flutter analyze` clean (non-negotiable, as before).
- Unit/widget tests for: §2 money rules (lending excluded from spend),
  Udhaar balance math incl. partial repayments, SMS parsers, importer dedupe,
  migration.
- Manual device pass by Inzimam on the release APK (WhatsApp feedback loop,
  as with build-13): capture flows, Udhaar flows, OCR, voice, import, Urdu.
- CI (existing workflow) builds + releases on push to main.

## 14. Release sequence

1. Inzimam approves this plan ("go").
2. Implement on a `v1.1` branch; local analyze + tests green.
3. PR → main → CI builds → GitHub Release APK for device testing.
4. Feedback loop → fixes → release candidate.
5. **Play Store: separate explicit approval + Inzimam's own developer account
   ($25).** Not started without both.

## 15. Open questions (for Inzimam, any time)

1. Bank share-sheet: what did you expect that didn't happen ("works somewhat")?
2. Pro price: Rs 500 vs 1,000 at launch (decide at launch, not now).
3. Accent color direction for the new identity (I'll propose 2–3 options
   visually during build).
