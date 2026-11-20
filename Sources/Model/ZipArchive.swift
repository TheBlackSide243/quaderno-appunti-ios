import Compression
import Foundation

/// Writes a zip archive one file at a time, straight to disk, so a large library never has to fit
/// in memory. Text-like files are deflated; pictures, PDFs and recordings (already compressed)
/// are stored as they are. With more than 65,535 files or more than 4 GB before the directory
/// the archive gets the zip64 records, which the Files app and every unzip tool read.
final class ZipWriter {
    private struct Entry {
        var name: [UInt8]
        var crc: UInt32
        var packed: UInt64
        var size: UInt64
        var method: UInt16
        var offset: UInt64
        var time: UInt16
        var date: UInt16
    }

    enum Failure: LocalizedError {
        case tooLarge
        var errorDescription: String? { String(localized: "Un file è troppo grande per la copia (più di 4 GB).") }
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private var closed = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    /// Extensions worth deflating: the rest is already compressed.
    private static let squeezable: Set<String> = ["json", "drawing", "rtf", "txt", "md", "plist", "svg"]

    func add(_ name: String, file: URL) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        try add(name, data: data, modified: date)
    }

    func add(_ name: String, data: Data, modified: Date = Date()) throws {
        guard data.count < 0xFFFF_FFFF else { throw Failure.tooLarge }
        let ext = (name as NSString).pathExtension.lowercased()
        var method: UInt16 = 0
        var body = data
        if Self.squeezable.contains(ext), data.count > 64, let packed = Self.deflate(data), packed.count < data.count * 9 / 10 {
            method = 8
            body = packed
        }
        let (time, day) = Self.dosTime(modified)
        let e = Entry(name: Array(name.utf8), crc: CRC32.checksum(data), packed: UInt64(body.count), size: UInt64(data.count),
                      method: method, offset: offset, time: time, date: day)
        var h = Bytes()
        h.u32(0x0403_4b50)
        h.u16(20)                 // version needed
        h.u16(0x0800)             // names in UTF-8
        h.u16(method)
        h.u16(time)
        h.u16(day)
        h.u32(e.crc)
        h.u32(UInt32(e.packed))
        h.u32(UInt32(e.size))
        h.u16(UInt16(e.name.count))
        h.u16(0)
        h.raw(e.name)
        try write(h.data)
        try write(body)
        entries.append(e)
    }

    /// Writes the directory at the end. The archive is complete only after this.
    func finish() throws {
        guard !closed else { return }
        closed = true
        let start = offset
        for e in entries {
            let far = e.offset >= 0xFFFF_FFFF
            var c = Bytes()
            c.u32(0x0201_4b50)
            c.u16(far ? 45 : 20)  // made by
            c.u16(far ? 45 : 20)  // needed
            c.u16(0x0800)
            c.u16(e.method)
            c.u16(e.time)
            c.u16(e.date)
            c.u32(e.crc)
            c.u32(UInt32(e.packed))
            c.u32(UInt32(e.size))
            c.u16(UInt16(e.name.count))
            c.u16(far ? 12 : 0)   // extra
            c.u16(0)              // comment
            c.u16(0)              // disk
            c.u16(0)              // internal attributes
            c.u32(0)              // external attributes
            c.u32(far ? 0xFFFF_FFFF : UInt32(e.offset))
            c.raw(e.name)
            if far {
                c.u16(0x0001)
                c.u16(8)
                c.u64(e.offset)
            }
            try write(c.data)
        }
        let size = offset - start
        let zip64 = entries.count >= 0xFFFF || start >= 0xFFFF_FFFF || size >= 0xFFFF_FFFF
        if zip64 {
            let record = offset
            var z = Bytes()
            z.u32(0x0606_4b50)
            z.u64(44)
            z.u16(45)
            z.u16(45)
            z.u32(0)
            z.u32(0)
            z.u64(UInt64(entries.count))
            z.u64(UInt64(entries.count))
            z.u64(size)
            z.u64(start)
            z.u32(0x0706_4b50)    // locator
            z.u32(0)
            z.u64(record)
            z.u32(1)
            try write(z.data)
        }
        var end = Bytes()
        end.u32(0x0605_4b50)
        end.u16(0)
        end.u16(0)
        end.u16(zip64 ? 0xFFFF : UInt16(entries.count))
        end.u16(zip64 ? 0xFFFF : UInt16(entries.count))
        end.u32(zip64 ? 0xFFFF_FFFF : UInt32(size))
        end.u32(zip64 ? 0xFFFF_FFFF : UInt32(start))
        end.u16(0)
        try write(end.data)
        try handle.close()
    }

    var count: Int { entries.count }

    private func write(_ d: Data) throws {
        try handle.write(contentsOf: d)
        offset += UInt64(d.count)
    }

    /// Raw deflate (what zip calls method 8); nil when it does not get smaller.
    static func deflate(_ data: Data) -> Data? {
        let cap = data.count
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        out.count = n
        return out
    }

