import Compression
import Darwin
import Foundation
import HaloCore

/// Strict, streaming readers for tar, gzip and xz on Apple's Compression framework, in the same style as `ZipReader`:
/// every archive is hostile until proven otherwise. Sizes are checked before use, checksums must match, and a stream that
/// ends early or carries garbage fails instead of giving half a result. Nothing here allocates more than a chunk or a header.
enum TarFormat {
    static let blockSize = 512
    static let chunkSize = 1 << 20

    static let damaged = ConversionError.engine("This archive is damaged or incomplete, so Frenzy couldn't open it.")
    static let unsupported = ConversionError.engine("This archive uses a feature Frenzy can't open yet.")
}

/// A source of bytes, read in order. `next()` is nil at the end.
protocol ByteChunks: AnyObject {
    func next() throws -> Data?
    /// Bytes taken from the file on disk so far, for honest progress on compressed input.
    var fileBytesRead: Int64 { get }
}

/// A plain file, in chunks.
final class FileChunks: ByteChunks {
    private let handle: FileHandle
    private(set) var fileBytesRead: Int64 = 0
    private let url: URL

    init(_ url: URL) throws {
        self.url = url
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ConversionError.unreadable(url) }
    }

    deinit { try? handle.close() }

    func next() throws -> Data? {
        let chunk: Data?
        do { chunk = try handle.read(upToCount: TarFormat.chunkSize) } catch { throw ConversionError.unreadable(url) }
        guard let chunk, !chunk.isEmpty else { return nil }
        fileBytesRead += Int64(chunk.count)
        return chunk
    }
}

/// One `compression_stream` decode: feed compressed bytes, take chunks of output.
final class StreamDecoder {
    private let stream: UnsafeMutablePointer<compression_stream>
    private let output: UnsafeMutablePointer<UInt8>
    private var input = Data()
    private var inputOffset = 0
    private(set) var finished = false

    init(algorithm: compression_algorithm) throws {
        stream = .allocate(capacity: 1)
        output = .allocate(capacity: TarFormat.chunkSize)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            output.deallocate()
            throw TarFormat.damaged
        }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        output.deallocate()
    }

    func feed(_ data: Data) {
        input = input.subdata(in: inputOffset..<input.count) + data
        inputOffset = 0
    }

    /// The next piece of output, or nil when the decoder needs more input or has finished. At most one chunk, however
    /// much the input expands, so a bomb can only cost a chunk of memory between size checks.
    func nextOutput(endOfInput: Bool) throws -> Data? {
        guard !finished else { return nil }
        let produced: Int = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            // An empty Data has no base address and the decoder needs a real pointer, even with zero bytes.
            let empty = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            defer { empty.deallocate() }
            stream.pointee.src_ptr = base.map { UnsafePointer($0 + inputOffset) } ?? UnsafePointer(empty)
            stream.pointee.src_size = input.count - inputOffset
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = TarFormat.chunkSize
            let status = compression_stream_process(stream, endOfInput ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
            guard status != COMPRESSION_STATUS_ERROR else { throw TarFormat.damaged }
            inputOffset = input.count - stream.pointee.src_size
            if status == COMPRESSION_STATUS_END { finished = true }
            return TarFormat.chunkSize - stream.pointee.dst_size
        }
        return produced > 0 ? Data(bytes: output, count: produced) : nil
    }

    var needsInput: Bool { !finished && inputOffset >= input.count }
}

/// gzip (RFC 1952): one or more members, each checked against its own CRC and length. The name and comment inside the
/// header are skipped and never used: a file's name comes from the file on disk, not from what the archive claims.
///
/// Apple's decoder swallows whatever follows the deflate data, so it can't say where a member's trailer starts. The trailer's
/// contents are known by then, though (the CRC and length of what came out), so it's found by looking for exactly those eight
/// bytes in what was last fed in. That doubles as the check: a wrong CRC or length is never found, and the file is refused.
final class GzipChunks: ByteChunks {
    private let source: any ByteChunks
    private var pending = Data()
    private var pendingOffset = 0
    private var sourceEnded = false
    private var decoder: StreamDecoder?
    /// What the decoder was last given, and the piece before it.
    private var lastFed = Data()
    private var previousFed = Data()
    private var crc = CRC32()
    private var memberBytes: UInt64 = 0
    private var membersRead = 0

