import CoreGraphics
import Foundation
import ImageIO

// Privacy checks for image outputs.
//
// "Strip Info" must leave nothing that identifies a person, a place, a device or a time. ImageIO's own answers are
// not enough on their own (a lossless JPEG copy reports clean properties while the old XMP and IPTC bytes are still in
// the file), so every check looks at three layers: ImageIO properties for every image index, every XMP tag ImageIO
// can see, and the raw bytes (XMP packets, Photoshop/IPTC blocks, Exif IFDs, PNG text chunks, JPEG segments).
// Tags an encoder always writes for technical reasons (pixel dimensions, colour space, orientation, tiling) are
// whitelisted explicitly so the check doesn't fail on output that is in fact clean.

/// One piece of identifying metadata found in a file.
struct MetadataFinding: Sendable, Hashable, CustomStringConvertible {
    enum Kind: Sendable { case location, personal }
    let kind: Kind
    let detail: String
    var description: String { detail }
}

enum ImageMetadataCheck {
    // MARK: Public API

    /// True if the file still has location, camera, author, date, XMP or IPTC info (anything but technical tags).
    static func hasPersonalInfo(_ url: URL) -> Bool { !findings(in: url).isEmpty }

    /// True if the file still says where it was taken (GPS, or a city/country/location in XMP or IPTC).
    static func hasLocation(_ url: URL) -> Bool { findings(in: url).contains { $0.kind == .location } }

