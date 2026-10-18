import SwiftUI
import StrandAnalytics
import UserNotifications
import UniformTypeIdentifiers
import WhoopProtocol

struct MoreView: View {
    @Environment(AppModel.self) private var model
    private func on(_ k: String) -> Bool { !model.ui.hiddenMore.contains(k) }
    private var compact: Bool { model.isCompact("more") }

    var body: some View {
        NavigationStack {
            List {
                Section("Long-term") {
                    if on("vitality") { NavigationLink("Vitality & Fitness Age") { LongevityView() } }
                    if on("circadian") { NavigationLink("Body clock & jet lag") { CircadianView() } }
                    if on("cycle") { NavigationLink("Cycle awareness") { CycleView() } }
                    if on("illness") { NavigationLink("Illness watch") { IllnessView() } }
                }
                Section("Strap") {
                    if on("alarms") { NavigationLink("Alarms & wind-down") { AlarmView() } }
                    NavigationLink("Device & sync") { DeviceView() }
                }
                if compact {
                    Section {
                        NavigationLink("Backup & restore") { BackupView() }
                        DisclosureGroup("Advanced") {
                            if on("fusion") { NavigationLink("Combining sources") { FusionView() } }
                            if on("testcentre") { NavigationLink("Test Centre") { TestCentreView() } }
                            NavigationLink("About & honesty rules") { AboutView() }
                        }
                    } header: { Text("Data") }
                } else {
                Section("Data") {
                    if on("fusion") { NavigationLink("Combining sources") { FusionView() } }
                    NavigationLink("Backup & restore") { BackupView() }
                    if on("testcentre") { NavigationLink("Test Centre") { TestCentreView() } }
                }
                }
                Section("Settings") {
                    NavigationLink("Personalize") { PersonalizeView() }
                    NavigationLink("Profile & preferences") { SettingsView() }
                    NavigationLink("Notifications") { NotificationsView() }
                    if !compact { NavigationLink("About & honesty rules") { AboutView() } }
                }
            }
            .navigationTitle("More")
        }
    }
}

struct LongevityView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section("Vitality") {
                if let v = model.vitality {
                    LabeledContent("Vitality", value: String(format: "%.0f / 100", v.vitality))
                    LabeledContent("Body age", value: String(format: "%.0f ± 5 y", v.bodyAge))
                    LabeledContent("Factors used", value: "\(v.factors)")
                } else { Text("Needs ≥ 3 factors").foregroundStyle(.secondary) }
                Text("Published hazard ratios, summed in log space with a 0.75 overlap shrink and an 8-year Gompertz doubling time. A wellness comparison, not a biological age.").font(.caption2)
            }
            Section("Fitness Age") {
                if let f = model.fitnessAge { LabeledContent("Fitness age", value: String(format: "%.0f ± 5 y", f)) }
                else { Text("Needs ≥ 4 nights of resting HR").foregroundStyle(.secondary) }
                Text("Nes 2011 (HUNT) non-exercise VO₂max inverted against a reference peer so body-size terms cancel.").font(.caption2)
            }
            Section("Energy balance") {
                Text("Opt-in retrospective TDEE needs 14+ intake days and 6+ weigh-ins; always shown as an interval.").font(.caption)
            }
        }.navigationTitle("Vitality")
    }
}

