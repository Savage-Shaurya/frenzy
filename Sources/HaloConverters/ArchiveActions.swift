import Darwin
import Foundation
import HaloCore
import UniformTypeIdentifiers

/// Zip and Unzip on Halo's own ZIP code (`ZipArchive.swift`), in the sandboxed worker like every other conversion.
///
/// Zip works like Finder's Compress: one item becomes "name.zip" next to it, several become "Archive.zip".
/// Unzip always produces one folder. Hostile archives are refused whole (unsafe paths, passwords, unknown methods)
/// and capped (items, unpacked size, free space), so a zip bomb can't fill the disk.
///
/// Unpack handles the other archives people get sent: `.tar`, `.tgz`, `.tar.gz`, `.gz`, `.tar.xz` and `.xz`. There's no
/// bzip2 route in Apple's Compression framework, so `.bz2` isn't offered.
enum ArchiveActions {
    private static let tar = UTType("public.tar-archive") ?? UTType(filenameExtension: "tar") ?? .data
    private static let gzip = UTType("org.gnu.gnu-zip-archive") ?? .gzip
    private static let xz = UTType("org.tukaani.xz-archive") ?? UTType(filenameExtension: "xz") ?? .data

    static var all: [ConversionAction] {
        [
            ConversionAction(
                id: "archive.unpack", title: "Unpack", subtitle: "Opens the archive", symbolName: "shippingbox",
                // `.tgz` conforms to the gzip type.
                category: .archive, inputTypes: [tar, gzip, xz],
                defaultRank: 10, converter: ClosureConverter(unpack)),
            // Folders only: it would crowd every ring otherwise, and Zip is what people want for a loose file.
            ConversionAction(
                id: "archive.to-tgz", title: "tar.gz", subtitle: "Makes a .tar.gz", symbolName: "shippingbox.fill",
                category: .archive, inputTypes: [.folder], cardinality: .combined(min: 1),
                defaultRank: 901, converter: ClosureConverter(toTarGzip)),
            ConversionAction(
                id: "archive.unzip", title: "Unzip", subtitle: "To a folder", symbolName: "folder",
                category: .archive, inputTypes: [.zip],
                defaultRank: 10, converter: ClosureConverter(unzip)),
            // Any files, folders or a mix. Ranked last so it never pushes a real conversion off the ring.
            ConversionAction(
                id: "archive.zip", title: "Zip", subtitle: "Makes a .zip", symbolName: "archivebox",
                category: .archive, inputTypes: [.item], cardinality: .combined(min: 1),
                defaultRank: 900, converter: ClosureConverter(zip)),
        ]
    }

    struct Limits: Sendable {
        /// Files plus folders an unzip may create. Matches the app's cap on items in one placed folder.
        var maxItems = 20_000
        var maxUnpackedBytes: Int64 = 10 << 30
        var maxZipBytes: Int64 = ZipWriter.maxBytes
        var maxZipItems = ZipWriter.maxEntries
    }