    init(_ source: any ByteChunks) { self.source = source }
    var fileBytesRead: Int64 { source.fileBytesRead }

    private var available: Int { pending.count - pendingOffset }

    @discardableResult private func fill(atLeast count: Int) throws -> Bool {
        while available < count, !sourceEnded {
            if let chunk = try source.next() {
                pending = pending.subdata(in: pendingOffset..<pending.count) + chunk
                pendingOffset = 0
            } else {
                sourceEnded = true
            }
        }
        return available >= count
    }

    private func take(_ count: Int) throws -> Data {
        guard try fill(atLeast: count) else { throw TarFormat.damaged }
        let piece = pending.subdata(in: pendingOffset..<(pendingOffset + count))
        pendingOffset += count
        return piece
    }

    private func skipZeroTerminated() throws {
        while true {
            guard try fill(atLeast: 1) else { throw TarFormat.damaged }
            let byte = pending[pending.startIndex + pendingOffset]
            pendingOffset += 1
            if byte == 0 { return }
        }
    }

    /// Reads a member header and starts a decoder. False at a clean end of file.
    private func startMember() throws -> Bool {
        guard try fill(atLeast: 1) else {
            guard membersRead > 0 else { throw TarFormat.damaged }
            return false
        }
        // Padding of zeros after the last member is allowed (tar and some tools write it); anything else isn't a new member.
        if membersRead > 0, pending[pending.startIndex + pendingOffset] == 0 {
            while try fill(atLeast: 1) {
                guard pending[pending.startIndex + pendingOffset] == 0 else { throw TarFormat.damaged }
                pendingOffset += 1
            }
            return false
        }
        let head = [UInt8](try take(10))
        guard head[0] == 0x1F, head[1] == 0x8B, head[2] == 8 else { throw TarFormat.damaged }
        let flags = head[3]
        guard flags & 0xE0 == 0 else { throw TarFormat.unsupported }
        if flags & 4 != 0 {
            let lengthBytes = [UInt8](try take(2))
            _ = try take(Int(lengthBytes[0]) | Int(lengthBytes[1]) << 8)
        }
        if flags & 8 != 0 { try skipZeroTerminated() }
        if flags & 16 != 0 { try skipZeroTerminated() }
        if flags & 2 != 0 { _ = try take(2) }
        decoder = try StreamDecoder(algorithm: COMPRESSION_ZLIB)
        crc = CRC32()
        memberBytes = 0
        membersRead += 1
        lastFed = Data()
        previousFed = Data()
        return true
    }

    private func finishMember() throws {
        var trailer = Data()
        withUnsafeBytes(of: crc.value.littleEndian) { trailer.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: memberBytes).littleEndian) { trailer.append(contentsOf: $0) }

        var window = previousFed + lastFed + pending.subdata(in: pendingOffset..<pending.count)
        pending = Data()
        pendingOffset = 0
        // The trailer can end just past what's been read so far.
        if !sourceEnded, let more = try source.next() { window += more } else { sourceEnded = true }

        var from = window.startIndex
        while let found = window.range(of: trailer, in: from..<window.endIndex) {
            // What follows has to look like the end of the file, padding, or the next member.
            let next = found.upperBound
            if next == window.endIndex || window[next] == 0 || window[next] == 0x1F {
                pending = window.subdata(in: next..<window.endIndex)
                pendingOffset = 0
                decoder = nil
                lastFed = Data()
                previousFed = Data()
                return
            }
            from = window.index(after: found.lowerBound)
        }
        throw TarFormat.damaged
    }

    func next() throws -> Data? {
        while true {
            if decoder == nil {
                guard try startMember() else { return nil }
            }
            guard let decoder else { return nil }
            if decoder.needsInput {
                if try fill(atLeast: 1) {
                    previousFed = lastFed
                    lastFed = pending.subdata(in: pendingOffset..<pending.count)
                    decoder.feed(lastFed)
                    pendingOffset = pending.count
                } else {
                    // Out of input with the stream still open: a truncated file. Let the decoder try to finish, or fail.
                    if let tail = try decoder.nextOutput(endOfInput: true) { crc.update(tail); memberBytes += UInt64(tail.count); return tail }
                    guard decoder.finished else { throw TarFormat.damaged }
                    try finishMember()
                    continue
                }
            }
            if let piece = try decoder.nextOutput(endOfInput: false) {
                crc.update(piece)
                memberBytes += UInt64(piece.count)
                return piece
            }
            if decoder.finished { try finishMember() }
        }
    }
}

