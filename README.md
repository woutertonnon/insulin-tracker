# Insulin Tracker

A dead-simple Apple Watch app for logging insulin and finger-prick blood sugar
readings as a Type 1 diabetic, plus a read-only history view on iPhone. Built with SwiftUI + SwiftData.
No cloud, no accounts — data stays on your devices, with one exception you
opt into: the coordinate, height and time of a blood sugar reading go to
Open-Meteo so the outside temperature can be looked up for it.

## How it works

**On the Watch Ultra:**

1. Press the **Action Button** (configured to open this app — see below).
2. Turn the **Digital Crown**:
   - **Up** → a **blood sugar** reading from a finger-prick meter, in whatever
     unit Health is set to on the phone — to a tenth of a mmol/L, or a whole
     mg/dL, across the whole range
   - **Down** → first rapid-acting **insulin** in **0.5 U** steps up to 20 U,
     then long-acting **basal** insulin restarting at 1 U in **1 U** steps up to 60 U
3. Stop turning. After **3 seconds** the value auto-saves with the current
   date & time, you get a checkmark + haptic, and it returns to the neutral screen.
4. If you never turn the crown, **nothing is saved** — just drop your wrist.

Readings are **stored in mmol/L** whichever unit they were dialled in, so a
reading survives Health being switched from one unit to the other, and the two
devices — which may hear about a change at different times — never disagree
about what a stored number means. The phone writes Health's unit down and sends
it to the watch over the same local link the log uses.

There is no carbohydrate logging. Earlier versions had it; rows of those kinds
are deleted at launch.

The **neutral screen** shows live **insulin on board**, **units active right now**,
and a ticking **time since last bolus**. That's what you see first, before you turn
the crown.

> One value per session (the dial is either a reading *or* insulin). To log
> both, press the Action Button again for a second entry.

**On the iPhone:** open the app to see all entries, newest first, grouped by day.
Entries logged on the watch sync over the local WatchConnectivity link (Bluetooth/
Wi-Fi, no internet) — usually within a few seconds when the phone is nearby.

## Project layout

