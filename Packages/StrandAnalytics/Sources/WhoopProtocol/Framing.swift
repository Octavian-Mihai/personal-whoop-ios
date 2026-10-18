import Foundation

/// WHOOP 4.0 / 5-MG framing (spec §14.10). Little-endian throughout. Read-only / reversible commands only.
public enum WhoopFamily: String, Sendable { case whoop4, whoop5 }

public enum WhoopUUID {
    public static let service4 = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
    public static let service5 = "fd4b0001-cce1-4033-93ce-002d5875f58a"
    public static let cmdWrite4 = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
    public static let cmdResp4 = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
    public static let events4 = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
    public static let data4 = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"
    public static let cmdWrite5 = "fd4b0002-cce1-4033-93ce-002d5875f58a"
    public static let hrService = "180D", hrMeasurement = "2A37"
    public static let batteryService = "180F", batteryLevel = "2A19"
}

public enum Checksum {
    public static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for b in bytes {
            crc ^= b
            for _ in 0..<8 { crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }
    public static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

public enum PacketType: UInt8, Sendable {
    case command = 35, commandResponse = 36, realtimeData = 40, realtimeRaw = 43
    case historical = 47, event = 48, metadata = 49, consoleLogs = 50
}

/// Commands NOOP may send. Deliberately has no case for destructive opcodes
/// (FORCE_TRIM 25, firmware load 36–38, ENTER_BLE_DFU 45, RESET_FUEL_GAUGE 99).
public enum WhoopCommand: UInt8, Sendable, CaseIterable {
    case toggleRealtimeHR = 3, reportVersionInfo = 7, setClock = 10, getClock = 11
    case toggleGenericHRProfile = 14, abortHistoricalTransmits = 20, sendHistoricalData = 22
    case historicalDataResult = 23, getBatteryLevel = 26, getDataRange = 34, getHelloHarvard = 35
    case sendR10R11Realtime = 63, setAlarmTime = 66, getAlarmTime = 67, runAlarm = 68, disableAlarm = 69
    case runHapticsPattern = 79, stopHaptics = 122, getHello = 145
}

public enum FrameReject: Error, Equatable {
    case noStartOfFrame, belowMinimumLength, lengthMismatch, headerChecksumMismatch, payloadCRCMismatch
}

public struct Frame: Equatable, Sendable {
    public var family: WhoopFamily
    public var inner: [UInt8]
    /// The whole verified frame (absolute offsets in the protocol notes refer to this).
    public var raw: [UInt8] = []
    public init(family: WhoopFamily, inner: [UInt8], raw: [UInt8] = []) { self.family = family; self.inner = inner; self.raw = raw }
    public var type: UInt8 { inner.first ?? 0 }
    public var seq: UInt8 { inner.count > 1 ? inner[1] : 0 }
    public var command: UInt8 { inner.count > 2 ? inner[2] : 0 }
    public var payload: [UInt8] { inner.count > 3 ? Array(inner[3...]) : [] }
}

public enum FrameCodec {
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    /// Build a command frame. 4.0: AA len16 crc8 inner crc32. 5/MG: AA 01 declLen16 00 01 crc16 inner(padded) crc32.
    public static func build(family: WhoopFamily, type: PacketType = .command, seq: UInt8, command: UInt8, payload: [UInt8] = [0x00]) -> [UInt8] {
        var inner: [UInt8] = [type.rawValue, seq, command] + payload
        switch family {
        case .whoop4:
            let len = UInt16(inner.count + 4)
            let lenBytes = le16(len)
            return [0xAA] + lenBytes + [Checksum.crc8(lenBytes)] + inner + le32(Checksum.crc32(inner))
        case .whoop5:
            while inner.count % 4 != 0 { inner.append(0) }
            let declLen = UInt16(inner.count + 4)
            let head: [UInt8] = [0xAA, 0x01] + le16(declLen) + [0x00, 0x01]
            return head + le16(Checksum.crc16Modbus(head)) + inner + le32(Checksum.crc32(inner))
        }
    }

    public static func build(family: WhoopFamily, _ cmd: WhoopCommand, seq: UInt8, payload: [UInt8] = [0x00]) -> [UInt8] {
        build(family: family, seq: seq, command: cmd.rawValue, payload: payload)
    }

    public static func verify(_ bytes: [UInt8], family: WhoopFamily) -> Result<Frame, FrameReject> {
        guard bytes.first == 0xAA else { return .failure(.noStartOfFrame) }
        switch family {
        case .whoop4:
            guard bytes.count >= 11 else { return .failure(.belowMinimumLength) }
            let len = Int(bytes[1]) | Int(bytes[2]) << 8
            guard bytes.count == len + 4 else { return .failure(.lengthMismatch) }
            guard Checksum.crc8([bytes[1], bytes[2]]) == bytes[3] else { return .failure(.headerChecksumMismatch) }
            let inner = Array(bytes[4..<(bytes.count - 4)])
            let crc = UInt32(bytes[bytes.count - 4]) | UInt32(bytes[bytes.count - 3]) << 8 | UInt32(bytes[bytes.count - 2]) << 16 | UInt32(bytes[bytes.count - 1]) << 24
            guard Checksum.crc32(inner) == crc else { return .failure(.payloadCRCMismatch) }
            return .success(Frame(family: family, inner: inner, raw: bytes))
        case .whoop5:
            guard bytes.count >= 13 else { return .failure(.belowMinimumLength) }
            let decl = Int(bytes[2]) | Int(bytes[3]) << 8
            guard bytes.count == decl + 8 else { return .failure(.lengthMismatch) }
            let hc = UInt16(bytes[6]) | UInt16(bytes[7]) << 8
            guard Checksum.crc16Modbus(Array(bytes[0..<6])) == hc else { return .failure(.headerChecksumMismatch) }
            let inner = Array(bytes[8..<(bytes.count - 4)])
            let crc = UInt32(bytes[bytes.count - 4]) | UInt32(bytes[bytes.count - 3]) << 8 | UInt32(bytes[bytes.count - 2]) << 16 | UInt32(bytes[bytes.count - 1]) << 24
            guard Checksum.crc32(inner) == crc else { return .failure(.payloadCRCMismatch) }
            return .success(Frame(family: family, inner: inner, raw: bytes))
        }
    }
}

/// Joins notification fragments, resyncs on the next 0xAA after a bad length, drops frames > 8192 bytes.
public struct Reassembler: Sendable {
    public let family: WhoopFamily
    var buffer: [UInt8] = []
    public init(family: WhoopFamily) { self.family = family }

    public mutating func feed(_ chunk: [UInt8]) -> [Frame] {
        buffer += chunk
        var out: [Frame] = []
        while true {
            guard let start = buffer.firstIndex(of: 0xAA) else { buffer.removeAll(); break }
            if start > 0 { buffer.removeFirst(start) }
            let total: Int
            switch family {
            case .whoop4:
                guard buffer.count >= 4 else { return out }
                total = (Int(buffer[1]) | Int(buffer[2]) << 8) + 4
            case .whoop5:
                guard buffer.count >= 4 else { return out }
                total = (Int(buffer[2]) | Int(buffer[3]) << 8) + 8
            }
            if total > 8192 || total < 8 { buffer.removeFirst(); continue }
            guard buffer.count >= total else { return out }
            let frameBytes = Array(buffer[0..<total])
            switch FrameCodec.verify(frameBytes, family: family) {
            case .success(let f): out.append(f); buffer.removeFirst(total)
            case .failure: buffer.removeFirst()
            }
        }
        return out
    }
}

// MARK: - Payload builders

public enum WhoopPayload {
    /// SET_CLOCK: seconds u32 + 4 zero bytes (8 B); a 4.0 also gets the legacy 9-byte form.
    public static func setClock(_ unix: UInt32, legacy: Bool = false) -> [UInt8] {
        FrameCodec.le32(unix) + [UInt8](repeating: 0, count: legacy ? 5 : 4)
    }
    /// 4.0 SET_ALARM_TIME 9-byte payload.
    public static func setAlarm4(epoch: UInt32) -> [UInt8] { [0x01] + FrameCodec.le32(epoch) + [0, 0] + [0, 0] }
    public static func haptics(patternId: UInt8 = 2, loops: UInt8) -> [UInt8] { [patternId, loops, 0, 0, 0] }
    public static let disableAlarm4: [UInt8] = [0x01]
    /// Ack for a HISTORY_END chunk: command 23 payload `[0x01] + end_data` verbatim.
    public static func historyAck(endData: [UInt8]) -> [UInt8] { [0x01] + endData }
}

// MARK: - Decoding

public struct HistoricalSample: Sendable, Equatable {
    public var unix: UInt32
    public var heartRate: UInt8
    public var rr: [UInt16]
    public var gravity: (Float, Float, Float)?
    public var onWrist: Bool?
    public static func == (a: Self, b: Self) -> Bool { a.unix == b.unix && a.heartRate == b.heartRate && a.rr == b.rr }
}

public enum WhoopDecoder {
    static let minUnix: UInt32 = 1_698_796_800 // 2023-11-01

    static func u32(_ f: [UInt8], _ o: Int) -> UInt32? { o + 4 <= f.count ? UInt32(f[o]) | UInt32(f[o+1]) << 8 | UInt32(f[o+2]) << 16 | UInt32(f[o+3]) << 24 : nil }
    static func u16(_ f: [UInt8], _ o: Int) -> UInt16? { o + 2 <= f.count ? UInt16(f[o]) | UInt16(f[o+1]) << 8 : nil }
    static func f32(_ f: [UInt8], _ o: Int) -> Float? { u32(f, o).map { Float(bitPattern: $0) } }

    /// Decode a type-47 record from a verified frame's *raw bytes* (offsets are absolute frame offsets).
    /// 4.0: version = seq byte (frame[5]); 5/MG: version at frame[9] and only v18 has a field map — other versions return nil (archive, never guess).
    public static func historical(raw: [UInt8], family: WhoopFamily, now: UInt32) -> HistoricalSample? {
        switch family {
        case .whoop4:
            guard raw.count > 25, let t = u32(raw, 11), t >= minUnix, t <= now &+ 86400 else { return nil }
            let version = raw[5]
            let hr = raw[21]
            guard (25...230).contains(Int(hr)) || hr == 0 else { return nil }
            let n = min(Int(raw[22]), 4)
            var rr: [UInt16] = []
            for i in 0..<n { if let v = u16(raw, 23 + 2 * i), v >= 250, v <= 2500 { rr.append(v) } }
            var g: (Float, Float, Float)?
            var wrist: Bool?
            if raw.count > 56, version == 24 || version == 12 {
                if let x = f32(raw, 40), let y = f32(raw, 44), let z = f32(raw, 48), x.isFinite, y.isFinite, z.isFinite, abs(x) < 20, abs(y) < 20, abs(z) < 20 { g = (x, y, z) }
                wrist = raw[55] != 0
            }
            return HistoricalSample(unix: t, heartRate: hr, rr: rr, gravity: g, onWrist: wrist)
        case .whoop5:
            guard raw.count > 58, raw[9] == 18, let t = u32(raw, 15), t >= minUnix, t <= now &+ 86400 else { return nil }
            let n = min(Int(raw[23]), 4)
            var rr: [UInt16] = []
            for i in 0..<n { if let v = u16(raw, 24 + 2 * i), v >= 250, v <= 2500 { rr.append(v) } }   // 5/MG R-R words are already ms
            var g: (Float, Float, Float)?
            if let x = f32(raw, 45), let y = f32(raw, 49), let z = f32(raw, 53), x.isFinite, y.isFinite, z.isFinite, abs(x) < 20, abs(y) < 20, abs(z) < 20 { g = (x, y, z) }
            return HistoricalSample(unix: t, heartRate: raw[22], rr: rr, gravity: g, onWrist: nil)
        }
    }

    /// Standard Heart Rate Measurement (0x2A37) with optional R-R in 1/1024 s.
    public static func standardHR(_ d: [UInt8]) -> (bpm: Int, rrMs: [Double])? {
        guard d.count >= 2 else { return nil }
        let flags = d[0]
        var i = 1
        let bpm: Int
        if flags & 1 == 0 { bpm = Int(d[i]); i += 1 } else { guard d.count >= 3 else { return nil }; bpm = Int(d[i]) | Int(d[i+1]) << 8; i += 2 }
        if flags & 0x08 != 0 { i += 2 }
        var rr: [Double] = []
        if flags & 0x10 != 0 { while i + 1 < d.count { rr.append(Double(UInt16(d[i]) | UInt16(d[i+1]) << 8) / 1024 * 1000); i += 2 } }
        return (bpm, rr)
    }

    /// Battery reply: percent = u16 / 10.
    public static func batteryPercent(u16Value: UInt16) -> Double { Double(u16Value) / 10 }
}

/// What a frame means in the history offload (spec §14.8 / §14.10).
public enum HistoryEvent: Equatable {
    case started
    case record(HistoricalSample)
    /// End of a chunk. `endData` is the 8-byte block the strap wants echoed back to free the chunk.
    case chunkEnd(endData: [UInt8], trimCursor: UInt32)
    case complete
}

public enum HistoryProtocol {
    /// METADATA meta types: 1 start, 2 end of chunk, 3 complete. Absolute frame offset 6 = `inner[2]` in both families.
    public static func parse(_ f: Frame, now: UInt32) -> HistoryEvent? {
        switch f.type {
        case PacketType.metadata.rawValue:
            switch f.inner.count > 2 ? f.inner[2] : 0 {
            case 1: return .started
            case 2:
                // end_data = frame[17..<25) on a 4.0, frame[21..<29) on a 5/MG → inner[13..<21] in both
                guard f.inner.count >= 21 else { return nil }
                let end = Array(f.inner[13..<21])
                let cursor = UInt32(end[0]) | UInt32(end[1]) << 8 | UInt32(end[2]) << 16 | UInt32(end[3]) << 24
                return .chunkEnd(endData: end, trimCursor: cursor)
            case 3: return .complete
            default: return nil
            }
        case PacketType.historical.rawValue:
            return WhoopDecoder.historical(raw: f.raw, family: f.family, now: now).map { .record($0) }
        default: return nil
        }
    }

    /// The acknowledgement that lets the strap free a chunk: command 23, payload `[0x01] + end_data`, sent as an acknowledged write.
    public static func ackPayload(endData: [UInt8]) -> [UInt8] { WhoopPayload.historyAck(endData: endData) }
}