    /// The date as MS-DOS keeps it (local time, two-second steps, from 1980).
    static func dosTime(_ d: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let year = max(1980, min(2107, c.year ?? 1980))
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

/// Reads a zip archive from disk without loading it whole: only the directory and the file asked
/// for are read. Stored and deflated files, with or without the zip64 records.
final class ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let packed: UInt64
        let size: UInt64
        let offset: UInt64
    }

    enum Failure: LocalizedError {
        case unreadable
        case damaged(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "Il file non è un archivio zip leggibile.")
            case .damaged(let name): return String(localized: "Nell'archivio il file «\(name)» è rovinato.")
            }
        }
    }

    private let handle: FileHandle
    private(set) var entries: [Entry] = []

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw Failure.unreadable }
        let tailLength = min(length, 65_557 + 20)
        let tailStart = length - tailLength
        let tail = [UInt8](try read(at: tailStart, count: Int(tailLength)))
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4b, tail[i + 2] == 0x05, tail[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.unreadable }
        var count = UInt64(Self.le16(tail, eocd + 10))
        var size = UInt64(Self.le32(tail, eocd + 12))
        var start = UInt64(Self.le32(tail, eocd + 16))
        if count == 0xFFFF || size == 0xFFFF_FFFF || start == 0xFFFF_FFFF {
            // the zip64 locator sits right before the usual end record
            let loc = eocd - 20
            guard loc >= 0, Self.le32(tail, loc) == 0x0706_4b50 else { throw Failure.unreadable }
            let record = Self.le64(tail, loc + 8)
            let z = [UInt8](try read(at: record, count: 56))
            guard z.count == 56, Self.le32(z, 0) == 0x0606_4b50 else { throw Failure.unreadable }
            count = Self.le64(z, 32)
            size = Self.le64(z, 40)
            start = Self.le64(z, 48)
        }
        guard start + size <= length else { throw Failure.unreadable }
        let dir = [UInt8](try read(at: start, count: Int(size)))
        var p = 0
        var list: [Entry] = []
        list.reserveCapacity(Int(min(count, 1_000_000)))
        for _ in 0..<count {
            guard p + 46 <= dir.count, Self.le32(dir, p) == 0x0201_4b50 else { throw Failure.unreadable }
            let method = UInt16(Self.le16(dir, p + 10))
            let crc = UInt32(Self.le32(dir, p + 16))
            var packed = UInt64(Self.le32(dir, p + 20)), unpacked = UInt64(Self.le32(dir, p + 24))
            let nameLen = Self.le16(dir, p + 28), extraLen = Self.le16(dir, p + 30), commentLen = Self.le16(dir, p + 32)
            var local = UInt64(Self.le32(dir, p + 42))
            guard p + 46 + nameLen + extraLen <= dir.count else { throw Failure.unreadable }
            let name = String(decoding: dir[p + 46..<p + 46 + nameLen], as: UTF8.self)
            // zip64: the values that did not fit are in the extra field, in this order
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = Self.le16(dir, e), len = Self.le16(dir, e + 2)
                if id == 0x0001 {
                    var q = e + 4
                    if unpacked == 0xFFFF_FFFF, q + 8 <= e + 4 + len { unpacked = Self.le64(dir, q); q += 8 }
                    if packed == 0xFFFF_FFFF, q + 8 <= e + 4 + len { packed = Self.le64(dir, q); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= e + 4 + len { local = Self.le64(dir, q) }
                }
                e += 4 + len
            }
            list.append(Entry(name: name, method: method, crc: crc, packed: packed, size: unpacked, offset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    deinit { try? handle.close() }

    /// The contents of one file of the archive, checked against its checksum.
    func data(_ e: Entry) throws -> Data {
        let header = [UInt8](try read(at: e.offset, count: 30))
        guard header.count == 30, Self.le32(header, 0) == 0x0403_4b50 else { throw Failure.damaged(e.name) }
        let start = e.offset + 30 + UInt64(Self.le16(header, 26)) + UInt64(Self.le16(header, 28))
        let body = try read(at: start, count: Int(e.packed))
        guard body.count == Int(e.packed) else { throw Failure.damaged(e.name) }
        let out: Data
        switch e.method {
        case 0:
            out = body
        case 8:
            if e.size == 0 { return Data() }
            var buf = Data(count: Int(e.size))
            let n = buf.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, Int(e.size),
                                              src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard n == Int(e.size) else { throw Failure.damaged(e.name) }
            out = buf
        default:
            throw Failure.damaged(e.name)
        }
        guard CRC32.checksum(out) == e.crc else { throw Failure.damaged(e.name) }
        return out
    }

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> Int { le16(b, i) | le16(b, i + 2) << 16 }
    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32 }
}

/// The checksum zip keeps for every file.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { t in
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                for b in buf { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}

/// Little-endian bytes for the zip records.
private struct Bytes {
    var data = Data()
    mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)) }
    mutating func u16(_ v: Int) { u16(UInt16(v)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v & 0xFFFF_FFFF)); u32(UInt32(v >> 32)) }
    mutating func raw(_ b: [UInt8]) { data.append(contentsOf: b) }
}
