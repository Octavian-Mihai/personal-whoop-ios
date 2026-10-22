import Foundation
import CoreBluetooth
import Observation
import WhoopProtocol
import StrandAnalytics

/// CoreBluetooth central for WHOOP 4.0 / 5-MG and any standard HR strap (service 180D).
/// Only the reversible command set in `WhoopCommand` can be sent.
@Observable
@MainActor
final class BLEManager: NSObject {
    enum State: String { case off = "Bluetooth off", idle = "Idle", scanning = "Scanning…", connecting = "Connecting…", connected = "Connected" }

    var state: State = .idle
    var deviceName: String?
    var family: WhoopFamily?
    var heartRate: Int?
    var batteryPercent: Double?
    /// Last battery reading ever received, kept across launches so the app can show it before the strap reconnects.
    var lastBattery: (percent: Double, at: Date)?
    var lastRR: [Double] = []
    var log: [String] = []
    var lastFrameCount = 0
    var wristOn: Bool?
    var onHR: ((Int, [Double]) -> Void)?
    var onBattery: ((Double) -> Void)?
    /// Recent (time, percent) readings, kept across launches to estimate the time left.
    private(set) var batteryHistory: [(t: Double, soc: Double)] = []
    var onHistoryFrame: ((Frame) -> Void)?
    var onReady: (() -> Void)?
    var onDisconnect: (() -> Void)?
    /// While true the 30 s battery/RSSI poll is skipped so it doesn't compete with a bulk history download.
    var isBusy: () -> Bool = { false }
    var hrWindow: [(t: Double, bpm: Double)] = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var seq: UInt8 = 0
    private var reassembler = Reassembler(family: .whoop4)
    private var keepAlive: Timer?
    private var wantConnect = false

    override init() {
        super.init()
        let d = UserDefaults.standard
        if let t = d.object(forKey: "lastBatteryAt") as? Double, d.object(forKey: "lastBatteryPct") != nil {
            lastBattery = (d.double(forKey: "lastBatteryPct"), Date(timeIntervalSince1970: t))
        }
        batteryHistory = (d.array(forKey: "batteryHistory") as? [[Double]] ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.octa.personalwhoop.central"])
    }

    private func setBattery(_ v: Double) {
        batteryPercent = v
        lastBattery = (v, Date())
        UserDefaults.standard.set(v, forKey: "lastBatteryPct")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastBatteryAt")
        let now = Date().timeIntervalSince1970
        if let last = batteryHistory.last, now - last.t < 300, abs(last.soc - v) < 1 {} else {
            batteryHistory.append((now, v))
            if batteryHistory.count > 600 { batteryHistory.removeFirst(batteryHistory.count - 600) }
            UserDefaults.standard.set(batteryHistory.map { [$0.t, $0.soc] }, forKey: "batteryHistory")
        }
        onBattery?(v)
    }
    /// Estimated hours until the strap hits 0 %.
    var hoursToEmpty: Double? {
        guard let cur = batteryPercent ?? lastBattery?.percent else { return nil }
        var s = batteryHistory
        if s.last?.soc != cur { s.append((lastBattery?.at.timeIntervalSince1970 ?? Date().timeIntervalSince1970, cur)) }
        return BatteryEstimator.hoursToEmpty(series: s, ratedHours: family == .whoop5 ? BatteryEstimator.ratedHours5 : BatteryEstimator.ratedHours4)
    }

    private func note(_ s: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(s)")
        if log.count > 200 { log.removeFirst(50) }
    }

    func connect() {
        wantConnect = true
        guard central.state == .poweredOn else { state = .off; return }
        let services = [CBUUID(string: WhoopUUID.service4), CBUUID(string: WhoopUUID.service5), CBUUID(string: WhoopUUID.hrService)]
        if let p = central.retrieveConnectedPeripherals(withServices: services).first {
            adopt(p); return
        }
        state = .scanning
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        note("Scanning for WHOOP / HR strap")
    }

    func disconnect() {
        wantConnect = false
        keepAlive?.invalidate()
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        state = .idle
    }

    private func adopt(_ p: CBPeripheral) {
        peripheral = p; p.delegate = self
        deviceName = p.name
        state = .connecting
        central.stopScan()
        central.connect(p)
    }

    // MARK: commands (reversible subset only)
    func send(_ cmd: WhoopCommand, payload: [UInt8] = [0x00], withResponse: Bool = true) {
        guard let p = peripheral, let c = cmdChar, let fam = family else { note("Not connected — can't send \(cmd)"); return }
        seq &+= 1
        let bytes = FrameCodec.build(family: fam, cmd, seq: seq, payload: payload)
        p.writeValue(Data(bytes), for: c, type: withResponse ? .withResponse : .withoutResponse)
        note("→ \(cmd) seq \(seq)")
    }

    func buzz(loops: UInt8) { send(.runHapticsPattern, payload: WhoopPayload.haptics(loops: loops)) }
    func syncClock() {
        let now = UInt32(Date().timeIntervalSince1970)
        send(.setClock, payload: WhoopPayload.setClock(now))
        if family == .whoop4 { send(.setClock, payload: WhoopPayload.setClock(now, legacy: true)) }
    }
    func armAlarm(at date: Date) {
        guard family == .whoop4 else { note("Strap alarm arming is only wired for WHOOP 4.0 (5/MG is experimental)"); return }
        syncClock()
        send(.setAlarmTime, payload: WhoopPayload.setAlarm4(epoch: UInt32(date.timeIntervalSince1970)))
        send(.getAlarmTime, payload: [0x01])
    }
    func disarmAlarm() { send(.disableAlarm, payload: WhoopPayload.disableAlarm4) }
    func requestBattery() { send(.getBatteryLevel) }

    private func startKeepAlive() {
        keepAlive?.invalidate()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, !self.isBusy() else { return }; self.requestBattery(); self.peripheral?.readRSSI() }
        }
    }

    private func ingestHR(bpm: Int, rr: [Double]) {
        guard (30...220).contains(bpm) else { return }
        let t = Date().timeIntervalSince1970
        hrWindow.append((t, Double(bpm))); hrWindow.removeAll { t - $0.t > 10 }
        let sorted = hrWindow.map(\.bpm).sorted()
        heartRate = Int(sorted[sorted.count / 2])           // median of ~10 s window
        lastRR = rr
        onHR?(bpm, rr)
    }
}

