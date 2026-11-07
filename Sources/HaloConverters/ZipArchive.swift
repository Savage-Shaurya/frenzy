import Compression
import Darwin
import Foundation
import HaloCore

/// A small, strict ZIP reader and writer on Apple's Compression framework (raw DEFLATE), so Halo needs no
/// third-party code. Classic ZIP only: no Zip64, so archives stay under 4 GB and 65,535 entries.
///
/// The reader treats every archive as hostile: sizes and offsets come from the central directory and are
/// bounds-checked, every entry is decompressed as a stream that stops at its declared size, and the CRC must match.
enum ZipFormat {
    static let localSignature: UInt32 = 0x0403_4b50
    static let centralSignature: UInt32 = 0x0201_4b50
    static let endSignature: UInt32 = 0x0605_4b50
    static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    static let stored: UInt16 = 0
    static let deflated: UInt16 = 8
    /// General purpose flag bits.
    static let encryptedFlag: UInt16 = 1 << 0
    static let utf8Flag: UInt16 = 1 << 11
    static let chunkSize = 1 << 20

    /// DOS date and time (local time, 2 s resolution), as ZIP stores them. Dates before 1980 clamp to 1 Jan 1980.
    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, year >= 1980, year <= 2107 else { return (0, UInt16(1 << 5 | 1)) }
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    static func date(dosTime: UInt16, dosDate: UInt16) -> Date? {
        var c = DateComponents()
        c.year = Int(dosDate >> 9) + 1980
        c.month = Int(dosDate >> 5 & 0x0F)
        c.day = Int(dosDate & 0x1F)
        c.hour = Int(dosTime >> 11)
        c.minute = Int(dosTime >> 5 & 0x3F)
        c.second = Int(dosTime & 0x1F) * 2
        guard (1...12).contains(c.month!), (1...31).contains(c.day!) else { return nil }
        return Calendar(identifier: .gregorian).date(from: c)
    }
}

/// CRC-32 (IEEE), as ZIP uses it.
struct CRC32 {
    private(set) var value: UInt32 = 0

    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    mutating func update(_ data: Data) {
        var c = ~value
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            }
        }
        value = ~c
    }
}

