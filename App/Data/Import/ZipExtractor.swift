import Foundation
import Compression

enum ZipError: LocalizedError {
    case notZip, entryNotFound(String), unsupported(String), corrupt, io(String)
    var errorDescription: String? {
        switch self {
        case .notZip: return "This file isn't a ZIP-based backup."
        case .entryNotFound(let n): return "The backup is missing \(n)."
        case .unsupported(let s): return "Unsupported backup format (\(s))."
        case .corrupt: return "The backup file looks damaged."
        case .io(let s): return s
        }
    }
}

/// Minimal ZIP reader (stored + deflate, no ZIP64). Streams, so a 500 MB database never sits in memory.
final class ZipArchive {
    struct Entry { var name: String; var method: UInt16; var compressedSize: Int; var uncompressedSize: Int; var localOffset: Int }

    private let handle: FileHandle
    private(set) var entries: [String: Entry] = [:]

    init(url: URL) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ZipError.io("Couldn't open the file.") }
        handle = h
        try parseCentralDirectory()
    }
    deinit { try? handle.close() }

    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    private func parseCentralDirectory() throws {
        let size = Int(try handle.seekToEnd())
        let tailLen = min(size, 65_557)
        try handle.seek(toOffset: UInt64(size - tailLen))
        guard let tail = try handle.read(upToCount: tailLen), tail.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        for i in stride(from: tail.count - 22, through: 0, by: -1) where Self.u32(tail, i) == 0x06054b50 { eocd = i; break }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = Self.u16(tail, eocd + 10), cdSize = Self.u32(tail, eocd + 12), cdOffset = Self.u32(tail, eocd + 16)
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
        try handle.seek(toOffset: UInt64(cdOffset))
        guard let cd = try handle.read(upToCount: cdSize), cd.count == cdSize else { throw ZipError.corrupt }
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, Self.u32(cd, p) == 0x02014b50 else { throw ZipError.corrupt }
            let method = Self.u16(cd, p + 10), comp = Self.u32(cd, p + 20), uncomp = Self.u32(cd, p + 24)
            let nameLen = Self.u16(cd, p + 28), extraLen = Self.u16(cd, p + 30), commentLen = Self.u16(cd, p + 32), local = Self.u32(cd, p + 42)
            let name = String(decoding: cd[(cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(name: name, method: UInt16(method), compressedSize: comp, uncompressedSize: uncomp, localOffset: local)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    /// Reads a small entry fully into memory.
    func data(for name: String) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try extract(name, to: tmp, progress: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try Data(contentsOf: tmp)
    }

    func extract(_ name: String, to dest: URL, progress: ((Double) -> Void)?) throws {
        guard let e = entries[name] else { throw ZipError.entryNotFound(name) }
        try handle.seek(toOffset: UInt64(e.localOffset))
        guard let lh = try handle.read(upToCount: 30), lh.count == 30, Self.u32(lh, 0) == 0x04034b50 else { throw ZipError.corrupt }
        let start = e.localOffset + 30 + Self.u16(lh, 26) + Self.u16(lh, 28)
        try handle.seek(toOffset: UInt64(start))
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: dest) else { throw ZipError.io("Couldn't write a temporary file.") }
        defer { try? out.close() }

        let chunk = 1 << 20
        var remaining = e.compressedSize
        if e.method == 0 {
            var written = 0
            while remaining > 0, let d = try handle.read(upToCount: min(chunk, remaining)), !d.isEmpty {
                try out.write(contentsOf: d); remaining -= d.count; written += d.count
                progress?(Double(written) / Double(max(e.uncompressedSize, 1)))
            }
            return
        }
        guard e.method == 8 else { throw ZipError.unsupported("compression method \(e.method)") }

        // raw DEFLATE (Apple's COMPRESSION_ZLIB decodes raw deflate)
        let dstCap = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { dst.deallocate(); compression_stream_destroy(stream); stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ZipError.corrupt }
        stream.pointee.dst_ptr = dst; stream.pointee.dst_size = dstCap
        var produced = 0
        var finished = false
        while !finished {
            let want = min(chunk, remaining)
            let input = want > 0 ? (try handle.read(upToCount: want) ?? Data()) : Data()
            remaining -= input.count
            let isLast = remaining <= 0 || input.isEmpty
            try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
                stream.pointee.src_size = input.count
                var status: compression_status
                var outputFull: Bool
                repeat {
                    status = compression_stream_process(stream, isLast ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    guard status != COMPRESSION_STATUS_ERROR else { throw ZipError.corrupt }
                    let n = dstCap - stream.pointee.dst_size
                    outputFull = stream.pointee.dst_size == 0          // more output may be waiting, even with no input left
                    if n > 0 { try out.write(contentsOf: Data(bytes: dst, count: n)); produced += n }
                    stream.pointee.dst_ptr = dst; stream.pointee.dst_size = dstCap
                    if status == COMPRESSION_STATUS_END { finished = true }
                } while status == COMPRESSION_STATUS_OK && (stream.pointee.src_size > 0 || outputFull || isLast) && !finished   // once finalizing, keep going until END
            }
            progress?(Double(produced) / Double(max(e.uncompressedSize, 1)))
            if isLast && !finished { finished = true }
        }
    }
}