/// xz, through Compression's LZMA decoder, which checks the stream's own integrity data.
final class XZChunks: ByteChunks {
    private let source: any ByteChunks
    private let decoder: StreamDecoder
    private var sourceEnded = false

    init(_ source: any ByteChunks) throws {
        self.source = source
        decoder = try StreamDecoder(algorithm: COMPRESSION_LZMA)
    }

    var fileBytesRead: Int64 { source.fileBytesRead }

    func next() throws -> Data? {
        while !decoder.finished {
            if decoder.needsInput, !sourceEnded {
                if let chunk = try source.next() { decoder.feed(chunk) } else { sourceEnded = true }
            }
            if let piece = try decoder.nextOutput(endOfInput: sourceEnded) { return piece }
            if sourceEnded, decoder.needsInput, !decoder.finished { throw TarFormat.damaged }
        }
        return nil
    }
}

// MARK: - Tar reading

/// A tar stream: ustar, GNU long names and pax headers. Sparse files are refused. Reads only forward.
final class TarReader {
    enum Kind: Equatable { case file, directory, link, special }

    struct Entry: Equatable {
        let name: String
        let kind: Kind
        let size: Int64
        let modified: Date?
    }

    private let source: any ByteChunks
    private var buffer = Data()
    private var offset = 0
    private var sourceEnded = false
    /// Unread data of the current entry, including padding to the next block.
    private var remainingData: Int64 = 0
    private var remainingPadding: Int64 = 0
    private var sawEnd = false

    /// Long names and pax records can't outgrow this. A real one is a few kilobytes.
    static let maxMetaBytes = 1 << 20

    init(_ source: any ByteChunks) { self.source = source }

    var fileBytesRead: Int64 { source.fileBytesRead }

    private func fill(atLeast count: Int) throws -> Bool {
        while buffer.count - offset < count, !sourceEnded {
            if let chunk = try source.next() {
                buffer = buffer.subdata(in: offset..<buffer.count) + chunk
                offset = 0
            } else {
                sourceEnded = true
            }
        }
        return buffer.count - offset >= count
    }

    private func readBlock() throws -> [UInt8]? {
        guard try fill(atLeast: TarFormat.blockSize) else {
            // Nothing left at all counts as an end, as GNU tar treats it; a partial block is damage.
            if buffer.count - offset == 0 { return nil }
            throw TarFormat.damaged
        }
        let block = [UInt8](buffer.subdata(in: offset..<(offset + TarFormat.blockSize)))
        offset += TarFormat.blockSize
        return block
    }

    private func skip(_ count: Int64) throws {
        var left = count
        while left > 0 {
            let want = Int(min(left, Int64(TarFormat.chunkSize)))
            guard try fill(atLeast: want) else { throw TarFormat.damaged }
            offset += want
            left -= Int64(want)
        }
    }

    /// Text field: up to the first NUL.
    private static func text(_ block: [UInt8], _ start: Int, _ length: Int) -> [UInt8] {
        let field = block[start..<(start + length)]
        return Array(field.prefix { $0 != 0 })
    }

    /// Octal number, or GNU's base-256 form for big values. Nil on anything else.
    static func number(_ block: [UInt8], _ start: Int, _ length: Int) -> Int64? {
        let field = Array(block[start..<(start + length)])
        if let first = field.first, first & 0x80 != 0 {
            guard first == 0x80 else { return nil } // Negative, or a form nobody writes.
            var value: Int64 = 0
            for byte in field.dropFirst() {
                guard value <= (Int64.max >> 8) else { return nil }
                value = value << 8 | Int64(byte)
            }
            return value
        }
        var value: Int64 = 0, sawDigit = false
        for byte in field {
            if byte == 0 || byte == 0x20 {
                if sawDigit { break }
                continue
            }
            guard (0x30...0x37).contains(byte), value <= (Int64.max >> 3) else { return nil }
            value = value << 3 | Int64(byte - 0x30)
            sawDigit = true
        }
        return sawDigit ? value : 0
    }