/// Little-endian byte builder for headers.
private struct Bytes {
    var data = Data()
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func raw(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
}

private extension Array where Element == UInt8 {
    func u16(_ at: Int) -> UInt16? {
        guard at >= 0, at + 2 <= count else { return nil }
        return UInt16(self[at]) | UInt16(self[at + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32? {
        guard at >= 0, at + 4 <= count else { return nil }
        return UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }
}

/// Mutable counter shared with a Compression callback.
private final class Counter { var value: Int64 = 0 }

// MARK: - Writer

/// Writes a classic ZIP file. Add entries in order, then `finish()`.
final class ZipWriter {
    /// Largest archive this writer can address without Zip64.
    static let maxBytes: Int64 = Int64(UInt32.max) - 1
    static let maxEntries = Int(UInt16.max) - 1

    private struct Entry {
        let name: [UInt8]
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let offset: UInt32
        let time: UInt16
        let date: UInt16
        let externalAttributes: UInt32
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: Int64 = 0

    init(creating url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ConversionError.writeFailed(url, "The file couldn't be created.")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    /// A folder entry. `path` is relative, with "/" separators and no trailing slash.
    func addDirectory(path: String, modified: Date, permissions: UInt16) throws {
        let name = Array((path + "/").utf8)
        let stamp = ZipFormat.dosDateTime(modified)
        let start = offset
        try write(localHeader(name: name, method: ZipFormat.stored, time: stamp.time, date: stamp.date))
        try append(Entry(name: name, method: ZipFormat.stored, crc: 0, compressedSize: 0, size: 0, offset: try narrow(start),
                         time: stamp.time, date: stamp.date,
                         externalAttributes: UInt32(S_IFDIR | (permissions & 0o777)) << 16 | 0x10))
    }

    /// A file entry read from `source`. `compress: false` stores it as is (for already-compressed formats).
    /// `onBytes` reports how many source bytes were just read.
    func addFile(from source: URL, path: String, modified: Date, permissions: UInt16, compress: Bool,
                 onBytes: (Int) -> Void) throws {
        let name = Array(path.utf8)
        let stamp = ZipFormat.dosDateTime(modified)
        let start = offset
        try write(localHeader(name: name, method: ZipFormat.stored, time: stamp.time, date: stamp.date))
        let dataStart = offset

        var crc = CRC32()
        var size: Int64 = 0
        var method = ZipFormat.stored
        if compress {
            let written = Counter()
            let filter = try OutputFilter(.compress, using: .zlib) { [handle] chunk in
                guard let chunk else { return }
                try handle.write(contentsOf: chunk)
                written.value += Int64(chunk.count)
            }
            try readChunks(source) { chunk in
                crc.update(chunk)
                size += Int64(chunk.count)
                try filter.write(chunk)
                onBytes(chunk.count)
            }
            try filter.finalize()
            offset += written.value
            guard offset <= Self.maxBytes else { throw Self.tooBig }
            method = ZipFormat.deflated
            // Deflate made it bigger (already-compressed data): store it instead.
            if size > 0 && written.value >= size {
                try handle.truncate(atOffset: UInt64(dataStart))
                offset = dataStart
                method = ZipFormat.stored
                // Count again: what is stored must match its own CRC even if the file changed in between.
                crc = CRC32()
                size = 0
                try readChunks(source) { chunk in
                    crc.update(chunk)
                    size += Int64(chunk.count)
                    try write(chunk)
                }
            }
        } else {
            try readChunks(source) { chunk in
                crc.update(chunk)
                size += Int64(chunk.count)
                try write(chunk)
                onBytes(chunk.count)
            }
        }
        let compressedSize = offset - dataStart
        // Patch the local header now that the CRC and sizes are known (no data descriptor needed).
        var patch = Bytes()
        patch.u16(method)
        try handle.seek(toOffset: UInt64(start + 8))
        try handle.write(contentsOf: patch.data)
        patch = Bytes()
        patch.u32(crc.value)
        patch.u32(try narrow(compressedSize))
        patch.u32(try narrow(size))
        try handle.seek(toOffset: UInt64(start + 14))
        try handle.write(contentsOf: patch.data)
        try handle.seekToEnd()
        try append(Entry(name: name, method: method, crc: crc.value, compressedSize: try narrow(compressedSize),
                         size: try narrow(size), offset: try narrow(start), time: stamp.time, date: stamp.date,
                         externalAttributes: UInt32(S_IFREG | (permissions & 0o777)) << 16))
    }

    /// Writes the central directory and closes the file.
    func finish() throws {
        let directoryStart = offset
        for entry in entries {
            var b = Bytes()
            b.u32(ZipFormat.centralSignature)
            b.u16(3 << 8 | 20)      // made by: Unix, spec 2.0 (so unzip tools read the permissions)
            b.u16(20)               // needed to extract
            b.u16(ZipFormat.utf8Flag)
            b.u16(entry.method)
            b.u16(entry.time)
            b.u16(entry.date)
            b.u32(entry.crc)
            b.u32(entry.compressedSize)
            b.u32(entry.size)
            b.u16(UInt16(entry.name.count))
            b.u16(0)                // extra
            b.u16(0)                // comment
            b.u16(0)                // disk
            b.u16(0)                // internal attributes
            b.u32(entry.externalAttributes)
            b.u32(entry.offset)
            b.raw(entry.name)
            try write(b.data)
        }
        var end = Bytes()
        end.u32(ZipFormat.endSignature)
        end.u16(0)
        end.u16(0)
        end.u16(UInt16(entries.count))
        end.u16(UInt16(entries.count))
        end.u32(try narrow(offset - directoryStart))
        end.u32(try narrow(directoryStart))
        end.u16(0)
        try write(end.data)
        try handle.close()
    }

    private func localHeader(name: [UInt8], method: UInt16, time: UInt16, date: UInt16) throws -> Data {
        guard name.count <= Int(UInt16.max) else { throw Self.tooBig }
        var b = Bytes()
        b.u32(ZipFormat.localSignature)
        b.u16(20)
        b.u16(ZipFormat.utf8Flag)
        b.u16(method)
        b.u16(time)
        b.u16(date)
        b.u32(0)    // CRC, patched later
        b.u32(0)    // compressed size, patched later
        b.u32(0)    // size, patched later
        b.u16(UInt16(name.count))
        b.u16(0)
        b.raw(name)
        return b.data
    }

    private func append(_ entry: Entry) throws {
        guard entries.count < Self.maxEntries else { throw Self.tooBig }
        entries.append(entry)
    }

    private func write(_ data: Data) throws {
        guard offset + Int64(data.count) <= Self.maxBytes else { throw Self.tooBig }
        try handle.write(contentsOf: data)
        offset += Int64(data.count)
    }

    private func narrow(_ value: Int64) throws -> UInt32 {
        guard value >= 0, value <= Int64(UInt32.max) else { throw Self.tooBig }
        return UInt32(value)
    }

    /// Reads `url` in chunks. Refuses a link or anything but a plain file, so a file swapped for a link after the
    /// folder was walked can't pull other files into the archive.
    private func readChunks(_ url: URL, _ body: (Data) throws -> Void) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ConversionError.unreadable(url) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ConversionError.unreadable(url) }
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: ZipFormat.chunkSize), !chunk.isEmpty else { return }
            try body(chunk)
        }
    }

    static let tooBig = ConversionError.engine("Frenzy can zip up to 4 GB and 65,000 items at a time for now. Try fewer files.")
}

// MARK: - Reader

/// Reads a classic ZIP file's central directory and extracts entries safely.
struct ZipReader {
    struct Entry: Sendable {
        let rawName: [UInt8]
        let flags: UInt16
        let method: UInt16
        let time: UInt16
        let date: UInt16
        let crc: UInt32
        let compressedSize: Int64
        let size: Int64
        let localOffset: Int64
        let madeBy: UInt16
        let externalAttributes: UInt32

