#if DEBUG
import Foundation
import StrandAnalytics
import WhoopProtocol

/// Debug-only fake WHOOP 4.0: builds real, CRC-valid history frames and answers the history commands the way the strap does
/// (chunk by chunk, waiting for each acknowledgement). Launch with `-simulateHistory [hours]`.
@MainActor
final class SimulatedStrap {
    private var chunks: [[UInt8]] = []
    private var next = 0
    private var reassembler = Reassembler(family: .whoop4)
    private weak var history: HistorySync?
    private(set) var framesSent = 0
    var finished: (() -> Void)?

    static func install(on history: HistorySync, hours: Double = 36) -> SimulatedStrap {
        let s = SimulatedStrap(); s.history = history
        history.isConnected = { true }
        history.transport = { [weak s] cmd, payload, _ in Task { @MainActor in s?.onCommand(cmd, payload) } }
        Task.detached(priority: .userInitiated) {
            let c = SimulatedStrap.buildChunks(hours: hours)
            await MainActor.run { s.chunks = c }
        }
        return s
    }

    private func onCommand(_ cmd: WhoopCommand, _ payload: [UInt8]) {
        switch cmd {
        case .sendHistoricalData: next = 0; deliverNext()
        case .historicalDataResult: deliverNext()           // the ack frees the chunk; now the strap sends the next one
        default: break
        }
    }

    private func deliverNext() {
        guard next < chunks.count else { return }
        let bytes = chunks[next]; next += 1
        Task { @MainActor in
            if next == 1 { self.feed(Self.metaFrame(1, end: [0, 0, 0, 0, 0, 0, 0, 0])) }
            // BLE-sized slices exercise the reassembler
            var i = 0
            while i < bytes.count { feed(Array(bytes[i..<min(i + 182, bytes.count)])); i += 182; if i % (182 * 400) == 0 { await Task.yield() } }
            if next < chunks.count { feed(Self.metaFrame(2, end: [UInt8(next & 0xFF), 0, 0, 0, 1, 2, 3, 4])) }
            else { feed(Self.metaFrame(2, end: [UInt8(next & 0xFF), 0, 0, 0, 1, 2, 3, 4])); feed(Self.metaFrame(3, end: [0, 0, 0, 0, 0, 0, 0, 0])) }
        }
    }

    private func feed(_ bytes: [UInt8]) {
        for f in reassembler.feed(bytes) { framesSent += 1; history?.handle(f) }
    }

    // MARK: frame building

    nonisolated static func metaFrame(_ type: UInt8, end: [UInt8]) -> [UInt8] {
        var inner = [UInt8](repeating: 0, count: 24); inner[0] = 49; inner[2] = type
        for (i, b) in end.enumerated() { inner[13 + i] = b }
        return FrameCodec.build(family: .whoop4, type: .metadata, seq: 1, command: type, payload: Array(inner[3...]))
    }

    nonisolated static func recordFrame(unix: UInt32, hr: UInt8, rr: [UInt16], g: (Float, Float, Float)) -> [UInt8] {
        var abs = [UInt8](repeating: 0, count: 90)
        for i in 0..<4 { abs[11 + i] = UInt8((unix >> (8 * UInt32(i))) & 0xFF) }
        abs[21] = hr; abs[22] = UInt8(rr.count)
        for (i, v) in rr.enumerated() { abs[23 + 2 * i] = UInt8(v & 0xFF); abs[24 + 2 * i] = UInt8(v >> 8) }
        for (k, f) in [g.0, g.1, g.2].enumerated() { let b = f.bitPattern; for i in 0..<4 { abs[40 + 4 * k + i] = UInt8((b >> (8 * UInt32(i))) & 0xFF) } }
        abs[55] = 1
        var inner = Array(abs[4...]); inner[0] = 47; inner[1] = 24
        return FrameCodec.build(family: .whoop4, type: .historical, seq: 24, command: inner[2], payload: Array(inner[3...]))
    }

    /// `hours` of 1 Hz records ending ten minutes ago, with a night (23:00–07:00 local) and a daytime workout.
    nonisolated static func buildChunks(hours: Double) -> [[UInt8]] {
        let end = Int(Date().timeIntervalSince1970) - 600
        let start = end - Int(hours * 3600)
        var rng = SystemRandomNumberGenerator()
        var out: [[UInt8]] = []; var cur: [UInt8] = []; var n = 0
        let cal = Calendar.current
        var gx: Float = 0, gy: Float = 0, gz: Float = 1
        for t in start..<end {
            let comps = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(t)))
            let h = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60
            let night = h >= 23 || h < 7
            let phase = 0.5 + 0.5 * sin(Double(t) / 2700)
            var bpm: Double, motion: Float
            if night {
                let deep = phase < 0.35
                bpm = 51 + 5 * phase + (deep ? Double.random(in: -0.25...0.25, using: &rng) - 3 : Double.random(in: -1.5...1.5, using: &rng)); motion = deep ? 0.001 : (Int.random(in: 0..<100, using: &rng) < 3 ? 0.05 : 0.002)
            } else if h >= 17 && h < 17.8 { bpm = 140 + Double.random(in: -8...8, using: &rng); motion = 0.5 }
            else { bpm = 70 + Double.random(in: -6...8, using: &rng); motion = Float.random(in: 0.01...0.12, using: &rng) }
            // gravity is a unit-ish vector that wobbles with movement (not a random walk, which would leave the plausible range)
            gx = 0.95 * gx + motion * Float.random(in: -1...1, using: &rng); gy = 0.95 * gy + motion * Float.random(in: -1...1, using: &rng); gz = 1 + motion * Float.random(in: -0.5...0.5, using: &rng)
            let rrMs = 60000 / bpm + (night ? Double.random(in: -75...75, using: &rng) : Double.random(in: -15...15, using: &rng))
            cur += recordFrame(unix: UInt32(t), hr: UInt8(max(30, min(220, bpm))), rr: [UInt16(max(300, min(2000, rrMs)))], g: (gx, gy, gz))
            n += 1
            if n == 1000 { out.append(cur); cur = []; n = 0 }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
#endif