extension BLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            if c.state == .poweredOn { state = .idle; if wantConnect { connect() } } else { state = .off }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            Task { @MainActor in adopt(p) }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        Task { @MainActor in note("Found \(p.name ?? "device") (\(rssi) dBm)"); adopt(p) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in note("Connected"); p.discoverServices(nil) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in note("Connect failed: \(error?.localizedDescription ?? "?")"); state = .idle; if wantConnect { central.connect(p) } }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            note("Disconnected")
            state = .idle; heartRate = nil; cmdChar = nil; keepAlive?.invalidate()
            onDisconnect?()
            // Standing connect: no timeout, iOS wakes the app when the strap returns.
            if wantConnect { state = .connecting; central.connect(p) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in p.services?.forEach { p.discoverCharacteristics(nil, for: $0) } }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        Task { @MainActor in
            let id = s.uuid.uuidString.lowercased()
            if id == WhoopUUID.service4 { family = .whoop4; reassembler = Reassembler(family: .whoop4) }
            if id == WhoopUUID.service5 { family = .whoop5; reassembler = Reassembler(family: .whoop5) }
            for ch in s.characteristics ?? [] {
                let cid = ch.uuid.uuidString.lowercased()
                switch cid {
                case WhoopUUID.hrMeasurement.lowercased(), "2a37": p.setNotifyValue(true, for: ch)
                case "2a19": p.readValue(for: ch); if family == .whoop5 { p.setNotifyValue(true, for: ch) }
                case WhoopUUID.cmdWrite4:
                    cmdChar = ch
                    // Just-works bonding with one confirmed write: a benign GET_BATTERY_LEVEL.
                    requestBattery()
                case WhoopUUID.cmdResp4, WhoopUUID.events4, WhoopUUID.data4: p.setNotifyValue(true, for: ch)
                case WhoopUUID.cmdWrite5: cmdChar = ch
                default:
                    if cid.hasPrefix("fd4b000") && cid != WhoopUUID.cmdWrite5 { p.setNotifyValue(true, for: ch) }
                }
            }
            state = .connected
            deviceName = p.name
            startKeepAlive()
            if family == .whoop4 { syncClock() }   // timestamps in history must line up with wall time
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.onReady?() }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        let bytes = [UInt8](data)
        Task { @MainActor in
            let id = ch.uuid.uuidString.lowercased()
            if id == "2a37" {
                if let r = WhoopDecoder.standardHR(bytes) { ingestHR(bpm: r.bpm, rr: r.rrMs) }
            } else if id == "2a19", let b = bytes.first, family != .whoop4 {
                setBattery(Double(b))           // 4.0's 2A19 is a stub constant of 100
            } else {
                let frames = reassembler.feed(bytes)
                lastFrameCount += frames.count
                for f in frames { handle(f) }
            }
        }
    }

    @MainActor private func handle(_ f: Frame) {
        switch f.type {
        case PacketType.historical.rawValue, PacketType.metadata.rawValue:
            onHistoryFrame?(f)
        case PacketType.commandResponse.rawValue:
            if f.command == WhoopCommand.getBatteryLevel.rawValue, f.payload.count >= 3 {
                // result byte at payload[?]; battery u16 follows. Logged, never trusted blindly.
                let raw = UInt16(f.payload[f.payload.count >= 4 ? 2 : 1]) | UInt16(f.payload[f.payload.count >= 4 ? 3 : 2]) << 8
                if raw <= 1000 { setBattery(WhoopDecoder.batteryPercent(u16Value: raw)) }
            }
        case PacketType.event.rawValue:
            let ev = f.inner.count > 3 ? f.inner[3] : 0
            switch ev {
            case 9: wristOn = true
            case 10: wristOn = false
            case 14: note("Double-tap"); NotificationCenter.default.post(name: .strapDoubleTap, object: nil)
            case 57: note("Strap alarm executed"); NotificationCenter.default.post(name: .strapAlarmFired, object: nil)
            default: break
            }
        default: break
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let e = error { note("Write failed: \(e.localizedDescription)") } else { note("Write acknowledged") }
        }
    }
}

extension Notification.Name {
    static let strapAlarmFired = Notification.Name("strapAlarmFired")
    static let strapDoubleTap = Notification.Name("strapDoubleTap")
}
