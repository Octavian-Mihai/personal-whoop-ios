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
