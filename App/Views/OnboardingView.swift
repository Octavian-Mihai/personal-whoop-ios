import SwiftUI

/// First launch: pick demo data or a real strap.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            AmbientBackground(tint: Palette.mintRich[0])
            VStack(spacing: 22) {
                Spacer(minLength: 20)
                Image(systemName: "waveform.path.ecg.rectangle.fill").font(.system(size: 56)).foregroundStyle(Palette.mintRich[1])
                VStack(spacing: 6) {
                    Text("Welcome").font(.largeTitle.bold())
                    Text("Everything is calculated on your phone, from your own heart rate and sleep. How do you want to start?")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                }
                VStack(spacing: 12) {
                    choice(icon: "dot.radiowaves.left.and.right", title: "Connect my WHOOP",
                           text: "Use your own strap. Live heart rate and battery appear right away; scores build up as data comes in.",
                           colors: Palette.mintRich) { model.chooseDataSource(demo: false) }
                    choice(icon: "sparkles", title: "Try it with demo data",
                           text: "Explore every screen with 60 days of made-up data. No strap needed. You can switch later in Settings.",
                           colors: Palette.lavenderRich) { model.chooseDataSource(demo: true) }
                }
                .padding(.horizontal, 20)
                Text("Not a medical device and not WHOOP's scoring.").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 10)
            }
        }
    }

    private func choice(icon: String, title: String, text: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(.white).frame(width: 50, height: 50)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(text).font(.caption).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: colors[1].opacity(0.3), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }
}
