import Foundation
import HaloCore

/// Moves Apple's metadata (creation date, camera model...) to where macOS reads it.
///
/// FFmpeg writes those `mdta` keys in `moov/udta/meta` as an ISO "full box" (4 extra version bytes). Apple's readers only
/// see `mdta` metadata directly in `moov`, with no version bytes, so the date and model looked lost. This moves that one
/// box. The engine writes the movie box last (no fast start), so the move changes only the end of the file: the media
/// data and every sample offset stay exactly where they are.
enum QuickTimeTags {
    private struct Box { var type: String; var start: Int; var size: Int; var header: Int }

    private static func boxes(in data: Data, from start: Int, to end: Int) -> [Box]? {
        var result: [Box] = [], offset = start
        while offset + 8 <= end {
            var size = Int(data.bigEndianUInt32(at: offset)), header = 8
            if size == 1 {
                guard offset + 16 <= end else { return nil }
                guard let big = Int(exactly: data.bigEndianUInt64(at: offset + 8)) else { return nil }
                size = big; header = 16
            } else if size == 0 { size = end - offset }
            guard size >= header, size <= end - offset else { return nil }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append(Box(type: type, start: offset, size: size, header: header))
            offset += size
        }
        return offset == end ? result : nil
    }

    /// Rewrites `url` in place. Leaves the file untouched when there is nothing to move or anything looks unexpected.
    static func relocate(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        // Only the top-level box list is read from the whole file; then just the movie box.
        guard let top = try topLevel(handle, length: length), let moovBox = top.last(where: { $0.type == "moov" }),
              moovBox.start + moovBox.size == length, moovBox.header == 8 else { return }
        try handle.seek(toOffset: UInt64(moovBox.start))
        guard let moov = try handle.read(upToCount: moovBox.size), moov.count == moovBox.size,
              let children = boxes(in: moov, from: 8, to: moov.count),
              let udta = children.first(where: { $0.type == "udta" }), udta.header == 8,
              let inUdta = boxes(in: moov, from: udta.start + 8, to: udta.start + udta.size),
              let meta = inUdta.first(where: { $0.type == "meta" }), meta.header == 8, meta.size >= 16 else { return }
        // A full box has 4 version bytes before its children; `mdta` is the QuickTime metadata handler.
        let body = meta.start + 12
        guard let metaKids = boxes(in: moov, from: body, to: meta.start + meta.size),
              let hdlr = metaKids.first(where: { $0.type == "hdlr" }), hdlr.size >= 20,
              String(decoding: moov[(hdlr.start + 16)..<(hdlr.start + 20)], as: UTF8.self) == "mdta",
              metaKids.contains(where: { $0.type == "keys" }), metaKids.contains(where: { $0.type == "ilst" }) else { return }

        // The new movie box: everything but the old meta (udta shrinks, or goes if that was all it held), then the
        // QuickTime meta: same children, no version bytes.
        var newUdta = Data()
        for box in inUdta where box.start != meta.start { newUdta.append(moov[box.start..<(box.start + box.size)]) }
        var newMoov = Data()
        for box in children {
            if box.start == udta.start {
                if !newUdta.isEmpty { newMoov.append(header(newUdta.count + 8, "udta")); newMoov.append(newUdta) }
            } else {
                newMoov.append(moov[box.start..<(box.start + box.size)])
            }
        }
        let metaBody = moov[body..<(meta.start + meta.size)]
        newMoov.append(header(metaBody.count + 8, "meta")); newMoov.append(metaBody)
        var whole = header(newMoov.count + 8, "moov"); whole.append(newMoov)

        // Write first, then cut: the new box is never longer than the old one, and a failed write never leaves a file
        // without a movie box (the caller then throws and nothing is saved).
        try handle.seek(toOffset: UInt64(moovBox.start))
        try handle.write(contentsOf: whole)
        try handle.truncate(atOffset: UInt64(moovBox.start + whole.count))
        try handle.synchronize()
    }

    private static func topLevel(_ handle: FileHandle, length: Int) throws -> [Box]? {
        var result: [Box] = [], offset = 0
        while offset + 8 <= length {
            try handle.seek(toOffset: UInt64(offset))
            guard let head = try handle.read(upToCount: 16), head.count >= 8 else { return nil }
            var size = Int(head.bigEndianUInt32(at: 0)), header = 8
            if size == 1 {
                guard head.count == 16, let big = Int(exactly: head.bigEndianUInt64(at: 8)) else { return nil }
                size = big; header = 16
            }
            else if size == 0 { size = length - offset }
            guard size >= header, size <= length - offset else { return nil }
            result.append(Box(type: String(decoding: head[4..<8], as: UTF8.self), start: offset, size: size, header: header))
            offset += size
        }
        return offset == length ? result : nil
    }

    private static func header(_ size: Int, _ type: String) -> Data {
        var d = Data(); var be = UInt32(size).bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        d.append(contentsOf: Array(type.utf8))
        return d
    }
}

private extension Data {
    func bigEndianUInt32(at i: Int) -> UInt32 {
        let s = startIndex + i
        return self[s..<(s + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
    func bigEndianUInt64(at i: Int) -> UInt64 {
        let s = startIndex + i
        return self[s..<(s + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