struct CircadianView: View {
    @Environment(AppModel.self) private var model
    @State private var shift = 3.0
    var body: some View {
        List {
            Section("Your rhythm") {
                if let c = model.circadian {
                    LabeledContent("Alignment", value: c.alignment.rawValue)
                    if c.alignment != .unreadable {
                        LabeledContent("Offset", value: String(format: "%+.0f min", c.offsetMinutes))
                        LabeledContent("Chronotype", value: CircadianEngine.chronotype(tempMin: c.tempMin).rawValue.capitalized)
                    }
                    LabeledContent("Confidence", value: c.solid ? "Solid" : "Wide")
                } else { Text("Hard to read right now").foregroundStyle(.secondary) }
            }
            Section("Jet-lag / shift plan") {
                Stepper(String(format: "Shift %+.0f h", shift), value: $shift, in: -12...12)
                let plan = CircadianEngine.planShift(hours: shift, currentBed: 23, currentWake: Double(model.settings.alarm.wakeMinute) / 60)
                if plan.isEmpty { Text("No adjustment needed") }
                ForEach(plan, id: \.day) { d in
                    VStack(alignment: .leading) {
                        Text("Day \(d.day): sleep \(String(format: "%02.0f:00", d.sleepHour)), wake \(String(format: "%02.0f:00", d.wakeHour))").font(.subheadline)
                        Text(d.light).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("Moves at most 1 h/day. Light and sleep-timing guidance only.").font(.caption2)
            }
        }.navigationTitle("Body clock")
    }
}

struct CycleView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Toggle("Enable cycle awareness", isOn: Binding(get: { model.settings.cycleAwareness }, set: { model.settings.cycleAwareness = $0 }))
            if model.settings.cycleAwareness {
                let est = estimate()
                LabeledContent("Phase", value: est.phase.rawValue.capitalized)
                LabeledContent("Confidence", value: est.confidence)
                if let l = est.cycleLength { LabeledContent("Cycle length", value: "\(l) days") }
                if let d = est.cycleDay { LabeledContent("Cycle day (±2)", value: "\(d)") }
            }
            Text("Wellness awareness only — not contraception, not a fertility or ovulation predictor, not a diagnosis. Needs ≥ 42 nights; without a clear pattern the phase reads unknown rather than guessed.")
                .font(.caption2)
        }.navigationTitle("Cycle")
    }
    private func estimate() -> CycleEstimate {
        let d = model.days
        func z(_ kp: KeyPath<DailyMetric, Double?>, _ b: BaselineMetric) -> [Double?] {
            let base = Baseline.build(b, from: d.map { $0[keyPath: kp] })
            return d.map { $0[keyPath: kp].map { base.z($0) } }
        }
        return CyclePhaseEngine.estimate(tempZ: d.map { $0.skinTempDev.map { $0 / 0.3 } }, rhrZ: z(\.restingHR, .restingHR), hrvZ: z(\.hrv, .hrv))
    }
}

struct IllnessView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Toggle("Illness watch", isOn: Binding(get: { model.settings.illnessWatch }, set: { model.settings.illnessWatch = $0; model.recompute() }))
            if let r = model.illness {
                LabeledContent("Level", value: r.level.rawValue)
                LabeledContent("Score", value: String(format: "%.0f", r.score))
                if let e = r.explanation { Text(e).font(.footnote) }
                if !r.firing.isEmpty { Text("Signals: " + r.firing.sorted().joined(separator: ", ")).font(.footnote) }
            } else { Text("Needs ≥ 14 days of history and a trusted baseline").foregroundStyle(.secondary) }
            Text("Two or more of resting HR ↑, respiration ↑, HRV ↓, skin temperature ↑ must each reach z ≥ 2. Alcohol, workouts or feeling sick downgrade the result. The copy never names a condition.")
                .font(.caption2)
        }.navigationTitle("Illness watch")
    }
}

// MARK: - Alarms

