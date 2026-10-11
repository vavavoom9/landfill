import AppKit
import LandfillCore
import ServiceManagement

struct ZoneSpot: Equatable {
    var origin: CGPoint
    var page: Int
}

/// Sits just above the desktop icons, below app windows.
final class ZonePanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    /// Glass turns grey in windows AppKit considers inactive, and a desktop panel in a
    /// background app is always inactive. AppKit asks the window through this
    /// undocumented method; if a future system stops asking, the glass just goes grey.
    @objc(_hasActiveAppearance) private func hasActiveAppearance() -> Bool { true }
}

final class ZoneController: NSObject {
    let store: LandfillStore
    private let panel: ZonePanel
    private let view: ZoneView
    private var style = WidgetStyle.current()
    private let work = DispatchQueue(label: "landfill.work", qos: .utility)
    private let defaults = UserDefaults.standard
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var refreshQueued = false
    private lazy var settings = SettingsWindowController(controller: self)

    var retentionDays: Int { Int((store.retention / 86400).rounded()) }

    override init() {
        let path = ProcessInfo.processInfo.environment["LANDFILL_ROOT"]
            ?? defaults.string(forKey: "root")
            ?? "~/Landfill"
        let days = defaults.double(forKey: "retentionDays")
        store = LandfillStore(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                              retention: (days > 0 ? days : 7) * 86400)
        panel = ZonePanel(frame: ZoneController.initialFrame(defaults))
        let bounds = NSRect(origin: .zero, size: panel.frame.size)
        view = ZoneView(frame: bounds)
        super.init()
        view.controller = self
        view.autoresizingMask = [.width, .height]
        view.apply(style)
        panel.contentView = view
    }

    deinit {
        WidgetStyle.observedKeys.forEach { defaults.removeObserver(self, forKeyPath: $0) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let latest = WidgetStyle.current()
            guard latest != self.style else { return }
            self.style = latest
            self.view.apply(latest)
        }
    }

    func start() {
        try? store.ensureRoot()
        panel.orderFrontRegardless()
        view.updateVisibility(animated: false)
        watch()
        refresh(sweep: true)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        WidgetStyle.observedKeys.forEach { defaults.addObserver(self, forKeyPath: $0, options: [], context: nil) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() {
        let frame = panel.frame
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame.insetBy(dx: 40, dy: 40)) }) {
            resetFrame()
        }
    }

    @objc private func didWake() { refresh(sweep: true) }

    // MARK: - Keeping in step with the folder

    private func watch() {
        watcher?.cancel()
        let fd = Darwin.open(store.root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.intersection([.rename, .delete]).isEmpty {
                // folder was moved or removed: recreate and rewatch
                try? self.store.ensureRoot()
                self.watch()
            }
            self.refreshSoon()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Coalesces bursts of file events.
    func refreshSoon() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshQueued = false
            self?.refresh(sweep: false)
        }
    }

    private func refresh(sweep: Bool) {
        work.async { [weak self, store] in
            let now = Date()
            if sweep { store.sweep(now: now) }
            let items = store.items(now: now)
            DispatchQueue.main.async { [weak self] in
                self?.view.setItems(items)
                self?.schedule(nextExpiry: items.map(\.expiresAt).min())
            }
        }
    }

    /// Fires at the next expiry, or hourly to refresh decay stages.
    private func schedule(nextExpiry: Date?) {
        timer?.cancel()
        var delay: TimeInterval = 3600
        if let nextExpiry {
            delay = min(delay, max(2, nextExpiry.timeIntervalSinceNow + 1))
        }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: .now() + delay, leeway: .seconds(delay > 120 ? 60 : 1))
        source.setEventHandler { [weak self] in self?.refresh(sweep: true) }
        source.resume()
        timer = source
    }

    // MARK: - Actions from the zone

    private func perform(_ block: @escaping (LandfillStore) -> Void) {
        work.async { [weak self, store] in
            block(store)
            DispatchQueue.main.async { [weak self] in self?.refreshSoon() }
        }
    }

    func adopt(_ urls: [URL], at spots: [ZoneSpot], copy: Bool) {
        perform { store in
            for (url, spot) in zip(urls, spots) {
                do {
                    try store.adopt(url, at: spot.origin, page: spot.page, copy: copy)
                } catch {
                    NSLog("Landfill: could not take in %@: %@", url.path, "\(error)")
                }
            }
        }
    }

    func setPosition(_ spot: ZoneSpot, for url: URL) {
        work.async { [store] in store.setPosition(spot.origin, page: spot.page, for: url) }
    }

    func touch(_ urls: [URL]) {
        perform { store in urls.forEach { store.touch($0) } }
    }

    func trash(_ urls: [URL]) {
        perform { _ in
            for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
    }

    func rename(_ url: URL, to name: String) {
        perform { store in
            if (try? store.rename(url, to: name)) == nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    func open(_ urls: [URL]) {
        urls.forEach { NSWorkspace.shared.open($0) }
        touch(urls)
    }

    // MARK: - Settings

    func showSettings() { settings.show() }

    func setRetentionDays(_ days: Int) {
        defaults.set(Double(days), forKey: "retentionDays")
        work.async { [weak self, store] in
            store.setRetention(TimeInterval(days) * 86400)
            DispatchQueue.main.async { self?.refresh(sweep: false) }
        }
    }

    var pagesTurnSideways: Bool {
        get { defaults.string(forKey: "pageAxis") == "horizontal" }
        set {
            defaults.set(newValue ? "horizontal" : "vertical", forKey: "pageAxis")
            view.pageAxisChanged()
        }
    }

    var hidesUntilHover: Bool {
        get { defaults.object(forKey: "hideUntilHover") == nil ? true : defaults.bool(forKey: "hideUntilHover") }
        set {
            defaults.set(newValue, forKey: "hideUntilHover")
            view.updateVisibility()
        }
    }

    func revealFiles() {
        NSWorkspace.shared.activateFileViewerSelecting([store.root])
    }

    // MARK: - Zone frame

    func saveFrame(placedFreely: Bool) {
        defaults.set(NSStringFromRect(panel.frame), forKey: "zoneFrame")
        defaults.set(placedFreely, forKey: "zonePlacedFreely")
    }

    func resetFrame() {
        defaults.removeObject(forKey: "zoneFrame")
        defaults.removeObject(forKey: "zonePlacedFreely")
        panel.setFrame(Self.initialFrame(defaults), display: true)
    }

    private static func initialFrame(_ defaults: UserDefaults) -> NSRect {
        if let saved = defaults.string(forKey: "zoneFrame") {
            let frame = NSRectFromString(saved)
            if frame.width >= 100, let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
                // back on the grid unless placed with Shift
                return defaults.bool(forKey: "zonePlacedFreely") ? frame : WidgetGrid.current().snap(frame, on: screen)
            }
        }
        let grid = WidgetGrid.current()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = grid.size(columns: 3, rows: 2)
        let rough = NSRect(x: screen.maxX - size.width - 150, y: screen.minY + 60,
                           width: size.width, height: size.height)
        return grid.snap(rough, on: NSScreen.main)
    }

    // MARK: - Login item

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func toggleLaunchAtLogin() {
        do {
            if launchesAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Landfill: login item change failed: %@", "\(error)")
            NSSound.beep()
        }
    }
}
