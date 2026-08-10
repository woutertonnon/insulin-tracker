# Insulin Tracker

A dead-simple Apple Watch app for logging carbs and insulin as a Type 1 diabetic,
plus a read-only history view on iPhone. Built with SwiftUI + SwiftData.
No cloud, no accounts — data stays on your devices.

## How it works

**On the Watch Ultra:**

1. Press the **Action Button** (configured to open this app — see below).
2. Turn the **Digital Crown**:
   - **Up** → carbs, in steps of **10 g** (10, 20, 30, …)
   - **Down** → insulin, in steps of **0.5 U** (0.5, 1.0, 1.5, …)
3. Stop turning. After **5 seconds** the value auto-saves with the current
   date & time, you get a checkmark + haptic, and it returns to the neutral screen.
4. If you never turn the crown, **nothing is saved** — just drop your wrist.

The **neutral screen** shows a live **"time since last insulin"** timer so you can
avoid stacking doses. That's what you see first, before you turn the crown.

> One value per session (the dial is either carbs *or* insulin). To log both,
> press the Action Button again for a second entry.

**On the iPhone:** open the app to see all entries, newest first, grouped by day.
Entries logged on the watch sync over the local WatchConnectivity link (Bluetooth/
Wi-Fi, no internet) — usually within a few seconds when the phone is nearby.

## Project layout

```
Shared/            LogEntry (SwiftData model) + WatchConnectivity manager
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

### 7. Assign the Action Button (on the watch)

On the Watch Ultra: **Settings → Action Button → Action → Open App → Insulin**.
Now a single press of the Action Button from anywhere opens straight to the dial.

---

## Notes & limitations

- **Auto-close:** watchOS apps can't quit themselves programmatically (App Store
  disallows it). "Do nothing" simply saves nothing; dropping your wrist backgrounds
  the app. Reopening always starts fresh at the neutral screen.
- **Ranges:** carbs 10–400 g, insulin 0.5–20 U. Adjust `maxSteps` in
  `WatchApp/DialView.swift` to change them.
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