        var isEncrypted: Bool { flags & ZipFormat.encryptedFlag != 0 }
        /// Unix file type and permission bits, when a Unix tool made the entry.
        var unixMode: UInt16? { madeBy >> 8 == 3 ? UInt16(externalAttributes >> 16) : nil }
        private var fileType: UInt16 { (unixMode ?? 0) & UInt16(S_IFMT) }
        var isSymlink: Bool { fileType == UInt16(S_IFLNK) }
        var isDirectory: Bool {
            rawName.last == UInt8(ascii: "/") || rawName.last == UInt8(ascii: "\\") || fileType == UInt16(S_IFDIR)
        }
        /// A device, socket or pipe, which no unzip should ever create.
        var isSpecial: Bool {
            fileType != 0 && fileType != UInt16(S_IFREG) && fileType != UInt16(S_IFDIR) && fileType != UInt16(S_IFLNK)
        }

        /// The entry's name. UTF-8 when flagged or when it decodes as UTF-8 (macOS tools don't always set the flag),
        /// else the old DOS code page. Nil when a flagged name isn't valid UTF-8.
        var name: String? {
            if let utf8 = String(bytes: rawName, encoding: .utf8) { return utf8 }
            if flags & ZipFormat.utf8Flag != 0 { return nil }
            let dos = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
            return String(bytes: rawName, encoding: String.Encoding(rawValue: dos))
        }
    }

    let url: URL
    let entries: [Entry]
    /// Where the central directory starts: no entry's data may run past it.
    let directoryOffset: Int64

    static let maxDirectoryBytes = 64 << 20

    init(url: URL, maxEntries: Int) throws {
        self.url = url
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ConversionError.unreadable(url) }
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        guard fileSize >= 22 else { throw Self.damaged }

        // The end record sits in the last 22 bytes plus an optional comment of up to 65,535 bytes.
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: UInt64(fileSize - tailLength))
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        var endAt: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.u32(i) == ZipFormat.endSignature, let comment = tail.u16(i + 20), i + 22 + Int(comment) <= tail.count {
                endAt = i
                break
            }
            i -= 1
        }
        guard let end = endAt,
              let disk = tail.u16(end + 4), let directoryDisk = tail.u16(end + 6),
              let onDisk = tail.u16(end + 8), let total = tail.u16(end + 10),
              let directorySize = tail.u32(end + 12), let directoryOffset = tail.u32(end + 16) else { throw Self.damaged }
        let endOffset = fileSize - tailLength + Int64(end)
        if (end >= 20 && tail.u32(end - 20) == ZipFormat.zip64LocatorSignature)
            || total == .max || directorySize == .max || directoryOffset == .max {
            throw Self.zip64
        }
        guard disk == 0, directoryDisk == 0, onDisk == total else {
            throw ConversionError.engine("This zip is split into parts. Frenzy can only open single-file zips.")
        }
        guard Int(total) <= maxEntries else { throw Self.tooManyItems(maxEntries) }
        guard Int(directorySize) <= Self.maxDirectoryBytes, Int64(directoryOffset) + Int64(directorySize) <= endOffset else {
            throw Self.damaged
        }

