import SwiftUI
import UniformTypeIdentifiers

/// Import from a NOOP backup (.noopbak). Strap-derived days, sleep nights and workouts come in; Apple Health history only fills gaps.
struct ImportBackupView: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false
    @State private var busy = false
    @State private var status = ""
    @State private var result: NoopImportResult?
    @State private var error: String?
    @State private var profileApplied = false
    @State private var confirmSwitch = false
    @State private var pendingURL: URL?

    private var types: [UTType] { [UTType(filenameExtension: "noopbak"), .zip, .data].compactMap { $0 } }

    var body: some View {
        List {
            Section {
                Text("Import the data file from another app: a NOOP backup (.noopbak) with your WHOOP history. Pick it from Files, iCloud Drive or AirDrop.")
                    .font(.footnote)
                Button { picking = true } label: {
                    HStack { Label("Choose backup file…", systemImage: "square.and.arrow.down"); if busy { Spacer(); ProgressView() } }
                }.disabled(busy)
                if busy { Text(status).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Large backups are unpacked temporarily on your phone (a 70 MB file can need about 500 MB for a minute). Nothing is uploaded anywhere.")
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote) }
            }

            if let r = result {
                Section("Imported") {
                    ForEach(r.summaryLines, id: \.self) { Label($0, systemImage: "checkmark.circle") }
                    if let first = r.days.first?.day, let last = r.days.last?.day {
                        LabeledContent("Strap days", value: "\(first) → \(last)")
                    }
                }
                if let p = r.profile {
                    Section {
                        if let a = p.age { LabeledContent("Age", value: "\(Int(a))") }
                        if let h = p.heightCm { LabeledContent("Height", value: "\(Int(h)) cm") }
                        if let w = p.weightKg { LabeledContent("Weight", value: "\(Int(w)) kg") }
                        if let m = p.hrMax { LabeledContent("Max heart rate", value: "\(Int(m)) bpm") }
                        Button(profileApplied ? "Profile updated" : "Use this profile") { model.useBackupProfile(p); profileApplied = true }.disabled(profileApplied)
                    } header: { Text("Profile in the backup") } footer: { Text("Optional. This changes your age, height, weight and max heart rate used for zones and calories.") }
                }
                Section {
                    Text("How it was merged: days your strap scored replace what was here; Apple Health history in the backup only fills days that had no strap data, and steps from Apple Health replace step estimates. HRV from Apple Health is never imported (different method).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Import from another app")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: types) { res in
            guard case .success(let u) = res else { return }
            if model.settings.useDemoData { pendingURL = u; confirmSwitch = true } else { run(u) }
        }
        .confirmationDialog("Replace demo data?", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button("Switch to My WHOOP and import", role: .destructive) { if let u = pendingURL { run(u) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Importing real data replaces the demo data you're looking at now.") }
        .task { await debugAutoImport() }
    }

    private func run(_ url: URL) {
        busy = true; error = nil; result = nil; status = "Opening…"
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let r = try await model.importNoopBackup(from: url) { msg in Task { @MainActor in status = msg } }
                result = r
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    /// Debug builds only: `-importNoopbak /path/to/file` runs the import on launch (used for testing).
    private func debugAutoImport() async {
        #if DEBUG
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "-importNoopbak"), i + 1 < a.count, result == nil, !busy { run(URL(fileURLWithPath: a[i + 1])) }
        #endif
    }
}
