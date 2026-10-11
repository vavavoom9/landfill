import Foundation

/// All per-file state lives in extended attributes.
enum XAttr {
    static func get(_ url: URL, _ name: String) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes {
                getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
            return read >= 0 ? data.prefix(read) : nil
        }
    }

    @discardableResult
    static func set(_ url: URL, _ name: String, _ data: Data) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return data.withUnsafeBytes {
                setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) == 0
            }
        }
    }

    static func remove(_ url: URL, _ name: String) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = removexattr(path, name, XATTR_NOFOLLOW)
        }
    }

    static func string(_ url: URL, _ name: String) -> String? {
        get(url, name).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func date(_ url: URL, _ name: String) -> Date? {
        string(url, name).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    static func setDate(_ url: URL, _ name: String, _ date: Date) {
        set(url, name, Data(String(date.timeIntervalSince1970).utf8))
    }
}