struct AlarmView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var m = model
        List {
            Section {
                Toggle("Strap wake alarm", isOn: Binding(get: { model.settings.alarm.enabled }, set: { model.settings.alarm.enabled = $0; apply() }))
                DatePicker("Wake time", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: model.settings.alarm.wakeMinute / 60, minute: model.settings.alarm.wakeMinute % 60, second: 0, of: Date())! },
                    set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); model.settings.alarm.wakeMinute = c.hour! * 60 + c.minute!; apply() }),
                    displayedComponents: .hourAndMinute)
                weekdayPicker
                Toggle("Snooze (max 3 re-arms)", isOn: Binding(get: { model.settings.alarm.snooze }, set: { model.settings.alarm.snooze = $0 }))
                Picker("Snooze delay", selection: Binding(get: { model.settings.alarm.snoozeMinutes }, set: { model.settings.alarm.snoozeMinutes = $0 })) {
                    ForEach(SmartAlarm.snoozeDelays, id: \.self) { Text("\($0) min").tag($0) }
                }
                if let next = next() { LabeledContent("Next", value: next.formatted(date: .abbreviated, time: .shortened)) }
            } footer: {
                Text("The strap holds one absolute alarm and buzzes silently on your wrist — the app re-arms it after every fire, on connect and daily. A phone notification at the same instant is a backup, not a loud alarm. WHOOP 4.0 only; 5/MG arming is experimental.")
            }
            Section("Wind-down") {
                Toggle("Evening nudge", isOn: Binding(get: { model.settings.alarm.windDown }, set: { model.settings.alarm.windDown = $0; apply() }))
                let w = WindDownNudge.minuteOfDay(wakeMinute: model.settings.alarm.wakeMinute, needMinutes: Int(model.sleepNeedMin))
                Text("Nudge at \(String(format: "%02d:%02d", w.minute / 60, w.minute % 60)) — wake time minus your sleep need minus 30 min.").font(.caption)
            }
        }
        .navigationTitle("Alarms")
    }

    private var weekdayPicker: some View {
        HStack {
            ForEach(Array(Calendar.current.veryShortWeekdaySymbols.enumerated()), id: \.offset) { i, s in
                let wd = i + 1
                let on = model.settings.alarm.weekdays.isEmpty || model.settings.alarm.weekdays.contains(wd)
                Text(s).frame(width: 30, height: 30)
                    .background(on ? Color.accentColor : Color.gray.opacity(0.2), in: Circle()).foregroundStyle(on ? .white : .primary)
                    .onTapGesture {
                        var set = model.settings.alarm.weekdays.isEmpty ? Set(1...7) : model.settings.alarm.weekdays
                        if set.contains(wd) { set.remove(wd) } else { set.insert(wd) }
                        model.settings.alarm.weekdays = set.count == 7 ? [] : set
                        apply()
                    }
            }
        }
    }

    private func next() -> Date? {
        let a = model.settings.alarm
        return a.enabled ? SmartAlarm.next(after: Date(), wakeMinute: a.wakeMinute, weekdays: a.weekdays) : nil
    }

    private func apply() {
        let a = model.settings.alarm
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["alarm-backup", "wind-down"])
        guard a.enabled || a.windDown else { model.ble.disarmAlarm(); return }
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            if a.enabled, let d = SmartAlarm.next(after: Date(), wakeMinute: a.wakeMinute, weekdays: a.weekdays) {
                let c = UNMutableNotificationContent(); c.title = "Wake up"; c.body = "Your alarm"; c.sound = .default
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                center.add(UNNotificationRequest(identifier: "alarm-backup", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
                Task { @MainActor in model.ble.armAlarm(at: d) }
            }
            if a.windDown {
                let w = WindDownNudge.minuteOfDay(wakeMinute: a.wakeMinute, needMinutes: a.sleepNeedMinutes)
                let c = UNMutableNotificationContent(); c.title = "Time to wind down"; c.body = "Dim the lights — bedtime is near."
                var dc = DateComponents(); dc.hour = w.minute / 60; dc.minute = w.minute % 60
                center.add(UNNotificationRequest(identifier: "wind-down", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
            }
        }
    }
}

// MARK: - Device

struct DeviceView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("State", value: model.ble.state.rawValue)
                LabeledContent("Device", value: model.ble.deviceName ?? "—")
                LabeledContent("Family", value: model.ble.family?.rawValue ?? "Standard HR")
                LabeledContent("Battery", value: model.ble.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                LabeledContent("Wrist", value: model.ble.wristOn.map { $0 ? "On" : "Off" } ?? "—")
                LabeledContent("Frames decoded", value: "\(model.ble.lastFrameCount)")
                Button(model.ble.state == .connected ? "Disconnect" : "Connect") { model.ble.state == .connected ? model.ble.disconnect() : model.ble.connect() }
            }
            Section("Commands (reversible only)") {
                Button("Buzz strap") { model.ble.buzz(loops: 2) }
                Button("Sync strap clock") { model.ble.syncClock() }
                Button("Read battery") { model.ble.requestBattery() }
                Text("Destructive opcodes (firmware load, force trim, DFU) have no case in the command type, so the app cannot form them.").font(.caption2)
            }
            Section("Log") { ForEach(model.ble.log.suffix(40).reversed(), id: \.self) { Text($0).font(.caption2.monospaced()) } }
        }.navigationTitle("Device")
    }
}

// MARK: - Fusion

