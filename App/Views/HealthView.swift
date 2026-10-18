import SwiftUI

struct HealthView: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false

    var body: some View {
        List {
            if !model.health.isAvailable {
                Section { Label("Apple Health isn't available on this device.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            } else {
                Section {
                    if model.healthConnected {
                        LabeledContent("Status", value: "Connected")
                        if let t = model.healthPrefs.lastImport { LabeledContent("Last import", value: t.formatted(date: .abbreviated, time: .shortened)) }
                        Button { Task { busy = true; await model.importHealth(); busy = false } } label: {
                            HStack { Text("Import now"); if busy { Spacer(); ProgressView() } }
                        }.disabled(busy || model.settings.useDemoData)
                    } else {
                        Button { Task { busy = true; await model.connectHealth(); busy = false } } label: {
                            HStack { Label("Connect Apple Health", systemImage: "heart.text.square.fill"); if busy { Spacer(); ProgressView() } }
                        }.disabled(busy)
                    }
                    if model.settings.useDemoData {
                        Label("You're on demo data. Switch to My WHOOP in Settings → Profile & units to import your own Health data.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Health data stays on this phone. You choose exactly what to share in the permission sheet, and you can change it any time in the Health app (Sharing → Apps).")
                }

                if model.healthConnected {
                    Section {
                        Toggle("Save workouts", isOn: pref(\.writeWorkouts))
                        Toggle("Save sleep stages", isOn: pref(\.writeSleep))
                        Toggle("Save water", isOn: pref(\.writeWater))
                    } header: { Text("Write to Health") } footer: {
                        Text("Workouts include heart-rate samples and energy. Each item is saved once, so re-syncing never creates duplicates.")
                    }
                }

                Section("What we read") {
                    row("shoeprints.fill", "Steps", "Counted by your phone or watch, so they replace the strap's step estimate.")
                    row("heart.fill", "Resting heart rate", "Fills days the strap didn't cover; never overrides it.")
                    row("lungs.fill", "Respiratory rate", "Fills gaps only.")
                    row("bed.double.fill", "Sleep", "Used only for nights this app didn't stage. Health stages come from the watch or phone.")
                    row("figure.run", "Workouts", "Listed in your history, marked as from Apple Health.")
                    row("flame.fill", "Active energy", "Shown on the comparison screen.")
                }
                Section {
                    Text("HRV is deliberately not imported: Apple reports SDNN, this app uses RMSSD, and mixing them would make your baseline meaningless.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pref(_ kp: WritableKeyPath<HealthPrefs, Bool>) -> Binding<Bool> {
        Binding(get: { model.healthPrefs[keyPath: kp] }, set: { var p = model.healthPrefs; p[keyPath: kp] = $0; model.healthPrefs = p })
    }

    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.medium)); Text(text).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