    /// Everything identifying in the file. Empty means clean.
    static func findings(in url: URL) -> [MetadataFinding] {
        var found: [MetadataFinding] = []
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            found += propertyFindings(source)
        } else {
            found.append(.init(kind: .personal, detail: "unreadable image"))
        }
        if let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            found += ImageBytes.findings(in: data)
        }
        return Array(Set(found)).sorted { $0.detail < $1.detail }
    }

    // MARK: Whitelists

    /// XMP tags (namespace -> names) that carry no personal information and that ImageIO writes on its own.
    static let technicalTags: [String: Set<String>] = [
        "http://ns.adobe.com/exif/1.0/": ["PixelXDimension", "PixelYDimension", "ColorSpace"],
        "http://ns.adobe.com/tiff/1.0/": [
            "Orientation", "XResolution", "YResolution", "ResolutionUnit", "Compression", "PhotometricInterpretation",
            "TileWidth", "TileLength", "BitsPerSample", "SamplesPerPixel", "PlanarConfiguration", "ImageWidth",
            "ImageLength", "RowsPerStrip",
        ],
    ]
    /// `{Exif}` keys an encoder writes for every image.
    static let technicalExifKeys: Set<String> = Set([
        kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifColorSpace,
    ].map { $0 as String })
    static let personalTIFFKeys: [String] = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFDateTime,
        kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFHostComputer,
        kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFDocumentName,
    ].map { $0 as String }
    /// PNG text chunks as ImageIO reports them.
    static let personalPNGKeys: [String] = [
        "Author", "Description", "Comment", "Software", "Title", "CreationTime", "ModificationTime", "Copyright",
        "Disclaimer", "Warning", "Source",
    ]
    /// Dictionaries that only exist to carry identifying info (GPS is reported separately, as location).
    static let personalDictionaries: [String] = [
        kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary,
        kCGImageProperty8BIMDictionary, kCGImagePropertyCIFFDictionary, kCGImagePropertyDNGDictionary,
        kCGImagePropertyRawDictionary,
    ].map { $0 as String }

    /// XMP tags that say where a photo was taken.
    static func isLocationTag(namespace: String, name: String) -> Bool {
        switch namespace {
        case "http://ns.adobe.com/exif/1.0/", "http://cipa.jp/exif/1.0/": name.hasPrefix("GPS")
        case "http://ns.adobe.com/photoshop/1.0/": ["City", "State", "Country"].contains(name)
        case "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/": ["Location", "CountryCode", "CountryName", "City", "ProvinceState"].contains(name)
        case "http://iptc.org/std/Iptc4xmpExt/2008-02-29/": ["LocationCreated", "LocationShown"].contains(name)
        default: false
        }
    }

    static let locationIPTCKeys: [String] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationName,
        kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCSubLocation,
    ].map { $0 as String }

    // MARK: ImageIO layer

    private static func propertyFindings(_ source: CGImageSource) -> [MetadataFinding] {
        var found: [MetadataFinding] = []
        let fileProps = CGImageSourceCopyProperties(source, nil) as? [String: Any] ?? [:]
        found += dictionaryFindings(fileProps, at: "file")
        for i in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any] ?? [:]
            found += dictionaryFindings(props, at: "image \(i)")
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, i, nil) {
                found += tagFindings(metadata, at: "image \(i)")
            }
            for type in auxiliaryTypes where CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, i, type) != nil {
                found.append(.init(kind: .personal, detail: "image \(i): auxiliary image \(type)"))
            }
        }
        return found
    }

    private static var auxiliaryTypes: [CFString] {
        var types: [CFString] = [
            kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, kCGImageAuxiliaryDataTypeHDRGainMap,
        ]
        if #available(macOS 15.0, *) { types.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        return types
    }

    private static func dictionaryFindings(_ props: [String: Any], at place: String) -> [MetadataFinding] {
        var found: [MetadataFinding] = []
        func nonEmpty(_ key: String) -> [String: Any]? {
            guard let dict = props[key] as? [String: Any], !dict.isEmpty else { return nil }
            return dict
        }
        if nonEmpty(kCGImagePropertyGPSDictionary as String) != nil {
            found.append(.init(kind: .location, detail: "\(place): GPS"))
        }
        if let iptc = nonEmpty(kCGImagePropertyIPTCDictionary as String),
           locationIPTCKeys.contains(where: { iptc[$0] != nil }) {
            found.append(.init(kind: .location, detail: "\(place): IPTC location"))
        }
        for key in props.keys where personalDictionaries.contains(key) || key.hasPrefix("{Maker") {
            if nonEmpty(key) != nil { found.append(.init(kind: .personal, detail: "\(place): \(key)")) }
        }
        if let exif = nonEmpty(kCGImagePropertyExifDictionary as String) {
            for key in exif.keys where !technicalExifKeys.contains(key) {
                found.append(.init(kind: .personal, detail: "\(place): Exif \(key)"))
            }
        }
        if let tiff = nonEmpty(kCGImagePropertyTIFFDictionary as String) {
            for key in personalTIFFKeys where tiff[key] != nil {
                found.append(.init(kind: .personal, detail: "\(place): TIFF \(key)"))
            }
        }
        if let png = nonEmpty(kCGImagePropertyPNGDictionary as String) {
            for key in personalPNGKeys where png[key] != nil {
                found.append(.init(kind: .personal, detail: "\(place): PNG \(key)"))
            }
        }
        if let thumbs = props[kCGImagePropertyThumbnailImages as String] as? [Any], !thumbs.isEmpty {
            found.append(.init(kind: .personal, detail: "\(place): embedded thumbnail"))
        }
        return found
    }

    private static func tagFindings(_ metadata: CGImageMetadata, at place: String) -> [MetadataFinding] {
        var found: [MetadataFinding] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            let namespace = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            if isLocationTag(namespace: namespace, name: name) {
                found.append(.init(kind: .location, detail: "\(place): XMP \(name)"))
            } else if technicalTags[namespace]?.contains(name) != true {
                found.append(.init(kind: .personal, detail: "\(place): XMP \(namespace)\(name)"))
            }
            return true
        }
        return found
    }

    /// Removes every location tag (GPS, IPTC/Photoshop city, state, country, location) from `metadata`.
    static func removeLocation(from metadata: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let namespace = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            if isLocationTag(namespace: namespace, name: name) { paths.append(path as String) }
            return true
        }
        for path in paths { CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString) }
    }
}

// MARK: - Byte layer