struct FusionView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section("How it works") {
                Text("When several sources report the same metric, one is picked verbatim and the disagreement is shown. Numbers are never averaged across devices.").font(.footnote)
            }
            Section("Example · today's resting HR") {
                let rhr = model.today?.restingHR ?? 56
                example(.restingHR, [(.noopComputed, rhr), (.appleHealth, rhr + 2)])
            }
            Section("Example · steps") {
                let steps = Double(model.today?.steps ?? 8000)
                example(.steps, [(.noopComputed, steps), (.appleHealth, steps * 0.92)])
            }
            Section("Example · sleep (min)") {
                let s = model.today?.asleepMin ?? 420
                example(.sleep, [(.noopComputed, s), (.appleHealth, s + 35)])
            }
        }.navigationTitle("Combining sources")
    }
    @ViewBuilder private func example(_ m: FusionMetric, _ inputs: [(DataSource, Double)]) -> some View {
        if let r = FusionResolver.resolve(m, inputs: inputs) {
            LabeledContent("Winner", value: "\(r.winner.source.rawValue) · \(String(format: "%.0f", r.winner.value))")
            Text("\(r.winner.reason) · \(r.agreement.rawValue)").font(.caption)
        }
    }
}

// MARK: - Backup

struct BackupView: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var message: String?
    var body: some View {
        List {
            Section {
                Button("Create backup") { exportURL = model.exportBackup() }
                if let exportURL { ShareLink("Share / save backup", item: exportURL) }
                Button("Restore from file…") { importing = true }
                Button("Reset to fresh demo data", role: .destructive) { model.resetDemo() }
                if let message { Text(message).font(.footnote) }
            } footer: {
                Text("Backups are plain JSON and carry settings, scores and workouts — never device identifiers. Point the Files share at iCloud Drive and its client does the upload.")
            }
        }
        .navigationTitle("Backup")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let u) = result else { return }
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            do { try model.restore(from: u); message = "Restored" } catch { message = "Restore failed — the file is not a backup from this app. Your data is untouched." }
        }
    }
}

// MARK: - Test Centre

struct TestCentreView: View {
    @Environment(AppModel.self) private var model
    @State private var domains: Set<String> = []
    let all = ["Sleep & Rest", "Connection & Sync", "Workouts", "Recovery", "HRV", "Stress & Illness", "Battery", "Notifications / Alarm"]
    var body: some View {
        List {
            Section("Capture domains") {
                ForEach(all, id: \.self) { d in
                    Toggle(d, isOn: Binding(get: { domains.contains(d) }, set: { if $0 { domains.insert(d) } else { domains.remove(d) } }))
                }
            }
            Section("Report") {
                ShareLink("Review & share report", item: report())
                Text("Identifiers are scrubbed from the text before you see it. Nothing leaves the device unless you share it.").font(.caption2)
            }
        }.navigationTitle("Test Centre")
    }
    private func report() -> String {
        var s = "Personal Whoop report\nDomains: \(domains.sorted().joined(separator: ", "))\n"
        s += "Days: \(model.days.count) · HRV baseline: \(model.baselines?.hrv.status.rawValue ?? "n/a")\n"
        s += "BLE: \(model.ble.state.rawValue), frames \(model.ble.lastFrameCount)\n"
        s += model.ble.log.suffix(50).joined(separator: "\n")
        // PII scrub: UUIDs and long hex strings
        s = s.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", with: "<id>", options: .regularExpression)
        return s
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section("Profile") {
                Stepper("Age \(Int(model.settings.profile.age))", value: Binding(get: { model.settings.profile.age }, set: { model.settings.profile.age = $0; model.recompute() }), in: 13...100)
                Picker("Sex", selection: Binding(get: { model.settings.profile.male.map { $0 ? 1 : 2 } ?? 0 }, set: { model.settings.profile.male = $0 == 0 ? nil : $0 == 1 })) {
                    Text("Unspecified").tag(0); Text("Male").tag(1); Text("Female").tag(2)
                }
                Stepper("Weight \(Int(model.settings.profile.weightKg)) kg", value: Binding(get: { model.settings.profile.weightKg }, set: { model.settings.profile.weightKg = $0 }), in: 30...200)
                Stepper("Height \(Int(model.settings.profile.heightCm)) cm", value: Binding(get: { model.settings.profile.heightCm }, set: { model.settings.profile.heightCm = $0 }), in: 120...220)
            }
            Section("Display") {
                Toggle("Effort on 0–21 scale", isOn: Binding(get: { model.settings.effortOn21Scale }, set: { model.settings.effortOn21Scale = $0 }))
            }
            Section("Automations (opt-in)") {
                Toggle("HR-zone coaching", isOn: Binding(get: { model.settings.zoneCoach }, set: { model.settings.zoneCoach = $0 }))
                Toggle("Inactivity reminder", isOn: Binding(get: { model.settings.sedentaryReminder }, set: { model.settings.sedentaryReminder = $0 }))
                Toggle("Stress check-in nudge", isOn: Binding(get: { model.settings.stressNudge }, set: { model.settings.stressNudge = $0 }))
            }
            Section("Data") {
                Toggle("Demo data", isOn: Binding(get: { model.settings.useDemoData }, set: { model.settings.useDemoData = $0 }))
            }
        }.navigationTitle("Settings")
    }
}