        try handle.seek(toOffset: UInt64(directoryOffset))
        let directory = [UInt8](try handle.read(upToCount: Int(directorySize)) ?? Data())
        guard directory.count == Int(directorySize) else { throw Self.damaged }
        var entries: [Entry] = []
        entries.reserveCapacity(Int(total))
        var p = 0
        for _ in 0..<Int(total) {
            guard directory.u32(p) == ZipFormat.centralSignature,
                  let madeBy = directory.u16(p + 4), let flags = directory.u16(p + 8), let method = directory.u16(p + 10),
                  let time = directory.u16(p + 12), let date = directory.u16(p + 14), let crc = directory.u32(p + 16),
                  let compressed = directory.u32(p + 20), let size = directory.u32(p + 24),
                  let nameLength = directory.u16(p + 28), let extraLength = directory.u16(p + 30),
                  let commentLength = directory.u16(p + 32), let external = directory.u32(p + 38),
                  let local = directory.u32(p + 42) else { throw Self.damaged }
            if compressed == .max || size == .max || local == .max { throw Self.zip64 }
            let nameStart = p + 46
            let next = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard next <= directory.count, Int64(local) < Int64(directoryOffset) else { throw Self.damaged }
            entries.append(Entry(rawName: Array(directory[nameStart..<nameStart + Int(nameLength)]), flags: flags,
                                 method: method, time: time, date: date, crc: crc, compressedSize: Int64(compressed),
                                 size: Int64(size), localOffset: Int64(local), madeBy: madeBy, externalAttributes: external))
            p = next
        }
        self.entries = entries
        self.directoryOffset = Int64(directoryOffset)
    }

    /// Writes `entry`'s contents to the open file `output`. Stops as soon as the data would pass the declared size,
    /// and fails unless the size and CRC match exactly. `onBytes` reports compressed bytes consumed.
    func extract(_ entry: Entry, to output: FileHandle, onBytes: (Int) -> Void) throws {
        guard !entry.isEncrypted else { throw Self.encrypted }
        guard entry.method == ZipFormat.stored || entry.method == ZipFormat.deflated else { throw Self.unsupportedMethod }
        guard entry.method == ZipFormat.deflated || entry.compressedSize == entry.size else { throw Self.damaged }
        // An empty file: some tools still write a tiny deflate stream. Nothing to read, but the CRC must say empty.
        if entry.size == 0 {
            guard entry.crc == 0 else { throw Self.damaged }
            return
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ConversionError.unreadable(url) }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.localOffset))
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard header.u32(0) == ZipFormat.localSignature, let nameLength = header.u16(26), let extraLength = header.u16(28) else {
            throw Self.damaged
        }
        let dataStart = entry.localOffset + 30 + Int64(nameLength) + Int64(extraLength)
        guard dataStart + entry.compressedSize <= directoryOffset else { throw Self.damaged }
        try handle.seek(toOffset: UInt64(dataStart))

        let crc = CRCBox()
        let written = Counter()
        let limit = entry.size
        let sink: (Data) throws -> Void = { chunk in
            // Checked per inflated chunk too: one compressed chunk can expand a thousand times.
            try Task.checkCancellation()
            guard written.value + Int64(chunk.count) <= limit else { throw Self.damaged }
            crc.crc.update(chunk)
            do { try output.write(contentsOf: chunk) } catch {
                // A full disk is not a damaged zip.
                throw ConversionError.writeFailed(url, (error as NSError).localizedDescription)
            }
            written.value += Int64(chunk.count)
        }
        let filter = entry.method == ZipFormat.deflated
            ? try OutputFilter(.decompress, using: .zlib) { chunk in if let chunk { try sink(chunk) } }
            : nil
        var remaining = entry.compressedSize
        do {
            while remaining > 0 {
                try Task.checkCancellation()
                let want = Int(min(remaining, Int64(ZipFormat.chunkSize)))
                guard let chunk = try handle.read(upToCount: want), chunk.count == want else { throw Self.damaged }
                remaining -= Int64(want)
                if let filter { try filter.write(chunk) } else { try sink(chunk) }
                onBytes(want)
            }
            try filter?.finalize()
        } catch let error as ConversionError {
            throw error
        } catch is CancellationError {
            throw ConversionError.cancelled
        } catch {
            // Compression reports a corrupt stream as a generic error.
            throw Self.damaged
        }
        guard written.value == entry.size, crc.crc.value == entry.crc else { throw Self.damaged }
    }

    static let damaged = ConversionError.engine("This zip is damaged or incomplete, so Frenzy couldn't open it.")
    static let zip64 = ConversionError.engine("This zip uses the large-archive format (over 4 GB or 65,535 items). Frenzy can't open those yet.")
    static let encrypted = ConversionError.engine("This zip is locked with a password. Frenzy can't open those yet.")
    static let unsupportedMethod = ConversionError.engine("This zip uses a compression method Frenzy can't open yet.")
    static func tooManyItems(_ limit: Int) -> ConversionError {
        .engine("This zip holds more than \(limit.formatted()) items, more than Frenzy unpacks at once.")
    }
}

/// CRC state shared with a Compression callback.
private final class CRCBox { var crc = CRC32() }
