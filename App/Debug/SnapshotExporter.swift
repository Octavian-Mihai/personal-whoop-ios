import SwiftUI
import WidgetKit

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
        for modeName in ["current"] {
            render(TodayView(snapshot: true), tint: Palette.mintRich[0], name: "today-\(modeName)", dir: dir, model: model)
            render(SleepView(snapshot: true), tint: Palette.lavenderRich[0], name: "sleep-\(modeName)", dir: dir, model: model)
            render(WorkoutsView(snapshot: true), tint: Palette.peach[0], name: "workouts-\(modeName)", dir: dir, model: model)
            render(TrendsView(snapshot: true), tint: Palette.mint[0], name: "trends-\(modeName)", dir: dir, model: model)
        }
        renderWidgets(dir: dir)
        SnapshotMode.on = false
        try? "done".write(to: dir.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
    }

    /// Widget previews: the same views the extension uses, on mock widget backgrounds.
    private static func renderWidgets(dir: URL) {
        let snap = WidgetSnapshot.sample
        func tile<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat, bg: AnyShapeStyle, dark: Bool = false, name: String) {
            let framed = v.padding(16).frame(width: w, height: h).background(bg, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(10).background(dark ? Color.black : Color(.systemGroupedBackground)).environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: framed); r.scale = 3
            if let d = r.uiImage?.pngData() { try? d.write(to: dir.appendingPathComponent("widget-\(name).png")) }
        }
        let green = AnyShapeStyle(LinearGradient(colors: WTheme.mint, startPoint: .topLeading, endPoint: .bottomTrailing))
        tile(TodayWidgetContent(snap: snap, family: .systemSmall), 158, 158, bg: green, name: "today-small")
        tile(TodayWidgetContent(snap: snap, family: .systemMedium), 338, 158, bg: green, name: "today-medium")
        tile(StrapWidgetContent(snap: snap, family: .systemSmall), 158, 158, bg: AnyShapeStyle(Color(.secondarySystemBackground)), name: "strap-small")
        tile(TodayWidgetContent(snap: snap, family: .accessoryRectangular), 170, 76, bg: AnyShapeStyle(Color.white.opacity(0.15)), dark: true, name: "lock-rectangular")
        tile(TodayWidgetContent(snap: snap, family: .accessoryCircular), 76, 76, bg: AnyShapeStyle(Color.white.opacity(0.15)), dark: true, name: "lock-circular")
        tile(StrapWidgetContent(snap: snap, family: .accessoryCircular), 76, 76, bg: AnyShapeStyle(Color.white.opacity(0.15)), dark: true, name: "lock-strap")
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
