import Foundation
import WhoopProtocol

/// One decoded second of strap history.
struct HistoryRecord: Equatable {
    var unix: UInt32
    var hr: UInt8
    var rr: [UInt16]                         // ms, up to 4
    var gravity: (Float, Float, Float)?
    var wrist: UInt8                         // 0 unknown, 1 off wrist, 2 on wrist

    init(_ s: HistoricalSample) {
        unix = s.unix; hr = s.heartRate; rr = s.rr; gravity = s.gravity
        wrist = s.onWrist == nil ? 0 : (s.onWrist! ? 2 : 1)
    }
    init(unix: UInt32, hr: UInt8, rr: [UInt16], gravity: (Float, Float, Float)?, wrist: UInt8) {
        self.unix = unix; self.hr = hr; self.rr = rr; self.gravity = gravity; self.wrist = wrist
    }
    static func == (a: HistoryRecord, b: HistoryRecord) -> Bool { a.unix == b.unix && a.hr == b.hr && a.rr == b.rr }
}

/// Append-only binary log of strap history (28 bytes per record), de-duplicated by timestamp.
/// An actor, so decoding a big first sync never touches the main thread.
actor HistoryStore {
    static let recordSize = 28
    private var records: [HistoryRecord] = []
    private var seen = Set<UInt32>()
    private var loaded = false
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("strap-history.bin")
    }()

    var count: Int { records.count }
    var range: (first: UInt32, last: UInt32)? { records.first.map { ($0.unix, records.last!.unix) } }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let d = try? Data(contentsOf: url) else { return }
        records.reserveCapacity(d.count / Self.recordSize)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var o = 0
            while o + Self.recordSize <= raw.count {
                let u = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)
                let hr = raw[o + 4], n = Int(raw[o + 5]), flags = raw[o + 6]
                var rr: [UInt16] = []
                for i in 0..<min(n, 4) { rr.append(raw.loadUnaligned(fromByteOffset: o + 7 + 2 * i, as: UInt16.self)) }
                var g: (Float, Float, Float)?
                if flags & 0x04 != 0 {
                    g = (raw.loadUnaligned(fromByteOffset: o + 15, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 19, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 23, as: Float.self))
                }
                if seen.insert(u).inserted { records.append(HistoryRecord(unix: u, hr: hr, rr: rr, gravity: g, wrist: flags & 0x03)) }
                o += Self.recordSize
            }
        }
        records.sort { $0.unix < $1.unix }
    }

    /// Adds new records, skipping timestamps already stored. Returns how many were new.
    @discardableResult
    func append(_ batch: [HistoryRecord]) -> Int {
        load()
        var fresh: [HistoryRecord] = []
        for r in batch where seen.insert(r.unix).inserted { fresh.append(r) }
        guard !fresh.isEmpty else { return 0 }
        var data = Data(capacity: fresh.count * Self.recordSize)
        for r in fresh {
            var rec = [UInt8](repeating: 0, count: Self.recordSize)
            withUnsafeBytes(of: r.unix) { rec.replaceSubrange(0..<4, with: $0) }
            rec[4] = r.hr; rec[5] = UInt8(min(r.rr.count, 4))
            var flags = r.wrist & 0x03
            for (i, v) in r.rr.prefix(4).enumerated() { withUnsafeBytes(of: v) { rec.replaceSubrange((7 + 2 * i)..<(9 + 2 * i), with: $0) } }
            if let g = r.gravity {
                flags |= 0x04
                withUnsafeBytes(of: g.0) { rec.replaceSubrange(15..<19, with: $0) }
                withUnsafeBytes(of: g.1) { rec.replaceSubrange(19..<23, with: $0) }
                withUnsafeBytes(of: g.2) { rec.replaceSubrange(23..<27, with: $0) }
            }
            rec[6] = flags
            data.append(contentsOf: rec)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close()
        } else { try? data.write(to: url) }
        records.append(contentsOf: fresh)
        records.sort { $0.unix < $1.unix }
        return fresh.count
    }

    func window(from: Date, to: Date = Date()) -> [HistoryRecord] {
        load()
        let a = UInt32(max(0, from.timeIntervalSince1970)), b = UInt32(max(0, to.timeIntervalSince1970))
        // binary search for the first record >= a
        var lo = 0, hi = records.count
        while lo < hi { let m = (lo + hi) / 2; if records[m].unix < a { lo = m + 1 } else { hi = m } }
        var out: [HistoryRecord] = []
        var i = lo
        while i < records.count, records[i].unix <= b { out.append(records[i]); i += 1 }
        return out
    }

    /// Drops anything older than `days` and rewrites the file.
    func trim(keepDays days: Int) {
        load()
        let cutoff = UInt32(max(0, Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970))
        guard let first = records.first, first.unix < cutoff else { return }
        records.removeAll { $0.unix < cutoff }
        seen = Set(records.map(\.unix))
        try? FileManager.default.removeItem(at: url)
        let keep = records; records = []; seen = []; loaded = true
        append(keep)
    }

    func clear() { records = []; seen = []; loaded = true; try? FileManager.default.removeItem(at: url) }
}
