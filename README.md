# Insulin Tracker

A dead-simple Apple Watch app for logging carbs and insulin as a Type 1 diabetic,
plus a read-only history view on iPhone. Built with SwiftUI + SwiftData.
No cloud, no accounts — data stays on your devices.

## How it works

**On the Watch Ultra:**

1. Press the **Action Button** (configured to open this app — see below).
2. Turn the **Digital Crown**:
   - **Up** → first the five meal sizes (**Snack, Small, Medium, Large, Very large**),
     then exact **carbs in grams** if you know the number
   - **Down** → first rapid-acting **insulin** in **0.5 U** steps up to 20 U,
     then long-acting **basal** insulin restarting at 1 U in **1 U** steps up to 60 U
3. Stop turning. After **3 seconds** the value auto-saves with the current
   date & time, you get a checkmark + haptic, and it returns to the neutral screen.
4. If you never turn the crown, **nothing is saved** — just drop your wrist.

Meal sizes carry **no gram amount** — they're stored as a size, not a guess, for the
common case where you don't know the carb count.

The **neutral screen** shows live **insulin on board**, **units active right now**,
and a ticking **time since last bolus**. That's what you see first, before you turn
the crown.

> One value per session (the dial is either food *or* insulin). To log both,
> press the Action Button again for a second entry.

**On the iPhone:** open the app to see all entries, newest first, grouped by day.
Entries logged on the watch sync over the local WatchConnectivity link (Bluetooth/
Wi-Fi, no internet) — usually within a few seconds when the phone is nearby.

## Project layout

```
Shared/            LogEntry (SwiftData model) + WatchConnectivity manager
                   + InsulinMath (IOB / activity curve) + CarbRatio + InsulinStats
                   + DailySeries + SharedStore (App Group)
WatchApp/          Watch app: the crown dial + auto-save (DialView.swift)
iOSApp/            iPhone app: read-only history list
project.yml        XcodeGen spec — the .xcodeproj is generated, not committed
Config.xcconfig    ← EDIT THIS: team id + bundle ids
fastlane/          match signing + build + TestFlight upload
.github/workflows/ CI: setup-signing (run once) + deploy to TestFlight
scripts/make_icon.py  Generates the placeholder app icon
```

You never need a Mac — GitHub's macOS runners build everything.

---

## One-time setup

### 1. Edit `Config.xcconfig`

Set your three values:

```
DEVELOPMENT_TEAM     = ABCDE12345          # App Store Connect → Membership → Team ID
IOS_APP_BUNDLE_ID    = com.yourname.insulintracker
WATCH_APP_BUNDLE_ID  = com.yourname.insulintracker.watchkitapp
```

### 2. Register the App IDs and create the app record

In the [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list),
register **both** bundle ids as App IDs (Identifiers → +).

