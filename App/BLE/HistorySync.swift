import Foundation
import Observation
import StrandAnalytics
import WhoopProtocol

/// Downloads what the strap stored while it was away (spec §14.8): ask for history, receive chunks of records, make each chunk durable,
/// then acknowledge it so the strap can free it. Anything not acknowledged is simply offered again next time, so stopping loses nothing.
@Observable
@MainActor
final class HistorySync {
    enum Phase: Equatable { case idle, requesting, receiving, finishing, done, failed(String) }

    var phase: Phase = .idle
    var recordsDecoded = 0
    var chunks = 0
    var oldest: Date?
    var newest: Date?
    var startedAt: Date?
    var lastCompleted: Date? = UserDefaults.standard.object(forKey: "historyLastCompleted") as? Date
    var estimate: SyncEstimate = {
        (UserDefaults.standard.data(forKey: "syncEstimate").flatMap { try? JSONDecoder().decode(SyncEstimate.self, from: $0) }) ?? SyncEstimate()
    }()
    var storedCount = 0

    let store = HistoryStore()
    weak var ble: BLEManager?
    /// Test seams: a fake strap can replace the Bluetooth link.
    var isConnected: () -> Bool = { false }
    var transport: ((WhoopCommand, [UInt8], Bool) -> Void)?
    private func send(_ c: WhoopCommand, _ payload: [UInt8] = [0x00], ack: Bool = true) {
        if let t = transport { t(c, payload, ack) } else { ble?.send(c, payload: payload, withResponse: ack) }
    }
    var onFinished: (() async -> Void)?

    private var policy = BackfillPolicy()
    private var pending: [HistoryRecord] = []
    private var nDecoded = 0
    private var nChunks = 0
    private var firstTs: UInt32?
    private var lastTs: UInt32?
    private var stall: Timer?
    private var publisher: Timer?
    private var gapAtStart: Double = 0

    var isActive: Bool { switch phase { case .requesting, .receiving, .finishing: return true; default: return false } }

    /// "about N min" from past syncs; nil until one has been timed.
    var estimateText: String? {
        guard let last = lastCompleted, let s = estimate.estimateSeconds(gap: Date().timeIntervalSince(last)) else { return nil }
        return s < 90 ? "about \(Int((s / 5).rounded()) * 5) s" : "about \(Int((s / 60).rounded())) min"
    }

    func loadStore() async { await store.load(); storedCount = await store.count }

    func start(manual: Bool) {
        guard isConnected(), !isActive else { return }
        let now = Date().timeIntervalSince1970
        guard manual || policy.allowed(.periodic, now: now, strapFutureDated: false) else { return }
        phase = .requesting; recordsDecoded = 0; chunks = 0; oldest = nil; newest = nil
        nDecoded = 0; nChunks = 0; firstTs = nil; lastTs = nil; pending = []
        startedAt = Date(); gapAtStart = lastCompleted.map { Date().timeIntervalSince($0) } ?? 0
        policy.lastAutomatic = now
        send(.sendHistoricalData, [0x00])
        armStall(); startPublishing()
    }

    func cancel() {
        guard isActive else { return }
        send(.abortHistoricalTransmits)
        finish(.idle)
    }

    /// Called for every type-47 (record) and type-49 (metadata) frame.
    func handle(_ f: Frame) {
        guard isActive || phase == .idle, let ev = HistoryProtocol.parse(f, now: UInt32(Date().timeIntervalSince1970)) else { return }
        armStall()
        switch ev {
        case .started:
            phase = .receiving
        case .record(let s):
            if phase == .requesting { phase = .receiving }
            nDecoded += 1
            pending.append(HistoryRecord(s))
            firstTs = min(firstTs ?? s.unix, s.unix); lastTs = max(lastTs ?? s.unix, s.unix)
        case .chunkEnd(let endData, _):
            nChunks += 1
            let batch = pending; pending = []
            Task {
                await store.append(batch)             // durable first…
                send(.historicalDataResult, HistoryProtocol.ackPayload(endData: endData))   // …then let the strap free it
            }
        case .complete:
            phase = .finishing
            let batch = pending; pending = []
            Task {
                await store.append(batch)
                storedCount = await store.count
                if nDecoded == 0 { policy.consecutiveEmpty += 1 } else { policy.consecutiveEmpty = 0 }
                if let start = startedAt, nDecoded > 0 { estimate.record(gapSeconds: max(gapAtStart, 600), durationSeconds: Date().timeIntervalSince(start)) }
                persist()
                await onFinished?()
                finish(.done)
            }
        }
    }

    // MARK: private
    private func finish(_ p: Phase) {
        stall?.invalidate(); publisher?.invalidate(); publish()
        if p == .done { lastCompleted = Date(); UserDefaults.standard.set(lastCompleted, forKey: "historyLastCompleted") }
        phase = p
    }

    private func armStall() {
        stall?.invalidate()
        stall = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.send(.abortHistoricalTransmits)
                self.finish(.failed("The strap stopped sending. Unacknowledged data will be offered again next time."))
            }
        }
    }

    /// Counters are copied to observable state a few times a second, so a 100k-record sync doesn't redraw the UI per record.
    private func startPublishing() {
        publisher?.invalidate()
        publisher = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.publish() } }
    }

    private func publish() {
        recordsDecoded = nDecoded; chunks = nChunks
        oldest = firstTs.map { Date(timeIntervalSince1970: Double($0)) }; newest = lastTs.map { Date(timeIntervalSince1970: Double($0)) }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(estimate) { UserDefaults.standard.set(d, forKey: "syncEstimate") }
    }
}