    private static func checksumIsValid(_ block: [UInt8]) -> Bool {
        guard let stored = number(block, 148, 8) else { return false }
        var unsigned: Int64 = 0
        for (i, byte) in block.enumerated() { unsigned += (148..<156).contains(i) ? 32 : Int64(byte) }
        return unsigned == stored
    }

    /// True when `block` is a real tar header: right checksum, so a random gzip's content isn't taken for one.
    static func isHeader(_ block: Data) -> Bool {
        guard block.count >= TarFormat.blockSize else { return false }
        let bytes = [UInt8](block.prefix(TarFormat.blockSize))
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        return checksumIsValid(bytes)
    }

    /// The whole of a small metadata entry (a long name, a pax record).
    private func readMeta(size: Int64) throws -> [UInt8] {
        guard size >= 0, size <= Int64(Self.maxMetaBytes) else { throw TarFormat.damaged }
        let padded = (size + 511) / 512 * 512
        guard try fill(atLeast: Int(padded)) else { throw TarFormat.damaged }
        let bytes = [UInt8](buffer.subdata(in: offset..<(offset + Int(size))))
        offset += Int(padded)
        return bytes
    }

    /// `length key=value\n` records. Only the ones Frenzy acts on are returned.
    static func paxRecords(_ bytes: [UInt8]) throws -> (path: String?, size: Int64?, modified: Double?) {
        var path: String?, size: Int64?, modified: Double?
        var i = 0
        while i < bytes.count {
            var j = i, length = 0
            while j < bytes.count, bytes[j] != 0x20 {
                guard (0x30...0x39).contains(bytes[j]), length < 1 << 24 else { throw TarFormat.damaged }
                length = length * 10 + Int(bytes[j] - 0x30)
                j += 1
            }
            guard j < bytes.count, length > j - i + 1, i + length <= bytes.count, bytes[i + length - 1] == 0x0A else { throw TarFormat.damaged }
            let record = bytes[(j + 1)..<(i + length - 1)]
            if let equals = record.firstIndex(of: 0x3D) {
                let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
                let value = String(decoding: record[(equals + 1)...], as: UTF8.self)
                switch key {
                case "path": path = value
                case "size":
                    guard let parsed = Int64(value), parsed >= 0 else { throw TarFormat.damaged }
                    size = parsed
                case "mtime": modified = Double(value)
                case "GNU.sparse.major", "GNU.sparse.map", "GNU.sparse.size": throw TarFormat.unsupported
                default: break
                }
            }
            i += length
        }
        return (path, size, modified)
    }

