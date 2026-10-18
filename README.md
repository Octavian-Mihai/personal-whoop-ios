# Personal Whoop (iOS)

On-device SwiftUI app implementing the health analysis described in `HEALTH_ANALYSIS.md`.

- `Packages/StrandAnalytics` — pure Swift engines (baselines, HRV, sleep detect/stage, Rest/Charge/Effort, stress,
  workouts, readiness/load/forecast, illness, vitality/fitness age, circadian, cycle, insights, fusion, breathwork,
  lift log, alarms/notification policies) plus `WhoopProtocol` (WHOOP 4.0/5-MG framing, CRCs, reassembly, decoders).
  Run `swift test` inside the package.
- `App/` — SwiftUI app (Today, Sleep, Trends, Workouts, Breathe, More), CoreBluetooth manager, JSON store, demo data.
- Generate the Xcode project with `xcodegen generate`, then open `PersonalWhoop.xcodeproj`.

Everything is an approximation; not a medical device and not WHOOP's scoring. Without a strap the app runs on
synthetic demo data (toggle in Settings). Not covered yet: WHOOP history offload decoding beyond the frame layer,
5/MG record versions 20/21/26, ECG, Oura/Polar/Xiaomi, Apple Health import, AI coach.

## Widgets
`Widgets/` is a WidgetKit extension (home screen small/medium, lock screen circular/rectangular/inline). The app writes a small
snapshot (`Shared/WidgetShared.swift`) into the App Group `group.com.octa.personalwhoop`. To run on a real device, enable the
App Groups capability for both the app and widget targets under your own signing team (and change the group id if needed).

## First run
A fresh install asks whether to use demo data or connect a real strap (Settings → Profile & units → Data source switches later).

## Apple Health and Live Activities
- Settings → Apple Health reads steps, resting HR, respiratory rate, sleep, workouts and active energy (fills gaps; steps replace the strap's estimate)
  and can write workouts (with HR samples), sleep stages and water back. HRV is intentionally not imported (SDNN vs RMSSD).
- A tracked workout shows on the lock screen and in the Dynamic Island (Live Activity: heart rate, zone, timer, kcal, effort).
- Both need the HealthKit and App Groups capabilities enabled under your own signing team when running on a device.

## Importing a NOOP backup
Settings → Import from another app reads a `.noopbak` (a ZIP holding `noop-backup.sqlite`, `settings.json`, `manifest.json`): strap-derived
days (Charge, Effort, Rest, HRV, resting HR…), sleep nights with stages, workouts (last year) and Apple Health history (gap filler).
The ZIP is streamed and inflated on-device with no third-party code; the SQLite copy is opened read/write because backups are WAL-mode.

## Strap history sync
`App/BLE/HistorySync.swift` implements the offload from the protocol notes: SEND_HISTORICAL_DATA, chunks of type-47 records, each chunk saved
(`HistoryStore`, an append-only binary log) *before* it is acknowledged with command 23. `HistoryAnalyzer` turns stored records into sleep nights,
daily rows and today's raw streams. Debug builds can replay a fake strap: launch with `-simulateHistory 36`.
Appearance (Settings → Personalize): Automatic (follow iPhone), Light, Dark, or light/dark by time of day.