struct NotificationsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Toggle("Battery alerts", isOn: bind(\.batteryAlerts))
            Toggle("Optimal strain reached", isOn: bind(\.strainTarget))
            Toggle("Illness heads-up", isOn: bind(\.illness))
            Toggle("Explain strap buzzes", isOn: bind(\.buzzExplain))
            Section {
                Text("Low ≤ 15 %, critical ≤ 12 %, full at 100 %, runtime ≤ 24 h. Hysteresis keeps 14↔15 % jitter to one alert per discharge cycle.").font(.caption)
                Text("Optimal band: Charge ≥ 67 → 14–18, 34–66 → 10–14, < 34 → 4–10 (of 21).").font(.caption)
            }
        }.navigationTitle("Notifications")
    }
    private func bind(_ kp: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings.notifications[keyPath: kp] }, set: {
            model.settings.notifications[keyPath: kp] = $0
            if $0 { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        })
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section("Honesty rules") {
                Text("• No number is shown when it can't be computed honestly — you'll see Calibrating instead.")
                Text("• Every score carries Solid / Building / Calibrating.")
                Text("• Engines are pure and deterministic, tested against fixed vectors.")
                Text("• Everything runs on your phone. No server.")
                Text("• Not medical advice and not WHOOP's proprietary algorithms.")
            }
            Section("Not yet in this build") {
                Text("Oura / Polar / Xiaomi sources, Apple Health import & write-back, WHOOP history offload decoding beyond the frame layer, 5/MG record versions 20/21/26, ECG, and the AI coach.")
            }
        }.navigationTitle("About")
    }
}

struct PersonalizeView: View {
    @Environment(AppModel.self) private var model

    static let moreItems: [(key: String, title: String)] = [
        ("vitality", "Vitality & Fitness Age"), ("circadian", "Body clock & jet lag"), ("cycle", "Cycle awareness"),
        ("illness", "Illness watch"), ("alarms", "Alarms & wind-down"), ("fusion", "Combining sources"), ("testcentre", "Test Centre"),
    ]

    private func toggle(_ keyPath: WritableKeyPath<UISettings, Set<String>>, _ key: String, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { !model.ui[keyPath: keyPath].contains(key) },
            set: { on in
                var ui = model.ui
                if on { ui[keyPath: keyPath].remove(key) } else { ui[keyPath: keyPath].insert(key) }
                model.ui = ui
            }))
    }

    var body: some View {
        Form {
            Section("Tabs") {
                ForEach(AppTab.allCases) { toggle(\.hiddenTabs, $0.rawValue, title: $0.title) }
                Text("Today and More are always shown.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Today page cards") {
                ForEach(TodayCard.allCases) { toggle(\.hiddenCards, $0.rawValue, title: $0.title) }
            }
            Section("Compact layouts") {
                ForEach([("today", "Today"), ("sleep", "Sleep"), ("workouts", "Workouts"), ("trends", "Trends"), ("more", "More")], id: \.0) { key, title in
                    Toggle(title, isOn: Binding(get: { model.ui.compact.contains(key) }, set: { on in
                        var ui = model.ui
                        if on { ui.compact.insert(key) } else { ui.compact.remove(key) }
                        model.ui = ui
                    }))
                }
                Text("Denser versions of each page — same data, less scrolling.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Charge drivers") {
                Picker("Show", selection: Binding(get: { model.ui.driverDisplay }, set: { var u = model.ui; u.driverDisplay = $0; model.ui = u })) {
                    ForEach(DriverDisplay.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section("More menu") {
                ForEach(Self.moreItems, id: \.key) { toggle(\.hiddenMore, $0.key, title: $0.title) }
            }
            Section {
                Button("Reset to defaults", role: .destructive) { model.ui = UISettings() }
            }
        }
        .navigationTitle("Personalize")
    }
}