    /// The next entry, or nil at the end of the archive. Its data must be read with `readData` or is skipped by the next call.
    func next() throws -> Entry? {
        guard !sawEnd else { return nil }
        try skip(remainingData + remainingPadding)
        remainingData = 0
        remainingPadding = 0

        var longName: String?, paxPath: String?, paxSize: Int64?, paxModified: Double?
        while true {
            guard let block = try readBlock() else {
                sawEnd = true
                return nil
            }
            if block.allSatisfy({ $0 == 0 }) {
                // Two zero blocks end an archive. A lone one at the end of the file is accepted too, as GNU tar does.
                _ = try readBlock()
                sawEnd = true
                return nil
            }
            guard Self.checksumIsValid(block) else { throw TarFormat.damaged }
            guard let headerSize = Self.number(block, 124, 12), headerSize >= 0 else { throw TarFormat.damaged }
            let type = block[156]
            switch type {
            case 0x4C: // 'L': GNU long name for the next entry
                longName = String(decoding: try readMeta(size: headerSize).prefix { $0 != 0 }, as: UTF8.self)
                continue
            case 0x4B: // 'K': GNU long link name; links are skipped, so only the skip matters
                _ = try readMeta(size: headerSize)
                continue
            case 0x78: // 'x': pax header for the next entry
                let records = try Self.paxRecords(try readMeta(size: headerSize))
                paxPath = records.path ?? paxPath
                paxSize = records.size ?? paxSize
                paxModified = records.modified ?? paxModified
                continue
            case 0x67: // 'g': pax global header
                _ = try Self.paxRecords(try readMeta(size: headerSize))
                continue
            case 0x53: // 'S': GNU sparse
                throw TarFormat.unsupported
            default:
                break
            }

            let kind: Kind
            var size = paxSize ?? headerSize
            switch type {
            case 0, 0x30, 0x37: kind = .file
            case 0x35: kind = .directory
            case 0x31, 0x32: kind = .link
            default: kind = .special
            }
            guard size >= 0 else { throw TarFormat.damaged }
            // Links and directories carry no data, whatever the header says. Old tars do say.
            if kind == .link { size = 0 }

            var name: String
            if let path = paxPath ?? longName {
                name = path
            } else {
                let prefix = Self.text(block, 345, 155)
                let magic = Self.text(block, 257, 6)
                let base = String(decoding: Self.text(block, 0, 100), as: UTF8.self)
                if magic.starts(with: Array("ustar".utf8)), !prefix.isEmpty, block[263] == 0x30 {
                    name = String(decoding: prefix, as: UTF8.self) + "/" + base
                } else {
                    name = base
                }
            }
            if name.isEmpty { throw TarFormat.damaged }
            // A very old convention marks a folder by a trailing slash on a plain-file entry.
            var finalKind = kind
            if kind == .file, name.hasSuffix("/") { finalKind = .directory }
            if name.hasSuffix("/") { name.removeLast() }

            let dataSize = finalKind == .file ? size : (finalKind == .special || finalKind == .directory ? size : 0)
            remainingData = dataSize
            remainingPadding = dataSize % 512 == 0 ? 0 : 512 - dataSize % 512

            let seconds = paxModified ?? Self.number(block, 136, 12).map(Double.init)
            let modified = seconds.flatMap { $0 > 0 && $0 < 8.0e9 ? Date(timeIntervalSince1970: $0) : nil }
            return Entry(name: name, kind: finalKind, size: finalKind == .file ? size : 0, modified: modified)
        }
    }

    /// Hands the current entry's data to `body`, in chunks. Fails if the archive ends before the entry does.
    func readData(_ body: (Data) throws -> Void) throws {
        while remainingData > 0 {
            guard try fill(atLeast: 1) else { throw TarFormat.damaged }
            let take = Int(min(remainingData, Int64(buffer.count - offset)))
            try body(buffer.subdata(in: offset..<(offset + take)))
            offset += take
            remainingData -= Int64(take)
        }
    }
}

// MARK: - Writing

/// Writes a `.tar.gz`: ustar headers with pax records for long names, as one gzip member.
final class TarGzipWriter {
    private let handle: FileHandle
    private let url: URL
    private var filter: OutputFilter?
    private let counter: ByteCounter
    private var crc = CRC32()
    private var total: UInt64 = 0

    private final class ByteCounter: @unchecked Sendable { var value: Int64 = 0 }

    /// Same promise as Zip: nothing that runs away with the disk.
    static let maxBytes: Int64 = 64 << 30
    static let tooBig = ConversionError.engine("That's too much for one archive. Frenzy makes .tar.gz files up to 64 GB.")