In [App Store Connect](https://appstoreconnect.apple.com/apps), create a **new app**
using the **iOS** bundle id (the watch app ships embedded inside it).

### 3. Create an App Store Connect API key

App Store Connect → **Users and Access → Integrations → App Store Connect API →
Team Keys → +**. Give it the **Admin** role — this is required so `fastlane match`
can create the distribution certificate. Download the `AuthKey_XXXX.p8` (you can only
download it once). Note the **Key ID** and **Issuer ID**.

Base64-encode the key for the secret:

```bash
base64 -i AuthKey_XXXX.p8 | tr -d '\n'
```

### 4. Add GitHub **secrets** and **variables**

In your app repo → **Settings → Secrets and variables → Actions**.

**Secrets** (Secrets tab):

| Name | Value |
|------|-------|
| `ASC_KEY_ID` | API Key ID from step 3 |
| `ASC_ISSUER_ID` | Issuer ID from step 3 |
| `ASC_KEY_CONTENT` | base64 of the `.p8` (step 3) |
| `MATCH_PASSWORD` | any passphrase — encrypts the signing assets stored on the `certs` branch |

**Variables** (Variables tab — must match `Config.xcconfig`):

| Name | Value |
|------|-------|
| `DEVELOPMENT_TEAM` | your Team ID |
| `APP_IDENTIFIER_IOS` | your iOS bundle id |
| `APP_IDENTIFIER_WATCH` | your watch bundle id |

> **Signing model:** `fastlane match` generates the distribution certificate + App
> Store profiles once and stores them **encrypted on a `certs` branch of this repo**
> (no second repo, no PAT — it authenticates with the built-in `GITHUB_TOKEN`).
> Cloud/automatic signing does **not** work reliably on throwaway CI runners, which
> is why match is used.

### 5. Bootstrap signing (run once)

**Actions → "Set up signing (run once)" → Run workflow.** This creates the cert +
profiles and pushes them to the `certs` branch. You only rerun this if the cert is
revoked or expires.

### 6. Ship it

Push to `main` (or **Actions → "Deploy to TestFlight" → Run workflow**). The build
lands in TestFlight in ~10–20 min after Apple finishes processing. Install via the
**TestFlight** app on your iPhone; the watch app installs from the iPhone's Watch app.

> **Apple caps uploads per app per day.** Hit it and every build fails at the last
> step — archiving and signing succeed, then `upload_to_testflight` returns
> `Validation failed (409) Upload limit reached`, for a full day. Since each push
> to `main` deploys, a run of small commits burns through it fast. Put
> **`[skip deploy]`** in a commit message to land work without spending an upload,
> and leave it off the last commit of a batch.

### 7. Assign the Action Button (on the watch)

On the Watch Ultra: **Settings → Action Button → Action → Open App → Insulin**.
Now a single press of the Action Button from anywhere opens straight to the dial.

---

## Insulin on board

The complication and the watch's neutral screen show two numbers, both computed
from **Table 7-8 of Gary Scheiner's *Think Like a Pancreas*** — the standard
action profile for rapid-acting insulin (NovoRapid / Humalog / Apidra):

| hours since bolus | 0.5 | 1 | 1.5 | 2 | 2.5 | 3 | 3.5 | 4 |
|---|---|---|---|---|---|---|---|---|
| insulin used up | 10% | 30% | 50% | 65% | 80% | 90% | 95% | 100% |
| **still working (IOB)** | 90% | 70% | 50% | 35% | 20% | 10% | 5% | 0% |

- **U on board** — every bolus from the last four hours, decayed along that curve
  and **summed**, so stacked doses are visible rather than just the latest one.
- **U active** — insulin *intensity*: the table's own consumption rate per
  interval, normalised so a dose at its peak reads its full size. 1 U injected an
  hour ago reads ≈ 1.0 U active; at 3 h ≈ 0.38; from 4 h on, zero.

**Basal insulin is excluded from both** — long-acting insulin has a completely
different action profile that this curve does not describe.

### The iPhone forecast chart

The History screen carries a live **"Insulin activity"** chart of how many units
are working at each moment, with stacked doses summed into one curve. It
disappears on its own once the last dose runs out.

It **scrolls in both directions**. The visible window is a fixed 4 hours wide and
5 units tall — the same scales as the complication — so the curve's shape means
the same thing wherever it is scrolled to. The plot extends four hours either
side of now, so the elapsed part of the curve can be scrolled back into, and a
dashed rule marks the boundary. Zero is the floor of the vertical domain, so it
cannot be scrolled below. Vertical scrolling only engages when a peak actually
exceeds 5 U.

The headline figure above the chart is **insulin on board**; the curve itself is
activity.

That chart uses the **biexponential model** used by OpenAPS / Loop / AndroidAPS
rather than the table above:

```
τ = tp·(1 − tp/td) / (1 − 2·tp/td)        Ia(t) = (S/τ²)·t·(1 − t/td)·e^(−t/τ)
```

with peak `tp` = 75 min (the OpenAPS rapid-acting default) and duration `td` = 4 h
(held equal to `InsulinMath.duration` so the chart agrees with the IOB figures;
OpenAPS's own default is 5 h — see `exponentialDuration`).

### Which curve is used where

| Quantity | Curve | Shown on |
|---|---|---|
| **Insulin on board** | Table 7-8 | complication (top right), watch neutral screen |
| **Activity / intensity** | exponential | complication chart, watch neutral screen, iPhone chart |

Every *activity* readout uses the exponential model so the three surfaces can't
contradict each other; IOB stays on the book's table. `InsulinMath.activity()`
still implements the Table-7-8-derived activity curve and is kept for reference —
swap it back in if you prefer the book's own numbers.

> Run at a 4 h duration the exponential model reproduces Table 7-8's IOB to
> within 2–4 percentage points, but it holds nearer the peak for longer —
> ≈0.98 vs 0.88 at 1.5 h.

### The complication

`.accessoryRectangular`, given over entirely to the 4-hour activity forecast, with
**IOB overlaid in the top-right corner** and the ticking time-since-last-bolus
smaller underneath it. That corner is free by construction: no bolus on board is
more than 4 h old, so the curve has always decayed to zero by the right edge of
the window — nothing can ever be drawn there.

The timer's point size is **fixed**, calibrated so `9:00:00` is exactly as wide as
the IOB line reads at `8 U IOB`. It is measured from live font metrics rather than
hardcoded, so it holds across watch sizes and Dynamic Type — and deliberately
carries no `minimumScaleFactor`, which would otherwise resize the text the moment
the elapsed time ticked past an hour.

The axes are **fixed** — 0–5 U vertically, 4 hours horizontally — so the curve's
height and slope mean the same thing at every glance instead of being rescaled by
whatever happens to be on board. A combined peak above 5 U flattens against the
top of the plot; the IOB figure stays exact. Widen `unitsCeiling` in
`WidgetExtension/LastDoseWidget.swift` if you routinely stack past 5 U.

> Duration of insulin action varies per person (the book notes anywhere from
> under 3 h to 5–6 h). The 4 h curve here is the book's typical case. To change
> it, edit the table in `Shared/InsulinMath.swift`.

## Carb ratio

A running 28-day insulin-to-carb ratio, measured from **what actually happened
after each meal** — no rules of thumb.

For every meal logged in **grams** with a bolus in the hour before it, glucose is
read at the meal and again four hours later. The miss is converted into the
insulin that was missing, which gives the ratio that *would* have landed flat:

```
ideal units = units given + (glucose end − glucose start) / ISF
ratio       = carbs / ideal units
```

That needs ISF — how far one unit moves you — so it is **measured, not assumed**,
from *correction boluses*: insulin taken with no food within four hours, where
the whole glucose fall is the dose's doing.

A correction does not need a clean four hours, either — a morning correction
followed by breakfast still has a clean couple of hours in it. The window is
truncated at whatever comes next, and the drop is scaled by how much of the dose
had acted by then, using the same action curve as the rest of the app. Requiring
four undisturbed hours would discard most real corrections.

Identifying those corrections can't rely on the log, though. Unlogged meals are
the premise of this whole feature, and an unlogged meal plus its bolus looks
exactly like a correction — it would drag ISF down and distort every ratio built
on it. **The CGM curve is the arbiter instead**, since it doesn't depend on
anyone remembering anything: carbohydrate absorbing pushes glucose *above* where
it started, and a dose acting alone never does. Any window containing a rise of
more than 10% above the starting value is discarded, logged or not. The
threshold is a fraction rather than an absolute so it holds in mmol/L and mg/dL
alike.

That check only starts **90 minutes after the dose**. Insulin takes 15–20 minutes
to bite and people correct when they are high *and climbing*, so glucose rising
straight after a correction is the normal case, not evidence of food.

A correction also has to move at least 8% and be at least 0.5 U, or the division
is dominated by sensor noise.

Results are split six ways, because both dimensions genuinely change the answer
and the book notes most people need their lowest ratio in the morning:

|  | No exercise | With exercise |
|---|---|---|
| **Morning** 04–11 | ● | ● |
| **Lunch** 11–17 | ● | ● |
| **Dinner** 17–04 | ● | ● |

Each cell is the **median** over its meals, so one mis-logged meal can't drag it.
A cell with fewer than 3 meals shows its count instead of a number, and every
rejected meal is listed with the reason.

A meal is used only if it has carbs in grams, exactly one bolus in the hour
before (or moments after — the watch logs dose and meal seconds apart), no other
insulin or food within 4 h, and glucose either side. Meals logged by size carry
no gram figure and are never assigned a guessed one.

> The window is 28 days. Six cells — three dayparts × exercise or not — leave a
> seven-day window with almost nothing in the exercise column.

> The unlogged-food filter protects the ISF measurement, not the meals
> themselves. An unlogged snack *during* a meal's four-hour window still
> distorts that meal — it looks like the meal ran high, so the ratio reads
> tighter than it is. The median across meals limits the damage; it does not
> eliminate it.

> This describes what already happened. It is not a dose recommendation.

## Averages

Glucose and insulin over **3, 7, 30 and 90 days**, side by side, so a change in
sensitivity shows up as a column that no longer matches the ones beside it.

Six rows, one column per window:

| Row | What it is |
|---|---|
| **Glucose** | mean of the CGM readings in the window |
| **SD** | sample standard deviation (n − 1) of the same readings |
| **Basal** | long-acting units per day |
| **Bolus** | rapid-acting units per day |
| **Total** | the two added |
| **Insulin ÷ glucose** | total daily units per unit of glucose |

Every window **ends at the newest glucose reading**, not at the clock. Dexcom
uploads to Health in batches, so "now" is routinely an hour ahead of the last
sample, and anchoring on the clock would leave each window with a ragged empty
tail that moves the averages for no reason.

The bottom row is the point of it: **what a given glucose level costs in
insulin**. Holding diet roughly constant, it rises when the same result takes
more units — so it goes **up as sensitivity goes down**. It is a resistance
index, not a sensitivity one. Its size also depends on whether Health is set to
mmol/L or mg/dL, so it compares across your own windows and across time, never
against anyone else's number.

Per-day figures are divided by **elapsed time**, not by a count of days with
entries. A window ends mid-afternoon: it holds the tail of its first day and the
head of its last, which together make one day but touch two, and counting dates
would divide three days of doses by four of them.

Anything that makes a column mean less than it looks like it means is said on
the card rather than left to be noticed:

- **The log is shorter than the window.** Per-day figures are divided by how far
  it actually reaches, so a fortnight of logging does not read as a third of the
  insulin in the 90-day column. Those windows say how many days they have.
- **The CGM was offline.** Coverage is measured from the gaps between readings
  rather than from an assumed sample rate, so a warm-up or a lost transmitter
  reads as missing time. Below 80% the card says so — a mean over a third of a
  window is a mean of that third.
- **Days with no basal on them.** A missed log and a missed injection are
  indistinguishable from here, and either way those days divide the average
  without contributing to it. Five forgotten days in thirty take a sixth off the
  total and off the index with it, which is the largest error here in practice.
- **No basal at all.** Basal is usually the larger half of the day, so this does
  not make the total slightly low — it makes it wrong.

> This describes what already happened. It is not a dose recommendation.

## Trends

Five charts stacked on one shared time axis, day by day over three months.
Drag any of them and all five scroll together, so a day lines up down the
screen. Reached from the chart button in the history toolbar.

| Chart | |
|---|---|
| **Average glucose** | mean of that day's CGM readings |
| **Total insulin** | units, with basal and bolus drawn as separate parts of the bar |
| **Insulin ÷ glucose** | that day's total insulin per unit of glucose |
| **Exercise calories** | active energy from Health, with the workout part drawn darker |
| **Weight** | plotted only on days it was actually recorded |

Stacked rather than overlaid: the five share no scale, and small multiples on a
common axis are the honest way to read one against another. A training block and
the notch it puts in insulin a day later line up vertically without pretending
kilocalories and millimoles belong on the same y-axis.

This is the counterpart to **Averages**, not a duplicate of it. That one smooths
a trend out of the noise; this one keeps every day intact so the noise is
visible. A day the basal never got logged should show up as a notch here, not be
quietly folded into a thirty-day mean.

**Exercise calories are active energy, not workout energy.** The book counts
"cleaning, shopping, playing, yard work, sex, and anything else that has us
using our muscles" as physical activity, and all of it moves insulin
sensitivity — so the bar is the whole day's movement, with the part spent inside
a logged workout drawn darker. Deliberate training and everything else, without
having to choose between them. To plot workouts only, use the darker series
alone in `iOSApp/TrendsView.swift`.

Two rules keep a chart from claiming more than it knows:

- **A day needs CGM for at least half of it** before its average is plotted.
  Glucose has a strong daily shape, so a mean over a third of a day is not a
  noisy version of that day's average — it is an average of whichever third the
  sensor was awake for, which is a different quantity.
- **Weight is drawn with dots as well as a line.** People weigh themselves when
  they remember to, and the line between two readings a week apart is
  interpolation, not measurement. The dots say which days were actually stood on.

Day length is asked of the calendar rather than assumed to be 86,400 seconds, so
the twenty-five-hour and twenty-three-hour days at each clock change are not
scored as short of readings.

> A single day of the index is noisy — one late dinner moves it. It is there to
> be read as a shape over weeks, not day to day.

## Apple Health

The iPhone app reads four things from Health, and writes nothing back:

- **Workouts** — shown in the history list, and drawn as shaded bands behind the
  insulin activity chart so you can see where exercise overlapped insulin that
  was still working.
- **Glucose** — written to Health by the Dexcom G7 app, shown as its own card
  with the latest reading and a trend line.
- **Active energy** — the day's movement, charted in **Trends**. Read as a daily
  statistics collection rather than as raw samples: the watch writes energy in
  small, frequent increments, so three months of them is tens of thousands of
  rows to produce ninety numbers.
- **Body mass** — charted in **Trends**, in whatever unit Health is set to.

Neither is copied into SwiftData. Health stays the source of truth, which avoids
reconciling against samples the Fitness or Dexcom apps may revise later.

> **Exercise does not change the IOB or activity figures.** It genuinely changes
> insulin sensitivity, but by an amount this app has no way to know, so it is
> shown as context rather than folded into the maths.

> **Glucose here can lag the sensor.** Dexcom uploads to Health in batches, not
> continuously. The card shows the age of the reading, and marks it when it is
> more than 15 minutes old.

Glucose is displayed in whatever unit Health is set to — `preferredUnits(for:)`
decides, so mmol/L and mg/dL both work with no setting of our own.

### One-time setup

HealthKit needs the capability enabled on the App ID before it will sign:

1. [Developer portal → Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   → your iOS bundle id → tick **HealthKit** → Save.
2. **Actions → "Set up signing (run once)" → Run workflow**, so `match`
   regenerates profiles that carry the new entitlement.

Skipping either makes every build fail at the signing step — `match` regenerates
profiles but cannot enable capabilities.

Both HealthKit purpose strings are required in `iOSApp/Info.plist`, including
`NSHealthUpdateUsageDescription`, even though this app never writes to Health.
App Store validation keys off the entitlement, not off which APIs are called, and
rejects the upload with `Missing purpose string in Info.plist` if the write one is
absent. That failure appears only at upload, after archiving and signing succeed.

## Notes & limitations

- **Auto-close:** watchOS apps can't quit themselves programmatically (App Store
  disallows it). "Do nothing" simply saves nothing; dropping your wrist backgrounds
  the app. Reopening always starts fresh at the neutral screen.
- **Ranges:** carbs use a ladder that coarsens as the number grows (1–10 by 1,
  then 15/20/25/30, then by 10 up to 200 g, then by 25 up to 500 g); bolus insulin
  is 0.5–20 U; basal is 1–60 U. Adjust `carbLadder` / `bolusMaxSteps` /
  `basalMaxUnits` in `WatchApp/DialView.swift`.
- **Replace the icon:** drop your own 1024×1024 PNG over
  `iOSApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png` (and the watch one), or
  re-run `python3 scripts/make_icon.py`.
- **Free provisioning** isn't used here — TestFlight requires a paid Developer account
  (which you have), and builds don't expire the way sideloaded ones do.
- **Xcode/SDK:** the deploy workflow uses `latest-stable` Xcode on `macos-15`.
  Apple requires builds to use a current SDK (iOS 26+ as of Aug 2026); if uploads
  start getting rejected for an "SDK version issue", that runner/Xcode is the knob.
- **Export compliance:** `ITSAppUsesNonExemptEncryption=false` is set so builds are
  immediately available to testers (the app uses no non-exempt encryption).
