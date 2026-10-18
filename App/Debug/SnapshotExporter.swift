import SwiftUI

/// Dev tool: launch with `-snapshot` to render full-length images of each screen in original and compact layouts
/// into the app's tmp/snaps folder (copied out with `simctl get_app_container`).
@MainActor
enum SnapshotExporter {
    static var requested: Bool { CommandLine.arguments.contains("-snapshot") }

    static func run(model: AppModel) async {
        try? await Task.sleep(for: .seconds(9))   // let demo streams load
        SnapshotMode.on = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snaps")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let all: Set<String> = ["today", "sleep", "workouts", "trends", "more"]
        for (modeName, compact) in [("original", false), ("compact", true)] {
            var ui = model.ui; ui.compact = compact ? all : []; model.ui = ui
            try? await Task.sleep(for: .milliseconds(300))
            render(TodayView(snapshot: true), tint: Palette.mintRich[0], name: "today-\(modeName)", dir: dir, model: model)
            render(SleepView(snapshot: true), tint: Palette.lavenderRich[0], name: "sleep-\(modeName)", dir: dir, model: model)
            render(WorkoutsView(snapshot: true), tint: Palette.peach[0], name: "workouts-\(modeName)", dir: dir, model: model)
            render(TrendsView(snapshot: true), tint: Palette.mint[0], name: "trends-\(modeName)", dir: dir, model: model)
        }
        var ui = model.ui; ui.compact = []; model.ui = ui
        SnapshotMode.on = false
        try? "done".write(to: dir.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
    }

    private static func render<V: View>(_ view: V, tint: Color, name: String, dir: URL, model: AppModel) {
        let framed = view
            .environment(model)
            .frame(width: 402)
            .fixedSize(horizontal: false, vertical: true)
            .background(ZStack { Color(.systemGroupedBackground); tint.opacity(0.12) })
            .environment(\.colorScheme, .light)
        let r = ImageRenderer(content: framed)
        r.scale = 2
        if let img = r.uiImage, let data = img.pngData() {
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