    init(creating url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { throw ConversionError.writeFailed(url, "Couldn't create the archive.") }
        self.handle = handle
        // 10-byte header: deflate, no name, no time, so the same input gives the same bytes.
        do { try handle.write(contentsOf: Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0x03])) }
        catch { throw ConversionError.writeFailed(url, error.localizedDescription) }
        let counter = ByteCounter()
        self.counter = counter
        filter = try OutputFilter(.compress, using: .zlib) { [handle] chunk in
            guard let chunk else { return }
            try handle.write(contentsOf: chunk)
            counter.value += Int64(chunk.count)
        }
    }

    private func put(_ data: Data) throws {
        guard let filter else { throw ConversionError.writeFailed(url, "The archive is already closed.") }
        crc.update(data)
        total += UInt64(data.count)
        do { try filter.write(data) } catch { throw ConversionError.writeFailed(url, error.localizedDescription) }
        guard counter.value <= Self.maxBytes else { throw Self.tooBig }
    }

    private static func octal(_ value: Int64, width: Int) -> [UInt8] {
        let digits = String(value, radix: 8)
        return Array(String(repeating: "0", count: max(0, width - 1 - digits.count)).utf8) + Array(digits.utf8) + [0]
    }

    private static func header(name: [UInt8], typeflag: UInt8, size: Int64, modified: Int64, permissions: UInt16) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func set(_ bytes: [UInt8], at start: Int) { for (i, b) in bytes.enumerated() { block[start + i] = b } }
        set(Array(name.prefix(100)), at: 0)
        set(octal(Int64(permissions), width: 8), at: 100)
        set(octal(0, width: 8), at: 108)
        set(octal(0, width: 8), at: 116)
        set(octal(size, width: 12), at: 124)
        set(octal(max(0, modified), width: 12), at: 136)
        set(Array(repeating: 0x20, count: 8), at: 148)
        block[156] = typeflag
        set(Array("ustar".utf8) + [0, 0x30, 0x30], at: 257)
        let sum = block.reduce(0) { $0 + Int64($1) }
        let digits = Array(String(String(sum, radix: 8).reversed().map { $0 }.reversed()).utf8)
        set(Array(repeating: 0x30, count: max(0, 6 - digits.count)) + digits + [0, 0x20], at: 148)
        return Data(block)
    }

    private func pad(_ size: Int64) throws {
        let rest = size % 512
        if rest != 0 { try put(Data(count: Int(512 - rest))) }
    }

    /// Long or non-ASCII names, and files over the 8 GB ustar can state, go in a pax record ahead of the entry.
    private func writeHeader(path: String, typeflag: UInt8, size: Int64, modified: Date, permissions: UInt16) throws {
        let name = Array(path.utf8)
        let seconds = Int64(modified.timeIntervalSince1970)
        let isBig = size >= 8 << 30
        var records = Data()
        func record(_ key: String, _ value: String) {
            let body = " \(key)=\(value)\n"
            var length = body.utf8.count
            while String(length).utf8.count + body.utf8.count != length { length = String(length).utf8.count + body.utf8.count }
            records.append(Data("\(length)\(body)".utf8))
        }
        if name.count >= 100 || name.contains(where: { $0 >= 0x80 }) { record("path", path) }
        if isBig { record("size", String(size)) }
        if !records.isEmpty {
            try put(Self.header(name: Array("PaxHeader".utf8), typeflag: 0x78, size: Int64(records.count), modified: seconds, permissions: 0o644))
            try put(records)
            try pad(Int64(records.count))
        }
        try put(Self.header(name: name, typeflag: typeflag, size: isBig ? 0 : size, modified: seconds, permissions: permissions))
    }

    func addDirectory(path: String, modified: Date, permissions: UInt16) throws {
        try writeHeader(path: path + "/", typeflag: 0x35, size: 0, modified: modified, permissions: permissions)
    }

    func addFile(from source: URL, path: String, modified: Date, permissions: UInt16, size: Int64, onBytes: (Int) -> Void) throws {
        try writeHeader(path: path, typeflag: 0x30, size: size, modified: modified, permissions: permissions)
        let file = try FileChunks(source)
        var written: Int64 = 0
        while let chunk = try file.next() {
            try Task.checkCancellation()
            // The file grew since it was measured: the header's size is what counts, or every later entry breaks.
            let piece = chunk.prefix(Int(min(Int64(chunk.count), size - written)))
            if !piece.isEmpty { try put(Data(piece)) }
            written += Int64(piece.count)
            onBytes(chunk.count)
            if written == size { break }
        }
        // It shrank: fill up, for the same reason.
        if written < size {
            var left = size - written
            while left > 0 {
                let count = Int(min(left, Int64(TarFormat.chunkSize)))
                try put(Data(count: count))
                left -= Int64(count)
            }
        }
        try pad(size)
    }

    func finish() throws {
        try put(Data(count: 1024))
        guard let filter else { return }
        do { try filter.finalize() } catch { throw ConversionError.writeFailed(url, error.localizedDescription) }
        self.filter = nil
        var trailer = Data()
        withUnsafeBytes(of: crc.value.littleEndian) { trailer.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: total).littleEndian) { trailer.append(contentsOf: $0) }
        do {
            try handle.write(contentsOf: trailer)
            try handle.close()
        } catch {
            throw ConversionError.writeFailed(url, error.localizedDescription)
        }
    }
}
