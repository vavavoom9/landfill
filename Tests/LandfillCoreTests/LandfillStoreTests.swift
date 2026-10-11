import XCTest
@testable import LandfillCore

final class LandfillStoreTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!
    private var outside: URL!
    private var store: LandfillStore!
    private var trashed: [String] = []
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("landfill-tests-\(UUID().uuidString)")
        outside = base.appendingPathComponent("desktop")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        store = LandfillStore(root: base.appendingPathComponent("zone"))
        try store.ensureRoot()
        trashed = []
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: base)
    }

    private func makeFile(_ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? outside).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func sweep(at date: Date) -> SweepResult {
        store.sweep(now: date) { url in
            self.trashed.append(url.lastPathComponent)
            try self.fm.removeItem(at: url)
        }
    }

    private func run(from start: Date, to end: Date) {
        var t = start
        while t <= end {
            _ = sweep(at: t)
            t += hour
        }
    }

    func testAdoptMovesStampsAndAvoidsCollisions() throws {
        let t0 = Date()
        let first = try store.adopt(try makeFile("a.txt"), at: CGPoint(x: 40, y: 50), now: t0)
        let second = try store.adopt(try makeFile("a.txt"), now: t0)

        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("a.txt").path))
        XCTAssertEqual(first.lastPathComponent, "a.txt")
        XCTAssertEqual(second.lastPathComponent, "a 2.txt")
        let items = store.items(now: t0)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first { $0.name == "a.txt" }?.position, CGPoint(x: 40, y: 50))
        XCTAssertNil(items.first { $0.name == "a 2.txt" }?.position)

        store.setPosition(CGPoint(x: 12, y: 30), page: 2, for: second)
        let moved = store.items(now: t0).first { $0.name == "a 2.txt" }
        XCTAssertEqual(moved?.position, CGPoint(x: 12, y: 30))
        XCTAssertEqual(moved?.page, 2)
        XCTAssertEqual(items.first { $0.name == "a.txt" }?.page, 0)
        XCTAssertEqual(items[0].decay, 0, accuracy: 0.001)
    }

    func testCopyLeavesTheOriginal() throws {
        let source = try makeFile("keep.txt")
        try store.adopt(source, copy: true)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(store.items().map(\.name), ["keep.txt"])
    }

    func testUntouchedFileIsTrashedAfterSevenDays() throws {
        let t0 = Date()
        try store.adopt(try makeFile("a.txt"), now: t0)

        run(from: t0, to: t0 + 7 * day - hour)
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(store.items(now: t0 + 3.5 * day).first?.decay ?? 0, 0.5, accuracy: 0.01)

        run(from: t0 + 7 * day, to: t0 + 7 * day + hour)
        XCTAssertEqual(trashed, ["a.txt"])
        XCTAssertTrue(store.items(now: t0 + 8 * day).isEmpty)
    }

    func testOpeningThroughTheZoneRestartsTheClock() throws {
        let t0 = Date()
        let url = try store.adopt(try makeFile("a.txt"), now: t0)
        run(from: t0, to: t0 + 5 * day)
        store.touch(url, now: t0 + 5 * day)

        run(from: t0 + 5 * day, to: t0 + 12 * day - hour)
        XCTAssertEqual(trashed, [])
        run(from: t0 + 12 * day, to: t0 + 12 * day + hour)
        XCTAssertEqual(trashed, ["a.txt"])
    }

    func testSavingTheFileRestartsTheClock() throws {
        let t0 = Date()
        let url = try store.adopt(try makeFile("a.txt"), now: t0)
        try fm.setAttributes([.modificationDate: t0 + 5 * day], ofItemAtPath: url.path)

        run(from: t0 + 5 * day, to: t0 + 12 * day - hour)
        XCTAssertEqual(trashed, [])
    }

    func testOpeningFromFinderRestartsTheClock() throws {
        let t0 = Date()
        let url = try store.adopt(try makeFile("a.txt"), now: t0)
        var stamp = [Int64((t0 + 5 * day).timeIntervalSince1970), 0]
        XAttr.set(url, "com.apple.lastuseddate#PS", Data(bytes: &stamp, count: 16))

        run(from: t0 + 5 * day, to: t0 + 12 * day - hour)
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(store.items(now: t0 + 5 * day).first?.decay ?? 1, 0, accuracy: 0.01)
    }

    func testFolderIsKeptAliveByActivityInside() throws {
        let t0 = Date()
        let folder = outside.appendingPathComponent("project")
        try fm.createDirectory(at: folder.appendingPathComponent("deep"), withIntermediateDirectories: true)
        _ = try makeFile("notes.txt", in: folder.appendingPathComponent("deep"))
        let url = try store.adopt(folder, now: t0)
        try fm.setAttributes([.modificationDate: t0 + 6 * day],
                             ofItemAtPath: url.appendingPathComponent("deep/notes.txt").path)

        run(from: t0 + 6 * day, to: t0 + 13 * day - hour)
        XCTAssertEqual(trashed, [])
    }

    func testItemsExpiredWhileAwayGoAtTheFirstSweepBack() throws {
        let t0 = Date()
        try store.adopt(try makeFile("gone.txt"), now: t0)
        try store.adopt(try makeFile("kept.txt"), now: t0 + 5 * day)
        _ = sweep(at: t0 + 5 * day)

        let back = t0 + 10 * day
        XCTAssertEqual(sweep(at: back).trashed.map(\.lastPathComponent), ["gone.txt"])
        XCTAssertEqual(store.items(now: back).map(\.name), ["kept.txt"])
    }

    func testFilesSavedStraightIntoTheFolderStartTheirClock() throws {
        let t0 = Date()
        _ = try makeFile("stray.txt", in: store.root)
        XCTAssertEqual(store.items(now: t0).first?.addedAt, store.items(now: t0 + day).first?.addedAt)

        run(from: t0, to: t0 + 7 * day + hour)
        XCTAssertEqual(trashed, ["stray.txt"])
    }

    func testRefusesToSwallowItsOwnParent() throws {
        XCTAssertThrowsError(try store.adopt(base))
        XCTAssertThrowsError(try store.adopt(store.root))
        XCTAssertTrue(fm.fileExists(atPath: store.root.path))
    }

    func testShorteningRetentionGivesADaysNotice() throws {
        let t0 = Date()
        try store.adopt(try makeFile("a.txt"), now: t0)
        run(from: t0, to: t0 + 3 * day)

        let change = t0 + 3 * day
        store.setRetention(1 * day, now: change)
        run(from: change, to: change + day - hour)
        XCTAssertEqual(trashed, [])
        run(from: change + day, to: change + day + hour)
        XCTAssertEqual(trashed, ["a.txt"])
    }

    func testRenameKeepsTheClock() throws {
        let t0 = Date()
        let url = try store.adopt(try makeFile("a.txt"), now: t0)
        let renamed = try store.rename(url, to: "b.txt")
        XCTAssertEqual(store.items(now: t0 + day).map(\.name), ["b.txt"])
        XCTAssertEqual(store.items(now: t0 + day).first?.addedAt.timeIntervalSince1970 ?? 0,
                       t0.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertThrowsError(try store.rename(renamed, to: "b.txt"))
    }
}