```
Shared/            LogEntry (SwiftData model) + WatchConnectivity manager
                   + InsulinMath (IOB / activity curve) + GlucoseUnit + InsulinStats
                   + DailySeries + A1c + SharedStore (App Group) + BasalSchedule
                   + Report (the doctor's report, computed) + InsulinAction
WatchApp/          Watch app: the crown dial + auto-save (DialView.swift)
iOSApp/            iPhone app: history, charts, the basal reminder setting,
                   and the doctor's report as a PDF (ReportView / ReportPDF /
                   ReportPageView)
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

The Action Button only takes a shortcut from your own library, and the library
is built on the iPhone:

1. On the **iPhone**, open **Shortcuts → + → search "Open Insulin"** and add
   that action (it is the app's own). Name the shortcut **Insulin**.
2. Open the shortcut's details (ⓘ) and turn on **Show on Apple Watch**.
3. On the **Watch Ultra**: **Settings → Action Button → Action → Shortcut →
   Insulin**.

Now a single press of the Action Button from anywhere opens straight to the
dial — and a second press, with a reading on screen, flips its inside /
outside badge (see **Blood sugar readings**).

> The **Shortcut**, not **Open App**. Set to Open App, the button only launches
> the app and a second press hands it nothing. Set to the shortcut, every press
> runs the app's intent, which is what the badge listens for. The intent is
> compiled into both apps under one name so the iPhone can offer the action
> and the watch can run it locally; the app's built-in shortcut, visible in
> the watch's Shortcuts app, cannot itself be assigned to the button.

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

It has one other state: when the basal reminder is due it drops all of the
above and reads **BASAL!** — see below.

## Basal reminder

A standard time for the long-acting injection. When it arrives, the
complication stops showing insulin on board and shows **BASAL!** instead, at
three times the type size of anything that was there a moment before.

Basal is the one dose nothing else in the day reminds you of. A bolus has a meal
attached to it; a missed basal announces itself only hours later, by which point
the evidence is indistinguishable from a bad day. It is also the largest single
error in everything else here — see **Averages**, where a day with no basal on
it divides an average without contributing to it.

Set it on the iPhone: the **gear** in the history toolbar. The watch is told
over the same local link the log uses and keeps its own copy, so the reminder
fires with the phone nowhere near.

> **Not a notification, deliberately.** A notification is cleared by the same
> reflex that clears every other notification, and what is wanted here is
> something that is simply *there* the next time the wrist goes up. So the
> complication gives itself over to it instead.

Type size does the work, not colour. Watch faces re-render complications in
whatever mode the face is in — full colour, accented, flat — so a bright fill
is not something the widget can count on, while a word filling the whole
complication reads the same in every mode, dimmed always-on included.

### What makes it stop

Two things, whichever comes first:

- **Logging basal.** Any basal entry clears it — from the watch dial, or added
  on the phone. Logged up to **three hours early** still counts, so an early
  dose is not asked for twice. That allowance is generous on purpose: being
  prompted for long-acting insulin you have already taken is the only failure
  mode here with a real consequence.
- **Two hours.** Then it gives up, logged or not. The alert replaces the *whole*
  complication, so a version that waited indefinitely would destroy the IOB
  readout for the rest of any day the injection was taken but not logged — and
  a complication that always says BASAL! is not a signal, it is wallpaper.

Deleting today's basal on the phone puts the reminder back, if the two hours
have not run out.

The scheduled time is shown small under the word. That matters on the evening
the dose was taken early and the alert fired anyway: seeing `due 22:00` is what
tells you the app disagrees about today, rather than that you have forgotten
something.

### Landing on the minute

WidgetKit renders a complication only at the dates its timeline gives it, and it
budgets timeline *refreshes* per day — ask too often and requests get dropped
rather than served. So the instants the alert turns on and off are **baked into
the timeline** a day ahead, as entries of their own alongside the five-minute
IOB samples. The flip happens at the scheduled minute with no refresh needed.

Clearing works the other way round: logging a dose *asks* for a reload, and
watchOS can decline. Worst case the word lingers until the next scheduled
rebuild — bounded by the same **30 minutes** that bounds complication staleness
everywhere else.

The setting is stored as a time of day (minutes after midnight), not as a date,
so it follows the wall clock through a time zone change or a clock change. Ten
o'clock stays ten o'clock.

> **It only works if you look at your watch.** No sound, no haptic, no
> notification. If the wrist never comes up between the scheduled time and two
> hours later, nothing has told you anything.

> Set on the phone rather than the watch because the watch app is one crown
> dial with no navigation in it, and a settings screen behind that dial would
> be a gesture that could be hit on the way to logging a dose.

## Blood sugar readings

Finger-prick readings live in the same log as the doses, logged from the
watch dial or added on the phone, and are drawn as **dots on the glucose card**
over the CGM line, so a meter check sits on the chart beside the sensor it was
checking. They feed none of the maths — every average, chart and estimate is
built from the CGM, which has a reading every five minutes where a meter has a
handful a day. They are listed in the doctor's report appendix.

### Outside temperature

A meter has no thermometer. Its strip's enzyme runs slower in the cold and
faster in the heat, and the meter converts the current it sees as if the strip
were at room temperature — so a reading taken outside in winter comes out low,
and one in a heatwave comes out high. Every reading is therefore stamped with
the **outside air temperature** where it was taken, and shown beside an
**adjusted** value, following [*Riding the Glucose Trail*, "BG &
temperatures"](https://ridingtheglucosetrail.com/p/bg-temperatures/):

```
adjusted = reading − 0.0928 mmol/L per °C × (T − 22.5 °C)
```

At 0 °C a reading of 5 mmol/L adjusts to about 7; at 40 °C, to about 3.4 —
the article's own two examples. (The article prints its mmol/L shortcut with
the sign the other way round, which contradicts both its model and both
examples; the model and the examples are followed.) It is one person's Contour
Next One, fitted mostly between 0 and 15 °C; another meter or batch of strips
will sit off it, and a reading taken from a warm pocket moments after coming
in is not at the outside temperature at all. The adjusted figure is shown
**beside** the reading, never in place of it, and nothing else in the app uses
it. The article also subtracts half a mmol/L as a safety margin; that is left
to the reader.

**The watch needs no network for this.** It records only where, how high and
when — a location fix, asked for the moment the crown enters the reading
region so it is usually in hand three seconds later when the reading saves.
Outside, away from Wi‑Fi, GPS can take a minute; a reading saved without a fix
keeps location running in the background, with the wrist down, until a good
fix lands or two minutes pass, then stops. A fix that lands is attached then
and the entry sent again, and any fix within a quarter hour stamps readings
that still went without. A reading with none shows "no location" in the
history. The phone, whenever it next runs with a connection, asks
[**Open-Meteo**](https://open-meteo.com) for that hour's air temperature at
that spot and writes it onto the entry. The last 92 days come from its
forecast endpoint, anything older from its archive. A dozen lookups at a time,
no more often than every quarter hour unless a reading has just arrived; the
free allowance is ten thousand a day. A reading still waiting shows a
thermometer in the history.

**Open-Meteo rather than WeatherKit, because of mountains.** WeatherKit takes a
coordinate only and returns the temperature at its model's own terrain height
for a grid cell a few kilometres across; on a mountainside that can be a
thousand metres below the wrist, which by the standard lapse rate is some 6 °C
warmer than the air actually around the meter. Open-Meteo takes an
**elevation** and downscales to it — the fix's altitude when the reading has
one, its own 90-metre elevation model at that coordinate when it does not. It
also needs no entitlement, no App Service and no signing step, and no key for
a non-commercial app. The coordinate, height and time go to a third party
rather than to Apple, and Open-Meteo says request coordinates may sit in its
server logs for up to 90 days. Weather data by Open-Meteo.com, CC BY 4.0.

**Indoors, none of this applies.** The effect is the strip's temperature, and
a strip indoors is at room temperature whatever the weather — so the
adjustment is shown only for readings taken outside, and the app has to
decide which those are. The indoor error is small in the article's own terms:
a room at 28 °C or 19 °C is half a mmol/L off the meter's assumed 22.5 °C,
inside the meter's own accuracy band; 0 °C is two mmol/L. So the reading on
the watch carries an **inside / outside badge**, and the adjustment follows
it.

The badge starts at what the wrist can tell on its own, offline: the motion
coprocessor's record of the last quarter hour. **Cycling or running means
outside**, whether or not a workout was recorded. Walking and standing still
say nothing, and the badge then starts at inside. To flip it, without
touching the screen — gloves, rain, a meter in the other hand:

- **Press the Action Button again.** Assigned to the app's Shortcut (setup
  step 7), every press runs the app's intent: the first opens the dial, the
  next, with a reading on screen, flips the badge. A press with a dose on
  screen does nothing. The three-second save timer restarts on a flip so the
  result can be seen.
- **Double Tap** — index finger and thumb, twice — on an Ultra 2 or Series 9
  and later, where the badge is the app's primary action.
- Or tap the badge, if a finger is free.

The checkmark screen keeps the badge too, and a flip there rewrites the
reading just saved and holds the screen a little longer — for the glance that
comes a moment too late.

**What the badge shows when the reading saves is the truth**, flipped or
let stand: the person saw it. It is stored with the reading, the phone never
recomputes it, and the switch in the phone's editor is the only thing that
changes it afterwards. Everything below decides only where the badge
**starts**, in order of how much each witness knows:

1. **The place.** Every flip is a lesson about where it was made. A reading
   within 150 metres of a spot flipped to inside at least three times more
   often than outside starts at inside, whatever else is going on — the
   kitchen at the end of a ride is still the kitchen. Three, not one: one
   flip is a flip. Only flips teach: a starting position merely let stand
   does not, so three mornings at the kitchen table do not by themselves
   make a place. Outside flips at the same spot count against, so a garden
   that keeps being flipped the other way does not become the house. Nothing
   is stored beyond the readings themselves, so the watch and the phone learn
   the same places from the same log.
2. **Health's workouts**, which know their kind and whether they were indoors,
   for a reading typed on the phone. A reading during one, or in the quarter
   hour after it ends while the meter is still cold from the pocket, goes
   with it. The Workout app says outright for the kinds that come in both
   flavours — Indoor Cycle against Outdoor Cycle, a treadmill against the
   road — and swims say pool or open water. Otherwise the kind decides:
   hiking, paddling, sailing, surfing, the snow sports, golf, fishing,
   hunting, riding, and the field sports are outside; the gym, the court, the
   rink and everything else that might be either are treated as inside. The
   watch does not have Health's workouts, so on the wrist a hike starts at
   inside and is one press away.
3. **The wrist**, which saw cycling or running just before.

With none of them, indoors. The phone's editor has a **Taken outdoors**
switch for the reading whose badge was wrong after all; what it is set to is
final, and a switch moved by hand teaches a place like a flip does. The
temperature is looked up for every stamped reading regardless, so flipping
either switch shows it at once.

Readings added by hand on the phone carry no location and get no temperature.

**Altitude comes from the barometer** where the watch has one, which gives
absolute altitude to a few metres in a second or two; a watch without one
uses the fix's GPS height, good to a few tens of metres, and stores nothing
when the fix cannot vouch for it. Either is nothing against a lapse rate of
6.5 °C per thousand. With no altitude the lookup falls back to the elevation
model.

**Altitude comes from the barometer** where the watch has one, which gives
absolute altitude to a few metres in a second or two; a watch without one
uses the fix's GPS height, good to a few tens of metres, and stores nothing
when the fix cannot vouch for it. Either is nothing against a lapse rate of
6.5 °C per thousand. With no altitude the lookup falls back to the elevation
model.

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

Six charts stacked on one shared time axis, day by day over three months.
Reached from the chart button in the history toolbar.

Three pieces of state are shared by every chart, which is the whole trick:

- **Drag** to scroll,
- **pinch** to zoom the time axis, between three days and the full range,
- **tap** to pick a day — a dashed rule lands on it in all six charts, and each
  one's readout switches from its latest value to that day's.

All six follow, so a day stays lined up down the screen.

Every chart also carries its **90-day average**, as a dashed line across the plot
and as a muted figure beside its title. It is the mean of the days plotted, so a
day with nothing logged neither raises nor lowers it — which is why it can differ
slightly from the same window on the **Averages** card, which divides by elapsed
time instead. A selected day with
nothing to show reads as a dash rather than falling back to the latest value,
which would answer a question about one day with a number from another.

| Chart | |
|---|---|
| **Average glucose** | mean of that day's CGM readings |
| **Total insulin** | units, with basal and bolus drawn as separate parts of the bar |
| **Insulin ÷ glucose** | that day's total insulin per unit of glucose |
| **Exercise calories** | active energy from Health, with the workout part drawn darker |
| **Weight** | plotted only on days it was actually recorded |
| **Estimated A1c** | that day's mean glucose through the ADAG formula |

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

**Weight is the one chart not scaled from zero.** It gets its own range plus
three kilograms either side, because on a zero-based axis two kilos of real
drift is a flat line. The pad is converted through `HKQuantity`, so pounds and
stones get a band of the same physical size rather than the same number.

Marks sit at the middle of their day rather than at midnight. A bar binned by
day spans midnight to midnight, so a line plotted at midnight would run through
its left edge and the selection rule could only ever agree with one of them.

Day length is asked of the calendar rather than assumed to be 86,400 seconds, so
the twenty-five-hour and twenty-three-hour days at each clock change are not
scored as short of readings.

### Estimated A1c

From the **ADAG** study's regression (Nathan et al., 2008), read backwards —
the app has the glucose and wants the A1c:

```
eAG (mg/dL)  = 28.7 × A1c − 46.7      →   A1c = (eAG + 46.7) / 28.7
eAG (mmol/L) = 1.59 × A1c −  2.59     →   A1c = (eAG +  2.59) / 1.59
```

Applied **per day**, which answers a question worth asking: *if every day looked
like this one, what would the A1c be?* On those terms it is a straight rescaling
of the glucose chart — the formula is linear, so the two curves have the same
shape — and it earns its place by being in the units a target is held in, not by
carrying information the glucose chart lacks.

> **It is not a prediction of a lab result.** Haemoglobin carries its glycation
> for the life of the red cell, so a real A1c answers for the previous three
> months, weighted towards the recent end. A single day cannot say what a blood
> test will. Read the level, not the point.

Two further limits: ADAG fitted a straight line to a population, and individuals
sit off it — red-cell lifespan varies, so the same mean glucose genuinely gives
different people different A1cs. And CGM software more often reports **GMI**
(Bergenstal, 2018), a different fit over a fourteen-day window, which is why an
app's number and this one can disagree by a few tenths.

On this chart the dashed 90-day average is worth more than the daily points.
The ADAG formula is affine, so the mean of the daily estimates equals the
estimate from the 90-day mean glucose **exactly** — that line is the closest
thing the app produces to a real A1c, and it comes free from plotting the days.

`A1c.millimolesPerMole` converts to the IFCC form for labs that report mmol/mol.

No target line is drawn. A1c targets are individual — looser with hypo
unawareness, in older age, in pregnancy — and a line across this chart would be
the app asserting a goal it has no basis for.

> A single day of the index is noisy — one late dinner moves it. It is there to
> be read as a shape over weeks, not day to day.

## Doctor's report

A PDF of the last 14, 30 or 90 whole days, laid out the way a clinic already
reads glucose data, with the things a CGM report cannot know set beside it.
Reached from the **document** button in the history toolbar; the share button
on that screen hands it to AirDrop, Mail, print, or Files.

It is modelled on the **Ambulatory Glucose Profile** (AGP), because that is
the form every diabetes clinic reads CGM in, and a report in a familiar shape
is read rather than deciphered. It carries **titles, labels, values, legends
and numbered references, and no prose** — the reader knows what time in range
is, and every sentence would sit between them and the number. Anything a
caveat would have said is a label with a value ("Days logged: 84 of 90");
anything a method note would have said is a reference, listed on the last
page in the form `[1] …`.

Pages, in order:

1. **Summary.** Mean glucose, GMI, estimated A1c, SD, CV and CGM coverage as
   tiles; **time in range** as the AGP's stacked bar and a table of the five
   consensus bands with percentages, hours per day and goals; the **daily
   profile** — every reading in the period folded onto one 24-hour day, with
   the median, the 25–75% band and the 5–95% band per half hour. Then basal,
   bolus, total, bolus share, boluses per day and days logged as tiles, and
   **insulin acting through the day** — see below.
2. **Glucose over time.** Estimated A1c and GMI per day, and mean glucose per
   day. Each chart carries its **14-, 30- and 90-day averages** as `14-day
   average: 7.4 mmol/L` beside its title, whatever period the report covers.
3. **Insulin, activity and weight.** Insulin per day with basal and bolus as
   parts of one bar, active energy per day and weight, together on one page
   so a training block and the notch it puts in insulin line up; the same
   three averages on each. Charts Health has nothing for are left out.
4. **Basal and references.** Days with basal, usual dose, dose range and usual
   time as tiles, and the numbered references.
5. **The day table.** One row per day: CGM coverage, mean, SD, time below, in
   and above range, basal, bolus, total, number of boluses, workout minutes,
   active energy, weight. A dash is a day with nothing recorded.
6. **Every dose, reading and workout** (optional). Each injection, finger-prick
   reading — with the outside temperature and the adjusted value where known —
   and workout in time order, two columns to a page. Off by default.

### Low and high events

Two more reports beside the overview, each its own PDF so it can be sent on
its own: **Lows** and **Highs**, chosen at the top of the report screen, over
the same period. Both are read off the CGM.

- **Low** — below 60 mg/dL (3.3 mmol/L) at any point, or below 70 mg/dL
  (3.9) for 30 minutes or longer.
- **High** — above 180 mg/dL (10.0 mmol/L) for an hour or longer.

The edges are set in mg/dL and converted exactly, so a trace gives the same
events in either unit. An event ends once glucose has been back across the
line for 15 minutes, as in the consensus definition of a CGM event, so one
reading bouncing over the line does not split a low in two; a CGM gap longer
than 20 minutes ends it too, since nothing is known past it.

The first page has the definition, the totals — events, events per week, time
in events, median length, how many began overnight, the lowest or highest —
a legend and the references. Then one panel per event, newest first, three to a page: the
day, start, end and length; the lowest or highest value and when; a chart from
four hours before to an hour after, with the CGM, the threshold lines, the
event shaded, workouts shaded, each dose as a line with its units, and each
finger-prick as a dot with, when it was taken outside, a diamond at its
temperature-adjusted value; and three lines beneath — **insulin** (boluses in
the four hours before through the end, the last basal in the 30 hours before,
and bolus on board at the start), **exercise** (workouts in the six hours
before through the end, since a low can follow exercise by hours), and
**meter** (finger-pricks from an hour before to an hour after, each with the
outside temperature and adjusted value where it was taken outside).

### Insulin acting through the day

The chart on page one that a CGM report cannot have: for a typical day of the
period, how much insulin was acting at each time of day, basal and bolus
stacked. It is in **units per hour** — the rate at which insulin is being used
up — because a rate is the only form in which basal and bolus can be added,
and because it is the unit a pump's basal is prescribed in, so a clinic reads
the basal half without translation. The area under a day's curve is the day's
dose, which ties it to the per-day tiles above it. (The watch's "U active" is a
different, peak-normalised scale; see **Insulin on board**.)

Two standard action profiles, in `Shared/InsulinAction.swift`:

- **NovoRapid (aspart)** — the same exponential curve the forecast chart uses
  (peak 75 min, duration 4 h), rescaled so its area is one rather than its
  peak.
- **Lantus (glargine)** — onset over the first two hours, flat until about
  twenty, gone by twenty-four: the "peakless" profile clamp studies (Lepore et
  al., 2000) and *Think Like a Pancreas* both describe. A smooth trapezoid,
  not a fit; neither source gives it a finer shape.

For every day the log covers, the rate of every logged dose is sampled every
ten minutes — the previous day's doses included, since an evening basal acts
through the next day — and **averaged across days**. A mean rather than a
median, so the area stays the average daily dose: a bolus given at one o'clock
on some days and two on others shows as a wider, lower bump, which is the
truth of it, where a median would lose it altogether.

### The rest of the method

The glucose bands and goals are the **2019 international consensus on time in
range** (Battelino et al.): 3.9–10.0 mmol/L (70–180 mg/dL) in range, below 3.0
(54) very low, above 13.9 (250) very high. They are not configurable — a report
meant to be read against the published targets should use the published edges.

**GMI is on the report and not in the app.** The glucose management indicator
(Bergenstal et al., 2018) is the figure a CGM report carries in place of an
estimated A1c, from a different fit to a different population, which is why it
and the ADAG estimate on the trends chart can disagree by a few tenths. The
report gives both, each with its reference, so the clinic sees the number it
is used to beside the one the patient has been watching.

**Whole days ending yesterday**, deliberately. A report generated at eleven in
the morning should not carry a day with a third of its readings in it, and a
dated range reads more easily across a desk than "the last 90 days from
10:42". Health is queried a day further back than the averages need so that
the 90-day report is complete. The three averaging windows end on the same
day, and the chosen period is one of them, so its figures and that column
agree by construction.

Per-day insulin is divided by the days the log covers, counted from the first
entry ever made — the same rule as the Averages card — so a log that began
mid-period does not read as a period of half doses.

The pages are ordinary SwiftUI views laid out at paper size and drawn through
`ImageRenderer` into a Core Graphics PDF context, so the charts are vectors and
the text is text. Tables are paginated by arithmetic — every row is a fixed
height — rather than by measuring, so nothing can run off the bottom of a
page. Paper is Letter where the locale measures in inches and A4 everywhere
else. Colours are fixed print colours chosen so that each pair that sits side
by side stays apart for colour-blind readers and in greyscale, and every
multi-series chart carries a legend.

> It describes what already happened; it is not a dose recommendation.

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

The watch's motion purpose string (`NSMotionUsageDescription`) has to be in
`iOSApp/Info.plist` as well, though the phone never reads motion: App Store
validation checks the bundle the watch app ships inside, and rejects the
upload with `ITMS-90683: Missing purpose string` without it. The location
string is in both for the same reason.

Both HealthKit purpose strings are required in `iOSApp/Info.plist`, including
`NSHealthUpdateUsageDescription`, even though this app never writes to Health.
App Store validation keys off the entitlement, not off which APIs are called, and
rejects the upload with `Missing purpose string in Info.plist` if the write one is
absent. That failure appears only at upload, after archiving and signing succeed.

## Notes & limitations

- **Auto-close:** watchOS apps can't quit themselves programmatically (App Store
  disallows it). "Do nothing" simply saves nothing; dropping your wrist backgrounds
  the app. Reopening always starts fresh at the neutral screen.
- **Ranges:** blood sugar runs 2.0–30.0 mmol/L by a tenth (40–500 mg/dL by
  one) — see `dialLadder` in `Shared/GlucoseUnit.swift`; bolus insulin is
  0.5–20 U; basal is 1–60 U.
  Adjust `bolusMaxSteps` / `basalMaxUnits` in `WatchApp/DialView.swift`.
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
