import CoreGraphics
import Foundation

public struct LandfillItem: Equatable {
    public let url: URL
    public let addedAt: Date
    public let modifiedAt: Date
    public let lastAttended: Date
    public let expiresAt: Date
    /// 0 = fresh, 1 = due for the Trash.
    public let decay: Double
    /// Seconds until the item is trashed.
    public let remaining: TimeInterval
    /// Top-left of the cell in the zone; nil until placed.
    public var position: CGPoint?
    /// Which page of the zone the item lies on.
    public var page: Int

    public var name: String { url.lastPathComponent }
}

public struct SweepResult: Equatable {
    public var trashed: [URL] = []
}

public final class LandfillStore {
    enum Key {
        static let added = "com.landfill.added"
        static let opened = "com.landfill.opened"
        static let reprieve = "com.landfill.reprieve"
        static let position = "com.landfill.pos"
        static let lastUsed = "com.apple.lastuseddate#PS"
    }

    public let root: URL
    public var retention: TimeInterval
    /// Notice given when retention is shortened.
    public var reprieve: TimeInterval = 24 * 3600
    /// Cap on the walk that looks for activity inside a folder.
    public var folderWalkLimit = 5000

    private let fm = FileManager.default

    public init(root: URL, retention: TimeInterval = 7 * 24 * 3600) {
        self.root = root.resolvingSymlinksInPath()
        self.retention = retention
    }

    public func ensureRoot() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Putting things in

    @discardableResult
    public func adopt(_ source: URL, at position: CGPoint? = nil, page: Int = 0, copy: Bool = false,
                      now: Date = Date()) throws -> URL {
        try ensureRoot()
        let source = source.standardizedFileURL
        if source.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path {
            if let position { setPosition(position, page: page, for: source) }
            return source
        }
        let resolved = source.resolvingSymlinksInPath().path
        guard resolved != root.path, !root.path.hasPrefix(resolved + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let destination = uniqueURL(for: source.lastPathComponent)
        if copy {
            try fm.copyItem(at: source, to: destination)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
        stamp(destination, position: position, page: page, now: now)
        return destination
    }

    private func stamp(_ url: URL, position: CGPoint?, page: Int, now: Date) {
        XAttr.setDate(url, Key.added, now)
        XAttr.remove(url, Key.opened)
        XAttr.remove(url, Key.reprieve)
        if let position {
            setPosition(position, page: page, for: url)
        } else {
            XAttr.remove(url, Key.position)
        }
    }

    private func uniqueURL(for name: String) -> URL {
        var candidate = root.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) || (try? candidate.checkResourceIsReachable()) == true {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = root.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    // MARK: - Attention

    public func touch(_ url: URL, now: Date = Date()) {
        XAttr.setDate(url, Key.opened, now)
        XAttr.remove(url, Key.reprieve)
    }

    public func setPosition(_ position: CGPoint, page: Int = 0, for url: URL) {
        let text = "\(Int(position.x.rounded())),\(Int(position.y.rounded())),\(max(0, page))"
        XAttr.set(url, Key.position, Data(text.utf8))
    }

    public func rename(_ url: URL, to name: String) throws -> URL {
        let destination = root.appendingPathComponent(name)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
              !fm.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.moveItem(at: url, to: destination)
        return destination
    }

    // MARK: - Reading

    /// Oldest first. Unstamped files found in the folder are stamped here.
    public func items(now: Date = Date()) -> [LandfillItem] {
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        return urls.map { item(at: $0, now: now) }
            .sorted { ($0.addedAt, $0.name) < ($1.addedAt, $1.name) }
    }

    private func item(at url: URL, now: Date) -> LandfillItem {
        let added: Date
        if let stamped = XAttr.date(url, Key.added) {
            added = stamped
        } else {
            XAttr.setDate(url, Key.added, now)
            // read back so repeated listings agree exactly
            added = XAttr.date(url, Key.added) ?? now
        }
        let modified = modificationDate(of: url)
        // ignore dates in the future
        let horizon = now.addingTimeInterval(60)
        let attended = [added, modified, XAttr.date(url, Key.opened), lastUsedDate(of: url)]
            .compactMap { $0 }
            .filter { $0 <= horizon }
            .max() ?? added
        let natural = attended.addingTimeInterval(retention)
        let reprieveUntil = XAttr.date(url, Key.reprieve).flatMap { $0 > attended ? $0 : nil }
        let expires = max(natural, reprieveUntil ?? .distantPast)
        let age = now.timeIntervalSince(attended)
        let place = position(of: url)
        return LandfillItem(
            url: url,
            addedAt: added,
            modifiedAt: modified,
            lastAttended: attended,
            expiresAt: expires,
            decay: retention > 0 ? min(1, max(0, age / retention)) : 1,
            remaining: expires.timeIntervalSince(now),
            position: place?.point,
            page: place?.page ?? 0
        )
    }

    private func position(of url: URL) -> (point: CGPoint, page: Int)? {
        guard let parts = XAttr.string(url, Key.position)?.split(separator: ","), parts.count >= 2,
              let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return (CGPoint(x: x, y: y), parts.count > 2 ? max(0, Int(parts[2]) ?? 0) : 0)
    }

    private func rawModificationDate(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    private func modificationDate(of url: URL) -> Date {
        var latest = rawModificationDate(url.path) ?? .distantPast
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let walker = fm.enumerator(atPath: url.path) else { return latest }
        var seen = 0
        while seen < folderWalkLimit, let relative = walker.nextObject() as? String {
            seen += 1
            if let date = rawModificationDate(url.path + "/" + relative), date > latest {
                latest = date
            }
        }
        return latest
    }

    /// Set by Launch Services when a file is opened from Finder or `open`.
    private func lastUsedDate(of url: URL) -> Date? {
        guard let data = XAttr.get(url, Key.lastUsed), data.count >= 16 else { return nil }
        let (seconds, nanos) = data.withUnsafeBytes {
            ($0.loadUnaligned(fromByteOffset: 0, as: Int64.self),
             $0.loadUnaligned(fromByteOffset: 8, as: Int64.self))
        }
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1e9)
    }

    public func setRetention(_ newValue: TimeInterval, now: Date = Date()) {
        let shortening = newValue < retention
        retention = newValue
        guard shortening else { return }
        for item in items(now: now) where item.remaining < reprieve {
            XAttr.setDate(item.url, Key.reprieve, now.addingTimeInterval(reprieve))
        }
    }

    // MARK: - Decomposition

    /// Wall clock: files that expired while the Mac was off go at the next sweep.
    @discardableResult
    public func sweep(now: Date = Date(), trash: ((URL) throws -> Void)? = nil) -> SweepResult {
        let trash = trash ?? { [fm] in try fm.trashItem(at: $0, resultingItemURL: nil) }
        var result = SweepResult()
        for item in items(now: now) where item.remaining <= 0 {
            if (try? trash(item.url)) != nil { result.trashed.append(item.url) }
        }
        return result
    }
}