/// Looks at the raw file for metadata that ImageIO might not report.
enum ImageBytes {
    static func findings(in data: Data) -> [MetadataFinding] {
        var found: [MetadataFinding] = []
        // Indexed in place (the file is memory-mapped), so a large TIFF isn't copied.
        let bytes = data.startIndex == 0 ? data : Data(data)
        let isJPEG = bytes.starts(with: [0xFF, 0xD8])
        var markers = [("<x:xmpmeta", "XMP packet"), ("http://ns.adobe.com/xap", "XMP namespace"), ("<?xpacket", "XMP packet")]
        // In a JPEG, Photoshop blocks are judged segment by segment (ImageIO itself writes an empty one).
        if !isJPEG { markers.append(("Photoshop 3.0\0", "Photoshop/IPTC block")) }
        for (marker, label) in markers where bytes.range(of: Data(marker.utf8)) != nil {
            found.append(.init(kind: .personal, detail: "bytes: \(label)"))
        }
        // Every embedded Exif block (JPEG APP1, HEIC Exif item, WebP EXIF chunk...).
        let exifHeader = Data("Exif\0\0".utf8)
        var searchFrom = 0
        while let range = bytes.range(of: exifHeader, in: searchFrom..<bytes.count) {
            found += TIFFInspector.findings(bytes, at: range.upperBound, embedded: true)
            searchFrom = range.upperBound
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { found += pngFindings(bytes) }
        if isJPEG { found += jpegFindings(bytes) }
        if bytes.starts(with: Array("II*\0".utf8)) || bytes.starts(with: Array("MM\0*".utf8)) {
            found += TIFFInspector.findings(bytes, at: 0, embedded: false)
        }
        return found
    }

    private static func pngFindings(_ bytes: Data) -> [MetadataFinding] {
        var found: [MetadataFinding] = []
        var i = 8
        while i + 8 <= bytes.count {
            let length = Int(BigEndian.u32(bytes, i))
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            let body = i + 8
            guard length >= 0, body + length + 4 <= bytes.count else { break }
            switch type {
            case "tEXt", "zTXt", "iTXt": found.append(.init(kind: .personal, detail: "bytes: PNG \(type) chunk"))
            case "tIME": found.append(.init(kind: .personal, detail: "bytes: PNG time chunk"))
            case "eXIf": found += TIFFInspector.findings(bytes, at: body, embedded: true)
            case "IEND": return found
            default: break
            }
            i = body + length + 4
        }
        return found
    }

    private static func jpegFindings(_ bytes: Data) -> [MetadataFinding] {
        guard let parsed = JPEGStructure(bytes) else { return [.init(kind: .personal, detail: "bytes: unparseable JPEG")] }
        var found: [MetadataFinding] = []
        for segment in parsed.segments {
            switch segment.verdict(bytes) {
            case .keep, .technical: break
            case .drop(let why): found.append(.init(kind: .personal, detail: "bytes: JPEG \(why)"))
            }
        }
        if parsed.trailing.contains(where: { bytes[$0] != 0 }) {
            found.append(.init(kind: .personal, detail: "bytes: data after the JPEG image (extra images)"))
        }
        return found
    }
}

enum BigEndian {
    static func u16(_ b: Data, _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    static func u32(_ b: Data, _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

/// Reads TIFF-structured metadata (a TIFF file, or an Exif block, which is a small TIFF).
enum TIFFInspector {
    /// IFD0 tags that identify a person, device, time or place.
    static let personalIFD0Tags: [UInt16: String] = [
        0x010E: "ImageDescription", 0x010F: "Make", 0x0110: "Model", 0x0131: "Software", 0x0132: "DateTime",
        0x013B: "Artist", 0x013C: "HostComputer", 0x8298: "Copyright", 0x02BC: "XMP", 0x83BB: "IPTC",
        0x8649: "Photoshop", 0x927C: "MakerNote", 0x9286: "UserComment", 0x8825: "GPS",
    ]
    /// Exif IFD tags that identify a person, device or time.
    static let personalExifTags: [UInt16: String] = [
        0x9003: "DateTimeOriginal", 0x9004: "DateTimeDigitized", 0x9010: "OffsetTime", 0x9011: "OffsetTimeOriginal",
        0x9012: "OffsetTimeDigitized", 0x9290: "SubSecTime", 0x9291: "SubSecTimeOriginal", 0x9292: "SubSecTimeDigitized",
        0x927C: "MakerNote", 0x9286: "UserComment", 0xA420: "ImageUniqueID", 0xA430: "CameraOwnerName",
        0xA431: "BodySerialNumber", 0xA433: "LensMake", 0xA434: "LensModel", 0xA435: "LensSerialNumber",
    ]

    /// `embedded` = an Exif block, where a second IFD is an embedded thumbnail. In a TIFF file it's another page.
    static func findings(_ b: Data, at base: Int, embedded: Bool) -> [MetadataFinding] {
        guard base + 8 <= b.count else { return [] }
        let little: Bool
        switch (b[base], b[base + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return []
        }
        func u16(_ at: Int) -> UInt16? {
            guard at >= 0, at + 2 <= b.count else { return nil }
            return little ? UInt16(b[at]) | UInt16(b[at + 1]) << 8 : BigEndian.u16(b, at)
        }
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= b.count else { return nil }
            return little ? UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24 : BigEndian.u32(b, at)
        }
        guard u16(base + 2) == 42, let ifd0 = u32(base + 4) else { return [] }
        let label = embedded ? "Exif" : "TIFF"
        /// Returns the tag -> value-or-offset entries of one IFD and the offset of the next IFD.
        func entries(_ offset: UInt32) -> (tags: [UInt16: UInt32], next: UInt32)? {
            let start = base + Int(offset)
            guard offset >= 8, let count = u16(start), count < 4096 else { return nil }
            var tags: [UInt16: UInt32] = [:]
            for e in 0..<Int(count) {
                let at = start + 2 + e * 12
                guard let tag = u16(at), let value = u32(at + 8) else { return nil }
                tags[tag] = value
            }
            return (tags, u32(start + 2 + Int(count) * 12) ?? 0)
        }
        guard let first = entries(ifd0) else { return [] }
        var found: [MetadataFinding] = []
        for (tag, name) in personalIFD0Tags where first.tags[tag] != nil {
            found.append(.init(kind: tag == 0x8825 ? .location : .personal, detail: "bytes: \(label) \(name)"))
        }
        if let exifOffset = first.tags[0x8769], let exif = entries(exifOffset) {
            for (tag, name) in personalExifTags where exif.tags[tag] != nil {
                found.append(.init(kind: .personal, detail: "bytes: \(label) \(name)"))
            }
        }
        if first.next != 0 {
            found.append(.init(kind: .personal, detail: embedded ? "bytes: Exif thumbnail" : "bytes: extra TIFF image"))
        }
        return found
    }
}

// MARK: - JPEG

/// The marker segments of a JPEG, up to its end-of-image marker.
struct JPEGStructure {
    struct Piece {
        /// The marker byte (0xE1 for APP1...), or nil for entropy-coded image data.
        let marker: UInt8?
        let range: Range<Int>
        /// Payload after the 2-byte length (empty for standalone markers and image data).
        let payload: Range<Int>

        enum Verdict { case keep, technical, drop(String) }

        func verdict(_ b: Data) -> Verdict {
            guard let marker else { return .keep }
            func starts(_ text: String) -> Bool { b[payload].starts(with: Array(text.utf8)) }
            switch marker {
            case 0xE0:
                if starts("JFIF\0") {
                    let p = payload.lowerBound
                    guard payload.count >= 14 else { return .drop("APP0 block") }
                    return payload.count > 14 || b[p + 12] != 0 || b[p + 13] != 0 ? .drop("JFIF thumbnail") : .technical
                }
                return .drop(starts("JFXX\0") ? "JFIF thumbnail" : "APP0 block")
            case 0xE1:
                if starts("Exif\0\0") { return .technical } // its tags are checked by TIFFInspector
                return .drop(starts("http://ns.adobe.com/xap") || starts("http://ns.adobe.com/xmp") ? "XMP block" : "APP1 block")
            case 0xE2: return starts("ICC_PROFILE\0") ? .keep : .drop(starts("MPF\0") ? "multi-picture (extra images)" : "APP2 block")
            case 0xEE: return starts("Adobe") ? .keep : .drop("APP14 block")
            case 0xED: return PhotoshopResources.isEncoderPlaceholder(b, payload) ? .technical : .drop("Photoshop/IPTC block")
            case 0xE3...0xEF: return .drop(String(format: "APP%d block", Int(marker) - 0xE0))
            case 0xFE: return .drop("comment")
            default: return .keep
            }
        }
    }

    let segments: [Piece]
    /// Bytes after the end-of-image marker (appended images such as MPF gain maps live here).
    let trailing: Range<Int>

    init?(_ b: Data) {
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var pieces: [Piece] = []
        var i = 2
        while true {
            guard i < b.count else { return nil }
            guard b[i] == 0xFF else { return nil }
            var m = i
            while m + 1 < b.count, b[m + 1] == 0xFF { m += 1 } // fill bytes
            guard m + 1 < b.count else { return nil }
            let marker = b[m + 1]
            if marker == 0xD9 {
                segments = pieces
                trailing = (m + 2)..<b.count
                return
            }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                pieces.append(Piece(marker: marker, range: i..<(m + 2), payload: (m + 2)..<(m + 2)))
                i = m + 2
                continue
            }
            guard m + 3 < b.count else { return nil }
            let length = Int(BigEndian.u16(b, m + 2))
            let end = m + 2 + length
            guard length >= 2, end <= b.count else { return nil }
            pieces.append(Piece(marker: marker, range: i..<end, payload: (m + 4)..<end))
            i = end
            if marker == 0xDA {
                // Entropy-coded data runs until the next marker that isn't a stuffed 0xFF00 or a restart marker.
                var j = i
                while j + 1 < b.count {
                    if b[j] == 0xFF {
                        let next = b[j + 1]
                        if next == 0x00 || (0xD0...0xD7).contains(next) { j += 2; continue }
                        if next == 0xFF { j += 1; continue }
                        break
                    }
                    j += 1
                }
                guard j + 1 < b.count else { return nil }
                pieces.append(Piece(marker: nil, range: i..<j, payload: i..<j))
                i = j
            }
        }
    }
}

/// Photoshop image resource blocks ("8BIM" records) inside a JPEG APP13 segment.
enum PhotoshopResources {
    /// ImageIO writes an APP13 segment to every JPEG it encodes: an empty IPTC record (0x0404) plus the MD5 digest of
    /// that empty record (0x0425). That carries no information; anything else in APP13 does.
    static func isEncoderPlaceholder(_ b: Data, _ payload: Range<Int>) -> Bool {
        let header = Array("Photoshop 3.0\0".utf8)
        guard b[payload].starts(with: header) else { return false }
        var i = payload.lowerBound + header.count
        var sawAny = false
        while i < payload.upperBound {
            guard i + 7 <= payload.upperBound, b[i..<(i + 4)].elementsEqual(Array("8BIM".utf8)) else { return false }
            let id = BigEndian.u16(b, i + 4)
            var j = i + 6
            let nameLength = Int(b[j])
            j += 1 + nameLength
            if (1 + nameLength) % 2 == 1 { j += 1 } // the name is padded to an even length
            guard j + 4 <= payload.upperBound else { return false }
            let size = Int(BigEndian.u32(b, j))
            j += 4
            guard j + size <= payload.upperBound else { return false }
            switch id {
            case 0x0404 where size == 0, 0x0425: break // empty IPTC record, and its digest
            default: return false
            }
            sawAny = true
            i = j + size + (size % 2)
        }
        return sawAny
    }
}

/// Removes metadata from a JPEG without touching the compressed pixels (no quality loss).
enum JPEGStripper {
    /// Keeps only what decoding needs (tables, frame, scans, ICC profile, Adobe colour transform) plus an orientation
    /// tag; drops Exif (and its GPS and thumbnail), XMP, IPTC, comments, MPF and anything after the image.
    static func strip(_ data: Data, orientation: CGImagePropertyOrientation) -> Data? {
        let b = data.startIndex == 0 ? data : Data(data)
        guard let parsed = JPEGStructure(b) else { return nil }
        var body: [UInt8] = []
        var jfif: [UInt8] = []
        for piece in parsed.segments {
            let p = piece.payload.lowerBound
            switch piece.verdict(b) {
            case .drop:
                // A JFIF block with a thumbnail: keep version, units and density, drop the thumbnail.
                if piece.marker == 0xE0, jfif.isEmpty, b[piece.payload].starts(with: Array("JFIF\0".utf8)), piece.payload.count >= 14 {
                    jfif = [0xFF, 0xE0, 0x00, 0x10] + Array(b[p..<(p + 12)]) + [0, 0]
                }
            case .technical where piece.marker == 0xE1: continue // the old Exif block, replaced by the orientation block
            case .technical where piece.marker == 0xE0: if jfif.isEmpty { jfif = Array(b[piece.range]) }
            default: body += b[piece.range]
            }
        }
        var out: [UInt8] = [0xFF, 0xD8] + jfif
        if orientation != .up { out += orientationSegment(orientation) }
        out += body
        out += [0xFF, 0xD9]
        return Data(out)
    }

    /// A minimal big-endian Exif APP1 block holding only the orientation tag.
    static func orientationSegment(_ orientation: CGImagePropertyOrientation) -> [UInt8] {
        let value = UInt16(orientation.rawValue)
        let tiff: [UInt8] = Array("MM".utf8) + [0x00, 0x2A, 0, 0, 0, 8] // header, IFD0 at 8
            + [0x00, 0x01] // one entry
            + [0x01, 0x12, 0x00, 0x03, 0, 0, 0, 1, UInt8(value >> 8), UInt8(value & 0xFF), 0, 0] // Orientation, SHORT, 1
            + [0, 0, 0, 0] // no next IFD (no thumbnail)
        let payload = Array("Exif\0\0".utf8) + tiff
        let length = payload.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }
}