    /// Stored, not deflated: these are compressed already, so deflating would only cost time.
    static let alreadyCompressed: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "mp4", "m4v", "mov", "m4a", "mp3", "aac",
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "docx", "xlsx", "pptx", "pages", "numbers", "key",
        "jar", "epub",
    ]

    // MARK: Zip

    @Sendable static func zip(_ job: ConversionJob) async throws -> [URL] { try zip(job, limits: Limits()) }

    static func zip(_ job: ConversionJob, limits: Limits) throws -> [URL] {
        let items = try plan(job.inputs, limits: limits)
        guard let first = job.inputs.first, !items.isEmpty else { throw ConversionError.engine("There was nothing to zip.") }
        let name = job.inputs.count == 1 ? first.url.lastPathComponent : "Archive"
        let out = try job.makeOutput(named: name, in: first.url.deletingLastPathComponent(), pathExtension: "zip")
        let writer = try ZipWriter(creating: out.temporaryURL)
        let total = Double(max(1, items.reduce(0) { $0 + $1.size }))
        var done: Int64 = 0
        for item in items {
            try Task.checkCancellation()
            if item.isDirectory {
                try writer.addDirectory(path: item.path, modified: item.modified, permissions: item.permissions)
            } else {
                let compress = !alreadyCompressed.contains(item.source.pathExtension.lowercased())
                try writer.addFile(from: item.source, path: item.path, modified: item.modified,
                                   permissions: item.permissions, compress: compress) { bytes in
                    done += Int64(bytes)
                    job.progress(Double(done) / total)
                }
            }
        }
        try writer.finish()
        return [try out.commit()]
    }

    struct ZipItem {
        let source: URL
        /// Path inside the archive, "/"-separated, no trailing slash.
        let path: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date
        let permissions: UInt16
    }

    /// Everything that goes into the archive, walked before writing so limits fail fast and progress is honest.
    /// Dropped items are followed if they are links; inside folders, links, `.DS_Store` and special files are left out.
    static func plan(_ inputs: [InputFile], limits: Limits) throws -> [ZipItem] {
        var items: [ZipItem] = []
        var bytes: Int64 = 0
        var topNames = Set<String>()
        func add(_ source: URL, _ path: String, _ info: FileInfo) throws {
            items.append(ZipItem(source: source, path: path, isDirectory: info.kind == .directory, size: info.size,
                                 modified: info.modified, permissions: info.permissions))
            // Data plus a local and a central header per entry. Checked before adding, so a huge sparse file can't overflow.
            guard info.size <= limits.maxZipBytes else { throw ZipWriter.tooBig }
            bytes += info.size + 76 + 2 * Int64(path.utf8.count + 1)
            guard items.count <= limits.maxZipItems, bytes <= limits.maxZipBytes else { throw ZipWriter.tooBig }
        }
        for input in inputs {
            try Task.checkCancellation()
            // A dropped link is followed once, here; every later read refuses links.
            let source = input.url.resolvingSymlinksInPath()
            guard let info = FileInfo(source.path, followLinks: false) else { throw ConversionError.unreadable(input.url) }
            let top = uniqueName(input.url.lastPathComponent, taken: &topNames)
            switch info.kind {
            case .file:
                try add(source, top, info)
            case .directory:
                try add(source, top, info)
                try walk(source, top: top, add: add)
            case .link, .other:
                continue
            }
        }
        return items
    }

    private static func walk(_ root: URL, top: String, add: (URL, String, FileInfo) throws -> Void) throws {
        guard access(root.path, R_OK | X_OK) == 0, let walker = FileManager.default.enumerator(atPath: root.path) else {
            throw ConversionError.unreadable(root)
        }
        var relatives: [String] = []
        while let relative = walker.nextObject() as? String {
            try Task.checkCancellation()
            let path = root.appendingPathComponent(relative).path
            if (relative as NSString).lastPathComponent == ".DS_Store" { continue }
            guard let info = FileInfo(path, followLinks: false) else { continue }
            switch info.kind {
            case .link: walker.skipDescendants()
            case .directory:
                // A folder Halo can't list would silently go missing from the archive: refuse instead.
                guard access(path, R_OK | X_OK) == 0 else { throw ConversionError.unreadable(URL(fileURLWithPath: path)) }
                relatives.append(relative)
            case .file:
                guard access(path, R_OK) == 0 else { throw ConversionError.unreadable(URL(fileURLWithPath: path)) }
                relatives.append(relative)
            case .other: continue
            }
        }
        // Sorted, so a folder always comes before what it holds and the archive is the same every time.
        for relative in relatives.sorted() {
            let url = root.appendingPathComponent(relative)
            guard let info = FileInfo(url.path, followLinks: false), info.kind == .file || info.kind == .directory else { continue }
            try add(url, top + "/" + relative, info)
        }
    }

    /// "photo.jpg", then "photo 2.jpg" when two dropped items share a name.
    private static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name
        var n = 2
        while taken.contains(candidate.lowercased()) {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    struct FileInfo {
        enum Kind { case file, directory, link, other }
        let kind: Kind
        let size: Int64
        let modified: Date
        let permissions: UInt16

        init?(_ path: String, followLinks: Bool) {
            var s = Darwin.stat()
            let status: Int32 = followLinks ? stat(path, &s) : lstat(path, &s)
            guard status == 0 else { return nil }
            switch s.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .link
            default: kind = .other
            }
            size = kind == .file ? Int64(s.st_size) : 0
            modified = Date(timeIntervalSince1970: TimeInterval(s.st_mtimespec.tv_sec) + TimeInterval(s.st_mtimespec.tv_nsec) / 1e9)
            permissions = UInt16(s.st_mode & 0o777)
        }
    }

    // MARK: tar.gz

    @Sendable static func toTarGzip(_ job: ConversionJob) async throws -> [URL] {
        var limits = Limits()
        limits.maxZipBytes = TarGzipWriter.maxBytes
        limits.maxZipItems = 500_000
        let items = try plan(job.inputs, limits: limits)
        guard let first = job.inputs.first, !items.isEmpty else { throw ConversionError.engine("There was nothing to archive.") }
        let name = job.inputs.count == 1 ? first.url.lastPathComponent + ".tar" : "Archive.tar"
        let out = try job.makeOutput(named: name, in: first.url.deletingLastPathComponent(), pathExtension: "gz")
        let writer = try TarGzipWriter(creating: out.temporaryURL)
        let total = Double(max(1, items.reduce(0) { $0 + $1.size }))
        var done: Int64 = 0
        for item in items {
            try Task.checkCancellation()
            if item.isDirectory {
                try writer.addDirectory(path: item.path, modified: item.modified, permissions: item.permissions)
            } else {
                try writer.addFile(from: item.source, path: item.path, modified: item.modified, permissions: item.permissions,
                                   size: item.size) { bytes in
                    done += Int64(bytes)
                    job.progress(min(0.99, Double(done) / total))
                }
            }
        }
        try writer.finish()
        return [try out.commit()]
    }

    // MARK: Unpack (tar, gzip, xz)

    @Sendable static func unpack(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            try unpack(input, job: job, limits: Limits(), progress: progress)
        }
    }

    enum PackedKind: Equatable { case tar, gzip, xz }

    /// What the file really is, from its first bytes: extensions lie, and a `.gz` can hold anything.
    static func packedKind(of url: URL) throws -> PackedKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ConversionError.unreadable(url) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: TarFormat.blockSize)) ?? Data()
        if head.starts(with: [0x1F, 0x8B]) { return .gzip }
        if head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if TarReader.isHeader(head) { return .tar }
        throw TarFormat.damaged
    }

    private static func chunks(_ url: URL, kind: PackedKind) throws -> any ByteChunks {
        let file = try FileChunks(url)
        switch kind {
        case .tar: return file
        case .gzip: return GzipChunks(file)
        case .xz: return try XZChunks(file)
        }
    }

    /// True when what's inside the compression is a tar. A plain `notes.txt.gz` is not, whatever its name.
    private static func holdsTar(_ url: URL, kind: PackedKind) throws -> Bool {
        if kind == .tar { return true }
        let stream = try chunks(url, kind: kind)
        var head = Data()
        while head.count < TarFormat.blockSize, let piece = try stream.next() { head += piece }
        return TarReader.isHeader(head)
    }

    /// "photos.tar.gz" and "photos.tgz" both give "photos".
    static func unpackedName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for ending in [".tar.gz", ".tar.xz", ".tgz", ".txz", ".tar", ".gz", ".xz"] where name.lowercased().hasSuffix(ending) {
            name = String(name.dropLast(ending.count))
            break
        }
        return name
    }

    static func unpack(_ input: InputFile, job: ConversionJob, limits: Limits,
                       progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let kind = try packedKind(of: input.url)
        if try holdsTar(input.url, kind: kind) {
            return try unpackTar(input, kind: kind, job: job, limits: limits, progress: progress)
        }
        return try gunzip(input, kind: kind, job: job, limits: limits, progress: progress)
    }

    /// One compressed file. Its name comes from the file on disk: a name stored inside the gzip can't choose where it lands.
    private static func gunzip(_ input: InputFile, kind: PackedKind, job: ConversionJob, limits: Limits,
                               progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let name = unpackedName(input.url)
        let base = name.isEmpty || name.hasPrefix(".") ? "Unpacked" : name
        let ext = (base as NSString).pathExtension.lowercased()
        // A plain document keeps its name beside the original. Anything else ("dump.sql", "run.command") goes inside a folder,
        // the same way Unzip does it: non-executable, quarantined and never looking like an app in Finder.
        let plainFile = StagedPlacement.allowedExtensions.contains(ext) && !ext.isEmpty
        let folder: OutputTarget?, target: OutputTarget?, destination: URL
        if plainFile {
            folder = nil
            let made = try job.makeOutput(named: (base as NSString).deletingPathExtension, in: input.url.deletingLastPathComponent(), pathExtension: ext)
            target = made
            destination = made.temporaryURL
        } else {
            var folderName = base
            while StagedPlacement.hasDangerousExtension(folderName) { folderName = (folderName as NSString).deletingPathExtension }
            if folderName.isEmpty { folderName = "Unpacked" }
            let made = try job.makeOutputFolder(named: folderName, in: input.url.deletingLastPathComponent())
            folder = made
            target = nil
            destination = made.temporaryURL.appendingPathComponent(base)
        }

        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw ConversionError.writeFailed(destination, String(cString: strerror(errno))) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let total = Double(max(1, AVSupport.fileSize(input.url)))
        let free = freeSpace(at: destination.deletingLastPathComponent())
        let stream = try chunks(input.url, kind: kind)
        var written: Int64 = 0
        while let piece = try stream.next() {
            try Task.checkCancellation()
            written += Int64(piece.count)
            try checkRoom(written, limits: limits, free: free)
            do { try handle.write(contentsOf: piece) } catch { throw ConversionError.writeFailed(destination, error.localizedDescription) }
            progress(min(0.99, Double(stream.fileBytesRead) / total))
        }
        try handle.close()
        if let target { return try target.commit() }
        guard let folder else { throw TarFormat.damaged }
        return try folder.commit()
    }

    /// A tar in two passes, as with a zip: first read every header and check everything, writing nothing, so a hostile
    /// archive is refused whole. Compressed tars have no index, so the check has to read through them once.
    private static func unpackTar(_ input: InputFile, kind: PackedKind, job: ConversionJob, limits: Limits,
                                  progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let fileSize = Double(max(1, AVSupport.fileSize(input.url)))
        let scan = TarReader(try chunks(input.url, kind: kind))
        var folders = Set<String>()
        var files = 0
        var unpacked: Int64 = 0
        var fileEntries: [[String]] = []
        var sawAny = false
        while let entry = try scan.next() {
            try Task.checkCancellation()
            guard let parts = safeComponents(entry.name) else { throw unsafeTarPaths }
            guard let first = parts.first else { continue }
            sawAny = true
            if isMacJunk(parts, first: first) { continue }
            switch entry.kind {
            case .link, .special: continue
            case .directory:
                for k in stride(from: parts.count, through: 1, by: -1) {
                    guard folders.insert(parts.prefix(k).joined(separator: "/")).inserted else { break }
                }
            case .file:
                for k in stride(from: parts.count - 1, through: 1, by: -1) {
                    guard folders.insert(parts.prefix(k).joined(separator: "/")).inserted else { break }
                }
                files += 1
                unpacked += entry.size
                fileEntries.append(parts)
                guard unpacked <= limits.maxUnpackedBytes else {
                    throw ConversionError.engine("This archive would unpack to more than the \(size(limits.maxUnpackedBytes)) Frenzy unpacks at once.")
                }
                try scan.readData { _ in try Task.checkCancellation() }
            }
            guard folders.count + files <= limits.maxItems else {
                throw ConversionError.engine("This archive holds more than \(limits.maxItems.formatted()) items, more than Frenzy unpacks at once.")
            }
            progress(min(0.3, 0.3 * Double(scan.fileBytesRead) / fileSize))
        }
        guard sawAny, files + folders.count > 0 else { throw ConversionError.engine("This archive is empty.") }

        // One folder at the top: unpack it as that folder, not "name/name/...".
        var folderName = unpackedName(input.url)
        let tops = Set(fileEntries.map { $0[0] } + folders.map { String($0.prefix { $0 != "/" }) })
        var dropTop = false
        if tops.count == 1, let only = tops.first, !only.hasPrefix("."), !StagedPlacement.hasDangerousExtension(only),
           !fileEntries.contains(where: { $0.count == 1 }) {
            folderName = only
            dropTop = true
        }
        while StagedPlacement.hasDangerousExtension(folderName) { folderName = (folderName as NSString).deletingPathExtension }
        if folderName.isEmpty || folderName.hasPrefix(".") { folderName = "Unpacked" }

        let folder = try job.makeOutputFolder(named: folderName, in: input.url.deletingLastPathComponent())
        let root = folder.temporaryURL
        let free = freeSpace(at: root)
        try checkRoom(unpacked, limits: limits, free: free)

        let fm = FileManager.default
        let reader = TarReader(try chunks(input.url, kind: kind))
        while let entry = try reader.next() {
            try Task.checkCancellation()
            guard var parts = safeComponents(entry.name) else { throw unsafeTarPaths }
            guard let first = parts.first else { continue }
            if isMacJunk(parts, first: first) { continue }
            if dropTop {
                parts.removeFirst()
                guard !parts.isEmpty else { continue }
            }
            let target = parts.reduce(root) { $0.appendingPathComponent($1) }
            switch entry.kind {
            case .link, .special: continue
            case .directory:
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .file:
                // A file already holding a folder's name, or a duplicate entry: keep the first, like Archive Utility.
                guard (try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else { continue }
                let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                guard fd >= 0 else {
                    if errno == EEXIST || errno == ENOTDIR || errno == EISDIR { continue }
                    throw ConversionError.writeFailed(target, String(cString: strerror(errno)))
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try reader.readData { piece in
                    try Task.checkCancellation()
                    do { try handle.write(contentsOf: piece) } catch { throw ConversionError.writeFailed(target, error.localizedDescription) }
                }
                try handle.close()
                if let date = entry.modified { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path) }
            }
            progress(min(0.99, 0.3 + 0.7 * Double(reader.fileBytesRead) / fileSize))
        }
        return try folder.commit()
    }

    /// Finder's leftovers: `.DS_Store`, `__MACOSX`, and the `._name` twins Apple's own tar adds for extended attributes.
    private static func isMacJunk(_ parts: [String], first: String) -> Bool {
        first == "__MACOSX" || parts.last == ".DS_Store" || parts.last?.hasPrefix("._") == true
    }

    private static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private static func checkRoom(_ bytes: Int64, limits: Limits, free: Int64?) throws {
        guard bytes <= limits.maxUnpackedBytes else {
            throw ConversionError.engine("This archive would unpack to more than the \(size(limits.maxUnpackedBytes)) Frenzy unpacks at once.")
        }
        if let free, bytes > free - (256 << 20) {
            throw ConversionError.engine("There isn't enough free space to unpack this. It needs \(size(bytes)).")
        }
    }

    static let unsafeTarPaths = ConversionError.engine("This archive has files that would land outside its folder, so Frenzy didn't open it.")

    // MARK: Unzip

    @Sendable static func unzip(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            try unzip(input, job: job, limits: Limits(), progress: progress)
        }
    }

    struct PlannedEntry {
        let entry: ZipReader.Entry
        let components: [String]
        let isDirectory: Bool
    }

    static func unzip(_ input: InputFile, job: ConversionJob, limits: Limits,
                      progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        // Twice the item cap: Finder's zips carry a `__MACOSX` twin per file, which is left out and not counted below.
        let reader = try ZipReader(url: input.url, maxEntries: limits.maxItems * 2)
        var planned = try plan(reader.entries)
        guard !planned.isEmpty else { throw ConversionError.engine("This zip is empty.") }

        // One folder at the top ("Photos/…"): unpack it as that folder instead of "Photos/Photos/…".
        var folderName = input.url.deletingPathExtension().lastPathComponent
        let tops = Set(planned.map { $0.components[0] })
        if tops.count == 1, let only = tops.first, !only.hasPrefix("."), !StagedPlacement.hasDangerousExtension(only),
           !planned.contains(where: { $0.components.count == 1 && !$0.isDirectory }) {
            folderName = only
            planned = planned.compactMap { p in
                p.components.count > 1 ? PlannedEntry(entry: p.entry, components: Array(p.components.dropFirst()), isDirectory: p.isDirectory) : nil
            }
        }
        // "Tool.app.zip" unpacks to "Tool": a folder ending in ".app" would look like an app to Finder.
        while StagedPlacement.hasDangerousExtension(folderName) { folderName = (folderName as NSString).deletingPathExtension }
        if folderName.isEmpty || folderName.hasPrefix(".") { folderName = "Unzipped" }

        // Every item the unzip creates, including folders only implied by paths. Stops at the cap, so a crafted
        // directory can't make this set huge first.
        var folders = Set<String>()
        var files = 0
        var unpacked: Int64 = 0
        for p in planned {
            let depth = p.isDirectory ? p.components.count : p.components.count - 1
            // Deepest first: once a folder is known, its parents are too.
            for k in stride(from: depth, through: 1, by: -1) {
                guard folders.insert(p.components.prefix(k).joined(separator: "/")).inserted else { break }
            }
            if !p.isDirectory {
                files += 1
                unpacked += p.entry.size
            }
            guard folders.count + files <= limits.maxItems else { throw ZipReader.tooManyItems(limits.maxItems) }
        }
        guard unpacked <= limits.maxUnpackedBytes else {
            throw ConversionError.engine("This zip would unpack to \(size(unpacked)), more than the \(size(limits.maxUnpackedBytes)) Frenzy unpacks at once.")
        }

        let folder = try job.makeOutputFolder(named: folderName, in: input.url.deletingLastPathComponent())
        let root = folder.temporaryURL
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let free, unpacked > free - (256 << 20) {
            throw ConversionError.engine("There isn't enough free space to unzip this. It needs \(size(unpacked)).")
        }

        let fm = FileManager.default
        let total = Double(max(1, planned.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.entry.compressedSize) }))
        var done: Int64 = 0
        for p in planned {
            try Task.checkCancellation()
            let target = p.components.reduce(root) { $0.appendingPathComponent($1) }
            if p.isDirectory {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            // A file already holding a folder's name, or a duplicate entry: keep the first, like Archive Utility.
            guard (try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else { continue }
            let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            guard fd >= 0 else {
                if errno == EEXIST || errno == ENOTDIR || errno == EISDIR { continue }
                throw ConversionError.writeFailed(target, String(cString: strerror(errno)))
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try reader.extract(p.entry, to: handle) { bytes in
                done += Int64(bytes)
                progress(Double(done) / total)
            }
            try handle.close()
            if let date = ZipFormat.date(dosTime: p.entry.time, dosDate: p.entry.date) {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
            }
        }
        return try folder.commit()
    }

    /// Checks every entry before anything is written. Refuses the whole archive on an unsafe path, a password or an
    /// unknown method; leaves out Finder's `__MACOSX` resource forks, `.DS_Store`, links and special files.
    static func plan(_ entries: [ZipReader.Entry]) throws -> [PlannedEntry] {
        // Entries sharing or overlapping data are a zip-bomb trick (one stream unpacked thousands of times). A local
        // header is at least 30 bytes plus the name, so this lower bound never rejects a real archive.
        let byOffset = entries.sorted { $0.localOffset < $1.localOffset }
        for (a, b) in Swift.zip(byOffset, byOffset.dropFirst())
        where a.localOffset + 30 + Int64(a.rawName.count) + a.compressedSize > b.localOffset {
            throw ZipReader.damaged
        }
        var planned: [PlannedEntry] = []
        for entry in entries {
            guard let name = entry.name, let parts = safeComponents(name) else { throw unsafePaths }
            guard let first = parts.first else { continue }
            if first == "__MACOSX" || parts.last == ".DS_Store" || entry.isSymlink || entry.isSpecial { continue }
            if !entry.isDirectory {
                guard !entry.isEncrypted else { throw ZipReader.encrypted }
                guard entry.method == ZipFormat.stored || entry.method == ZipFormat.deflated else { throw ZipReader.unsupportedMethod }
            }
            planned.append(PlannedEntry(entry: entry, components: parts, isDirectory: entry.isDirectory))
        }
        return planned
    }

    /// The entry's path as folder names, or nil if it could land outside the output folder (absolute, "..") or
    /// can't be a macOS name.
    static func safeComponents(_ name: String) -> [String]? {
        let unified = name.replacingOccurrences(of: "\\", with: "/")
        guard !unified.hasPrefix("/"), !unified.contains("\0") else { return nil }
        let parts = unified.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.contains(".."), parts.count <= 64, unified.utf8.count <= 1024,
              parts.allSatisfy({ $0.utf8.count <= 255 }) else { return nil }
        return parts
    }

    static let unsafePaths = ConversionError.engine("This zip has files that would land outside its folder, so Frenzy didn't open it.")

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
