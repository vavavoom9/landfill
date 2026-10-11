import AppKit
import LandfillCore
import Quartz

struct Metrics {
    var icon: CGFloat = 64
    var text: CGFloat = 12

    var cellWidth: CGFloat { max(icon + 44, 104) }
    var labelHeight: CGFloat { ceil((text + 3) * 2) + 2 }
    var cellHeight: CGFloat { icon + 6 + labelHeight }

    static func fromFinder() -> Metrics {
        var metrics = Metrics()
        let desktop = UserDefaults(suiteName: "com.apple.finder")?.dictionary(forKey: "DesktopViewSettings")
        if let settings = desktop?["IconViewSettings"] as? [String: Any] {
            if let size = (settings["iconSize"] as? NSNumber)?.doubleValue, size >= 16, size <= 256 {
                metrics.icon = size
            }
            if let size = (settings["textSize"] as? NSNumber)?.doubleValue, size >= 9, size <= 24 {
                metrics.text = size
            }
        }
        return metrics
    }
}

final class ZoneView: NSView, NSDraggingSource, NSTextFieldDelegate, NSMenuDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private struct Cell {
        var item: LandfillItem
        var origin: CGPoint
        var page: Int
        var spot: ZoneSpot { ZoneSpot(origin: origin, page: page) }
    }

    private enum Drag {
        case none
        case item(start: CGPoint, index: Int)
        case band(start: CGPoint)
        case moveZone(mouse: NSPoint, frame: NSRect)
        /// Control is down: a drag moves the zone, a plain click still opens the menu.
        case controlPress(mouse: NSPoint, frame: NSRect)
        case resizeZone(mouse: NSPoint, frame: NSRect)
    }

    weak var controller: ZoneController?

    private let metrics = Metrics.fromFinder()
    private let icons = IconRenderer()
    private var cells: [Cell] = []
    private var selection = Set<String>()
    private var drag = Drag.none
    private var band: CGRect?
    private var dropHighlighted = false
    private var dragStart = CGPoint.zero
    private var draggedURLs: [URL] = []
    /// Position for the next promised-file drop.
    private var strayHint: ZoneSpot?
    private var renameField: NSTextField?
    private var renamingURL: URL?
    private let promiseQueue = OperationQueue()
    private var redrawQueued = false
    private var zoneGrid = WidgetGrid()
    private var zonePlacedFreely = false

    private var currentPage = 0
    private let stage = NSView()
    private let well = CALayer()
    private let overlay = OverlayView()
    private var pageViews: [Int: PageView] = [:]
    private var style = WidgetStyle.current()
    private var tracking = false
    private var settling: Int?
    private var turnGeneration = 0
    private var progress: CGFloat = 0
    private var lastStep: CGFloat = 0

    private let ghost = CAShapeLayer()
    private var hovering = false
    private var gripHint = false
    private var gripHintGeneration = 0
    private var menuOpen = false
    private var revealed = true
    private var hideGeneration = 0
    private var dragActive = false
    private var edgeHover: (direction: Int, since: CFTimeInterval)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let promised = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL] + promised)
        icons.onUpdate = { [weak self] in self?.redrawSoon() }
        wantsLayer = true
        stage.frame = bounds
        stage.autoresizingMask = [.width, .height]
        stage.wantsLayer = true
        addSubview(stage)
        overlay.zone = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        showOnlyCurrentPage()
        ghost.fillColor = nil
        ghost.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        ghost.lineWidth = 1.5
        ghost.lineDashPattern = [7, 5]
        ghost.shadowColor = NSColor.black.cgColor
        ghost.shadowOpacity = 0.45
        ghost.shadowRadius = 1.5
        ghost.shadowOffset = .zero
        ghost.opacity = 0
        ghost.zPosition = -2
        layer?.addSublayer(ghost)
        updateVisibility(animated: false)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Model

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateStage()
        if anyPageOverfull { cleanUp(by: .position) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateStage()
    }

    /// Pages and overlay only draw; the zone takes the events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let field = renameField, hit === field || hit.isDescendant(of: field) { return hit }
        return self
    }

    func apply(_ style: WidgetStyle) {
        self.style = style
        appearance = style.appearance.flatMap { NSAppearance(named: $0) }
        pageViews.values.forEach { $0.apply(style) }
        redraw()
    }

    func pageAxisChanged() {
        redraw()
    }

    // MARK: - Hiding until hovered

    private var shouldBeRevealed: Bool {
        guard controller?.hidesUntilHover ?? true else { return true }
        return hovering || dragActive || tracking || settling != nil || menuOpen || renameField != nil
    }

    func updateVisibility(animated: Bool = true) {
        let show = shouldBeRevealed
        hideGeneration += 1
        guard show != revealed else { return }
        if show {
            setRevealed(true, animated: animated)
        } else if !animated {
            setRevealed(false, animated: false)
        } else {
            // short delay so brushing the edge doesn't flicker
            let generation = hideGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.hideGeneration == generation, !self.shouldBeRevealed else { return }
                self.setRevealed(false, animated: true)
            }
        }
    }

    private func setRevealed(_ show: Bool, animated: Bool) {
        revealed = show
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? (show ? 0.18 : 0.4) : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stage.animator().alphaValue = show ? 1 : 0
            overlay.animator().alphaValue = show ? 1 : 0
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? (show ? 0.18 : 0.4) : 0)
        ghost.opacity = show ? 0 : 1
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        setGripHint(false)
        updateVisibility()
    }

    override func mouseMoved(with event: NSEvent) {
        setGripHint(gripRect.contains(convert(event.locationInWindow, from: nil)))
    }

    /// Resting on the resize corner shows what the modifier keys do.
    private func setGripHint(_ wanted: Bool) {
        gripHintGeneration += 1
        guard wanted != gripHint else { return }
        if !wanted {
            gripHint = false
            overlay.needsDisplay = true
            return
        }
        let generation = gripHintGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.gripHintGeneration == generation else { return }
            self.gripHint = true
            self.overlay.needsDisplay = true
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        updateVisibility()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        refreshHover()
    }

    private func refreshHover() {
        if let window {
            hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        updateVisibility()
    }

    private func redraw() {
        pageViews.values.forEach { $0.content.needsDisplay = true }
        overlay.needsDisplay = true
    }

    func setItems(_ items: [LandfillItem]) {
        var placed: [Cell] = []
        for item in items {
            if let origin = item.position {
                placed.append(Cell(item: item, origin: origin, page: item.page))
            } else {
                let spot = strayHint ?? freeSpot(avoiding: placed)
                strayHint = nil
                controller?.setPosition(spot, for: item.url)
                placed.append(Cell(item: item, origin: spot.origin, page: spot.page))
            }
        }
        let before = cells.map { "\($0.item.url.path)|\(IconRenderer.stage(of: $0.item))" }
        let after = placed.map { "\($0.item.url.path)|\(IconRenderer.stage(of: $0.item))" }
        if before != after, !before.isEmpty { crossFade() }
        cells = placed
        let paths = Set(items.map(\.url.path))
        selection.formIntersection(paths)
        icons.keepOnly(paths)
        if !dragActive { closePageGaps() }
        if anyPageOverfull { cleanUp(by: .position) }
        showOnlyCurrentPage()
        redraw()
    }

    private func redrawSoon() {
        guard !redrawQueued else { return }
        redrawQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.redrawQueued = false
            self?.redraw()
        }
    }

    private var selectedCells: [Cell] { cells.filter { selection.contains($0.item.url.path) } }
    private var selectedURLs: [URL] { selectedCells.map(\.item.url) }

    // MARK: - Geometry

    private let edge = WidgetGrid.tileInset

    /// Stored positions are kept as dropped and clamped only for display.
    private func shown(_ origin: CGPoint) -> CGPoint {
        let pad = edge + 6
        return CGPoint(x: min(max(pad, origin.x), max(pad, bounds.width - metrics.cellWidth - pad)),
                       y: min(max(pad, origin.y), max(pad, bounds.height - metrics.cellHeight - pad)))
    }

    private func iconRect(_ cell: Cell) -> CGRect {
        let o = shown(cell.origin)
        return CGRect(x: o.x + (metrics.cellWidth - metrics.icon) / 2, y: o.y,
                      width: metrics.icon, height: metrics.icon)
    }

    private func labelRect(_ cell: Cell) -> CGRect {
        let o = shown(cell.origin)
        return CGRect(x: o.x, y: o.y + metrics.icon + 6, width: metrics.cellWidth, height: metrics.labelHeight)
    }

    private var gripRect: CGRect { CGRect(x: bounds.maxX - edge - 24, y: bounds.maxY - edge - 24, width: 24 + edge, height: 24 + edge) }

    private func cellIndex(at point: CGPoint) -> Int? {
        cells.indices.reversed().first {
            cells[$0].page == currentPage
                && (iconRect(cells[$0]).insetBy(dx: -4, dy: -4).contains(point) || labelRect(cells[$0]).contains(point))
        }
    }

    // MARK: - Grid

    private var gridStart: CGFloat { edge + 10 }
    private var gridStep: CGSize { CGSize(width: metrics.cellWidth, height: metrics.cellHeight + 6) }
    private var gridColumns: Int {
        max(1, Int((bounds.width - 2 * gridStart - metrics.cellWidth) / gridStep.width) + 1)
    }
    private var gridRows: Int {
        max(1, Int((bounds.height - 2 * gridStart - metrics.cellHeight) / gridStep.height) + 1)
    }
    private var pageCapacity: Int { gridColumns * gridRows }

    private func slot(_ index: Int) -> CGPoint {
        let spare = max(0, bounds.width - 2 * gridStart - CGFloat(gridColumns) * metrics.cellWidth)
        return CGPoint(x: gridStart + spare / 2 + CGFloat(index % gridColumns) * gridStep.width,
                       y: gridStart + CGFloat(index / gridColumns) * gridStep.height)
    }

    private func freeSlots(on page: Int, avoiding placed: [Cell]) -> [CGPoint] {
        let size = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)
        let taken = placed.filter { $0.page == page }.map { CGRect(origin: shown($0.origin), size: size).insetBy(dx: 6, dy: 6) }
        return (0..<pageCapacity).map { slot($0) }.filter { origin in
            let candidate = CGRect(origin: origin, size: size)
            return !taken.contains { $0.intersects(candidate) }
        }
    }

    private func freeSpot(avoiding placed: [Cell]) -> ZoneSpot {
        let last = placed.map(\.page).max() ?? 0
        for page in [currentPage] + Array(0...last + 1) {
            if let origin = freeSlots(on: page, avoiding: placed).first { return ZoneSpot(origin: origin, page: page) }
        }
        return ZoneSpot(origin: slot(0), page: last + 1)
    }

    // MARK: - Pages

    private var sideways: Bool { controller?.pagesTurnSideways ?? false }

    private var pageCount: Int {
        max((cells.map(\.page).max() ?? 0) + 1, currentPage + 1)
    }

    private var anyPageOverfull: Bool {
        Dictionary(grouping: cells, by: \.page).values.contains { $0.count > pageCapacity }
    }

    /// Removes emptied pages.
    private func closePageGaps() {
        let used = Set(cells.map(\.page)).sorted()
        if used != Array(0..<used.count) {
            let renumbered = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
            for index in cells.indices {
                let page = renumbered[cells[index].page] ?? 0
                if page != cells[index].page {
                    cells[index].page = page
                    controller?.setPosition(cells[index].spot, for: cells[index].item.url)
                }
            }
            currentPage = renumbered[currentPage] ?? currentPage
        }
        currentPage = min(currentPage, max(0, used.count - 1))
    }

    private var lastPage: Int { cells.map(\.page).max() ?? 0 }
    private var turnLength: CGFloat { sideways ? bounds.width : bounds.height }

    private func pageView(_ index: Int) -> PageView {
        if let view = pageViews[index] { return view }
        let view = PageView(frame: stage.bounds, page: index, zone: self, style: style)
        stage.addSubview(view)
        pageViews[index] = view
        return view
    }

    private func showOnlyCurrentPage() {
        guard !tracking, settling == nil else { return }
        let keep = pageViews[currentPage] ?? pageViews.values.first
        for (index, view) in pageViews where view !== keep {
            view.removeFromSuperview()
            pageViews[index] = nil
        }
        pageViews.removeAll()
        let view = keep ?? PageView(frame: stage.bounds, page: currentPage, zone: self, style: style)
        if view.superview == nil { stage.addSubview(view) }
        view.content.page = currentPage
        view.layer?.removeAllAnimations()
        view.layer?.sublayerTransform = CATransform3DIdentity
        view.frame = stage.bounds
        pageViews[currentPage] = view
    }

    private func updateStage() {
        guard let layer = stage.layer else { return }
        let tile = stage.bounds.insetBy(dx: edge, dy: edge)
        let radius = min(ZoneBackgroundView.cornerRadius, min(tile.width, tile.height) / 2)
        if well.superlayer == nil {
            well.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            well.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            well.borderWidth = 1
            well.cornerCurve = .continuous
            well.opacity = 0
            well.zPosition = -1
            layer.addSublayer(well)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        well.frame = tile
        well.cornerRadius = radius
        let outline = bounds.insetBy(dx: edge + 5, dy: edge + 5)
        let outlineRadius = max(0, min(ZoneBackgroundView.cornerRadius - 5, min(outline.width, outline.height) / 2))
        ghost.frame = bounds
        ghost.path = CGPath(roundedRect: outline, cornerWidth: outlineRadius, cornerHeight: outlineRadius, transform: nil)
        if layer.mask != nil { clipStage(true) }
        CATransaction.commit()
    }

    private func clipStage(_ on: Bool) {
        guard let layer = stage.layer else { return }
        guard on else { layer.mask = nil; return }
        let tile = stage.bounds.insetBy(dx: edge, dy: edge)
        let radius = min(ZoneBackgroundView.cornerRadius, min(tile.width, tile.height) / 2)
        let mask = CAShapeLayer()
        mask.path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
        layer.mask = mask
    }

    /// progress: 0 at rest, 1 or -1 when the neighbouring page has arrived.
    private func origin(for index: Int, progress: CGFloat) -> CGPoint {
        let offset = (CGFloat(index - currentPage) - progress) * turnLength
        // stage y runs upward, so the next page comes from below
        return sideways ? CGPoint(x: offset, y: 0) : CGPoint(x: 0, y: -offset)
    }

    /// Scale applied to a page's contents, about its centre.
    private func shrink(_ engaged: CGFloat) -> CATransform3D {
        let scale = 1 - 0.084 * engaged
        let centre = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -centre.x, y: -centre.y)
        return CATransform3DMakeAffineTransform(transform)
    }

    private enum Pop {
        static let inDuration: CFTimeInterval = 0.38
        static let inCurve = CAMediaTimingFunction(controlPoints: 0.16, 0.9, 0.3, 1)
        static let outDuration: CFTimeInterval = 0.62
        static let outCurve = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.2, 1)
    }

    private func place(progress: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, view) in pageViews {
            view.setFrameOrigin(origin(for: index, progress: progress))
        }
        CATransaction.commit()
        overlay.needsDisplay = true
    }

    private func beginTurn(allowingNewPage: Bool = false, popIn: Bool = true) {
        finishRename(commit: true)
        clipStage(true)
        let limit = lastPage + (allowingNewPage ? 1 : 0)
        for index in [currentPage - 1, currentPage + 1] where index >= 0 && index <= limit {
            _ = pageView(index)
        }
        guard popIn else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in pageViews.values {
            guard let layer = view.layer else { continue }
            let pop = CABasicAnimation(keyPath: "sublayerTransform")
            pop.fromValue = NSValue(caTransform3D: layer.presentation()?.sublayerTransform ?? layer.sublayerTransform)
            pop.toValue = NSValue(caTransform3D: shrink(1))
            pop.duration = Pop.inDuration
            pop.timingFunction = Pop.inCurve
            layer.add(pop, forKey: "pop")
            layer.sublayerTransform = shrink(1)
        }
        let rise = CABasicAnimation(keyPath: "opacity")
        rise.fromValue = well.presentation()?.opacity ?? well.opacity
        rise.toValue = 1
        rise.duration = Pop.inDuration
        rise.timingFunction = Pop.inCurve
        well.add(rise, forKey: "pop")
        well.opacity = 1
        CATransaction.commit()
    }

    private func settle(towards direction: Int, pulse: Bool = false) {
        tracking = false
        let target = pageViews[currentPage + direction] != nil ? direction : 0
        settling = target
        turnGeneration += 1
        let generation = turnGeneration
        let duration = Pop.outDuration
        let glide = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = pulse ? duration : duration * 0.75
            context.timingFunction = pulse ? CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1) : glide
            context.allowsImplicitAnimation = true
            for (index, view) in pageViews {
                view.animator().setFrameOrigin(origin(for: index, progress: CGFloat(target)))
                guard let layer = view.layer else { continue }
                let pop = CAKeyframeAnimation(keyPath: "sublayerTransform")
                let now = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
                if pulse {
                    pop.values = [CATransform3DIdentity, shrink(1), shrink(1), CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
                    pop.keyTimes = [0, 0.3, 0.55, 1]
                    pop.timingFunctions = [Pop.inCurve, CAMediaTimingFunction(name: .linear), Pop.outCurve]
                } else {
                    pop.values = [now, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
                    pop.keyTimes = [0, 1]
                    pop.timingFunctions = [Pop.outCurve]
                }
                pop.duration = duration
                layer.add(pop, forKey: "pop")
                layer.sublayerTransform = CATransform3DIdentity
            }
            let shown = well.presentation()?.opacity ?? well.opacity
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = pulse ? [0, 1, 1, 0] : [shown, 0]
            fade.keyTimes = pulse ? [0, 0.3, 0.55, 1] : [0, 1]
            fade.timingFunctions = pulse ? [Pop.inCurve, CAMediaTimingFunction(name: .linear), Pop.outCurve] : [Pop.outCurve]
            fade.duration = duration
            well.add(fade, forKey: "pop")
            well.opacity = 0
        }, completionHandler: {})
        // the pop outlasts the glide
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            guard let self, self.turnGeneration == generation else { return }
            self.finishTurn()
        }
        overlay.needsDisplay = true
    }

    private func finishTurn() {
        guard let direction = settling else { return }
        settling = nil
        progress = 0
        currentPage += direction
        if direction != 0, !dragActive { selection = [] }
        well.removeAllAnimations()
        well.opacity = 0
        clipStage(false)
        if !dragActive { closePageGaps() }
        showOnlyCurrentPage()
        redraw()
        refreshHover()
    }

    private func turnPage(by direction: Int, allowingNewPage: Bool = false) {
        guard !tracking, settling == nil, direction != 0 else { return }
        let target = currentPage + (direction > 0 ? 1 : -1)
        guard target >= 0, target <= lastPage + (allowingNewPage ? 1 : 0) else { return }
        beginTurn(allowingNewPage: allowingNewPage, popIn: false)
        place(progress: 0)
        settle(towards: direction > 0 ? 1 : -1, pulse: true)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else {
            // mouse wheel: one notch, one page
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            if delta != 0 { turnPage(by: delta < 0 ? 1 : -1) }
            return
        }
        // ignore momentum; release settles the page
        guard event.momentumPhase.isEmpty else { return }

        if event.phase.contains(.began) {
            if settling != nil { finishTurn() }
            guard lastPage > 0 else { return }
            tracking = true
            progress = 0
            lastStep = 0
            beginTurn()
        }
        guard tracking else { return }
        if event.phase.contains(.changed) || event.phase.contains(.began) {
            var step = -(sideways ? event.scrollingDeltaX : event.scrollingDeltaY) / max(1, turnLength)
            // resist past the first or last page
            let towards = progress + step
            if (towards > 0 && currentPage >= lastPage) || (towards < 0 && currentPage == 0) { step *= 0.25 }
            progress = min(1, max(-1, progress + step))
            lastStep = step
            place(progress: progress)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let flicked = abs(lastStep) > 0.012 && lastStep * progress > 0
            let direction = abs(progress) > 0.3 || (abs(progress) > 0.04 && flicked) ? (progress > 0 ? 1 : -1) : 0
            settle(towards: direction)
        }
    }

    fileprivate var pageDots: [CGRect] {
        let count = pageCount
        guard count > 1 else { return [] }
        let pitch: CGFloat = 10, size: CGFloat = 5
        let run = CGFloat(count - 1) * pitch
        return (0..<count).map { n in
            sideways
                ? CGRect(x: bounds.midX - run / 2 + CGFloat(n) * pitch - size / 2, y: bounds.maxY - size - 1, width: size, height: size)
                : CGRect(x: bounds.maxX - size - 1, y: bounds.midY - run / 2 + CGFloat(n) * pitch - size / 2, width: size, height: size)
        }
    }

    fileprivate func drawOverlay() {
        let active = currentPage + (tracking ? Int(progress.rounded()) : settling ?? 0)
        for (page, dot) in pageDots.enumerated() {
            NSColor.white.withAlphaComponent(page == active ? 0.95 : 0.4).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        if let band {
            ink.withAlphaComponent(0.15).setFill()
            ink.withAlphaComponent(0.6).setStroke()
            let path = NSBezierPath(rect: band)
            path.fill()
            path.stroke()
        }
        if gripHint { drawGripHint() }
    }

    private func drawGripHint() {
        let rows = [("Drag", "resize on the widget grid"),
                    ("Shift", "resize freely"),
                    ("Control", "move the zone"),
                    ("Control Shift", "move freely")]
        let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textFont = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString()
        for (n, row) in rows.enumerated() {
            text.append(NSAttributedString(string: row.0, attributes: [.font: keyFont, .foregroundColor: NSColor.white]))
            text.append(NSAttributedString(string: "  " + row.1 + (n < rows.count - 1 ? "\n" : ""),
                                           attributes: [.font: textFont, .foregroundColor: NSColor.white.withAlphaComponent(0.75)]))
        }
        let room = CGSize(width: max(60, bounds.width - 2 * edge - 28), height: bounds.height)
        let size = text.boundingRect(with: room, options: [.usesLineFragmentOrigin]).size
        let box = CGRect(x: bounds.maxX - edge - 14 - ceil(size.width) - 16,
                         y: bounds.maxY - edge - 30 - ceil(size.height) - 12,
                         width: ceil(size.width) + 16, height: ceil(size.height) + 12)
        NSColor(white: 0.12, alpha: 0.95).setFill()
        NSColor(white: 1, alpha: 0.18).setStroke()
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        path.fill()
        path.stroke()
        text.draw(with: box.insetBy(dx: 8, dy: 6), options: [.usesLineFragmentOrigin])
    }

    // MARK: - Clean Up

    private enum CleanUpOrder: Int {
        case position, name, dateAdded, timeLeft
    }

    private func cleanUp(by order: CleanUpOrder) {
        var sorted = cells
        switch order {
        case .position:
            sorted.sort { a, b in
                if a.page != b.page { return a.page < b.page }
                let pa = shown(a.origin), pb = shown(b.origin)
                let ra = (pa.y / gridStep.height).rounded(), rb = (pb.y / gridStep.height).rounded()
                if ra != rb { return ra < rb }
                if pa.x != pb.x { return pa.x < pb.x }
                return a.item.addedAt < b.item.addedAt
            }
        case .name:
            sorted.sort { $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending }
        case .dateAdded:
            // newest first
            sorted.sort { $0.item.addedAt > $1.item.addedAt }
        case .timeLeft:
            sorted.sort { $0.item.remaining < $1.item.remaining }
        }
        crossFade()
        let capacity = pageCapacity
        for (n, cell) in sorted.enumerated() {
            guard let index = cells.firstIndex(where: { $0.item.url == cell.item.url }) else { continue }
            let spot = ZoneSpot(origin: slot(n % capacity), page: n / capacity)
            if cells[index].spot != spot {
                cells[index].origin = spot.origin
                cells[index].page = spot.page
                controller?.setPosition(spot, for: cell.item.url)
            }
        }
        currentPage = min(currentPage, max(0, (sorted.count - 1) / capacity))
        showOnlyCurrentPage()
        redraw()
    }

    private func crossFade() {
        guard let layer = pageViews[currentPage]?.content.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.35
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "contents")
    }

    // MARK: - Drawing

    private var onDarkTile: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var ink: NSColor { onDarkTile ? .white : .black }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: metrics.text, weight: .medium),
                .foregroundColor: ink.withAlphaComponent(0.92), .paragraphStyle: style]
    }

    override func viewDidChangeEffectiveAppearance() {
        redraw()
    }

    fileprivate func drawContents(ofPage page: Int) {
        let dropHighlighted = dropHighlighted && page == currentPage
        let inset = edge + 5
        let radius = ZoneBackgroundView.cornerRadius - 5
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
        if dropHighlighted {
            ink.withAlphaComponent(0.1).setFill()
            outline.fill()
        }
        outline.setLineDash([7, 5], count: 2, phase: 0)
        outline.lineWidth = dropHighlighted ? 2.5 : 1.5
        ink.withAlphaComponent(dropHighlighted ? 0.9 : 0.3).setStroke()
        outline.stroke()

        let grip = NSBezierPath()
        for offset in [7.0, 12.0] {
            grip.move(to: NSPoint(x: bounds.maxX - edge - offset - 13, y: bounds.maxY - edge - 13))
            grip.line(to: NSPoint(x: bounds.maxX - edge - 13, y: bounds.maxY - edge - offset - 13))
        }
        grip.lineWidth = 1.5
        grip.lineCapStyle = .round
        ink.withAlphaComponent(0.4).setStroke()
        grip.stroke()

        if cells.isEmpty { drawHint() }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds.insetBy(dx: inset + 2, dy: inset + 2), xRadius: radius - 2, yRadius: radius - 2).addClip()
        for cell in cells where cell.page == page { draw(cell) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHint() {
        var attributes = labelAttributes
        attributes[.foregroundColor] = ink.withAlphaComponent(0.6)
        let days = controller?.retentionDays ?? 7
        let text = "Drop files here.\nLeft untouched for \(days) days, they go to the Trash." as NSString
        let size = text.boundingRect(with: bounds.insetBy(dx: 24, dy: 24).size,
                                     options: [.usesLineFragmentOrigin], attributes: attributes).size
        text.draw(with: CGRect(x: 24, y: bounds.midY - size.height / 2, width: bounds.width - 48, height: size.height + 2),
                  options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    private func draw(_ cell: Cell) {
        let icon = iconRect(cell), label = labelRect(cell)
        let selected = selection.contains(cell.item.url.path)
        let name = cell.item.name as NSString
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]

        if selected {
            ink.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: icon.insetBy(dx: -5, dy: -5), xRadius: 8, yRadius: 8).fill()
            let used = name.boundingRect(with: label.size, options: options, attributes: labelAttributes).size
            let pill = CGRect(x: label.midX - used.width / 2 - 5, y: label.minY - 1,
                              width: used.width + 10, height: min(label.height, used.height) + 2)
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        }

        let scale = window?.backingScaleFactor ?? 2
        icons.image(for: cell.item, points: metrics.icon, scale: scale)
            .draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        var attributes = labelAttributes
        attributes[.foregroundColor] = selected ? NSColor.white : ink.withAlphaComponent(0.92 - 0.3 * cell.item.decay)
        name.draw(with: label, options: options, attributes: attributes)
        drawCountdown(for: cell.item, over: icon)
    }

    private func drawCountdown(for item: LandfillItem, over icon: CGRect) {
        guard item.remaining < 3 * 86400 else { return }
        let lastDay = item.remaining < 86400
        let text = (lastDay ? "\(max(1, Int(ceil(item.remaining / 3600))))h"
                            : "\(Int(ceil(item.remaining / 86400)))d") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(x: icon.maxX - size.width - 6, y: icon.minY - 4, width: size.width + 10, height: size.height + 3)
        (lastDay ? NSColor.systemRed : onDarkTile ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.45, alpha: 1)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 5, y: pill.minY + 1), withAttributes: attributes)
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateVisibility()
        // saves in other apps don't change the folder listing
        controller?.refreshSoon()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let extending = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        setGripHint(false)

        if event.modifierFlags.contains(.control), let frame = window?.frame {
            zoneGrid = .current()
            drag = .controlPress(mouse: NSEvent.mouseLocation, frame: frame)
        } else if let dot = pageDots.firstIndex(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
            if dot != currentPage { turnPage(by: dot - currentPage) }
        } else if let index = cellIndex(at: point) {
            let path = cells[index].item.url.path
            if extending {
                if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
            } else if !selection.contains(path) {
                selection = [path]
            }
            if event.clickCount == 2 {
                controller?.open(selectedURLs)
            } else {
                drag = .item(start: point, index: index)
            }
        } else if gripRect.contains(point), let frame = window?.frame {
            zoneGrid = .current()
            drag = .resizeZone(mouse: NSEvent.mouseLocation, frame: frame)
        } else if !bounds.insetBy(dx: edge + 12, dy: edge + 12).contains(point), let frame = window?.frame {
            zoneGrid = .current()
            drag = .moveZone(mouse: NSEvent.mouseLocation, frame: frame)
        } else {
            if !extending { selection = [] }
            drag = .band(start: point)
        }
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            break
        case let .item(start, index):
            guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
            drag = .none
            beginItemDrag(from: start, index: index, event: event)
        case let .band(start):
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            band = rect
            selection = Set(cells.filter { $0.page == currentPage && (iconRect($0).intersects(rect) || labelRect($0).intersects(rect)) }
                .map(\.item.url.path))
            redraw()
        case let .controlPress(mouse, frame):
            let now = NSEvent.mouseLocation
            guard hypot(now.x - mouse.x, now.y - mouse.y) > 4 else { return }
            drag = .moveZone(mouse: mouse, frame: frame)
            placeZone(frame.offsetBy(dx: now.x - mouse.x, dy: now.y - mouse.y), free: event.modifierFlags.contains(.shift))
        case let .moveZone(mouse, frame):
            let now = NSEvent.mouseLocation
            placeZone(frame.offsetBy(dx: now.x - mouse.x, dy: now.y - mouse.y), free: event.modifierFlags.contains(.shift))
        case let .resizeZone(mouse, frame):
            let now = NSEvent.mouseLocation
            let width = max(120, frame.width + now.x - mouse.x)
            let height = max(120, frame.height - (now.y - mouse.y))
            placeZone(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height),
                      free: event.modifierFlags.contains(.shift))
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case let .item(_, index):
            // plain click on a multi-selection narrows it
            if event.modifierFlags.intersection([.command, .shift]).isEmpty, cells.indices.contains(index) {
                selection = [cells[index].item.url.path]
            }
        case .controlPress:
            // Control-click without a drag is the usual secondary click.
            drag = .none
            NSMenu.popUpContextMenu(contextMenu(at: convert(event.locationInWindow, from: nil)), with: event, for: self)
        case .moveZone, .resizeZone:
            controller?.saveFrame(placedFreely: zonePlacedFreely)
        case .band, .none:
            break
        }
        drag = .none
        band = nil
        redraw()
    }

    private func placeZone(_ frame: NSRect, free: Bool) {
        guard let window else { return }
        zonePlacedFreely = free
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? window.screen
        let target = free ? frame : zoneGrid.snap(frame, on: screen)
        if target != window.frame { window.setFrame(target, display: true) }
    }

    // MARK: - Dragging out and around

    private func beginItemDrag(from start: CGPoint, index: Int, event: NSEvent) {
        guard cells.indices.contains(index) else { return }
        let scale = window?.backingScaleFactor ?? 2
        dragStart = start
        draggedURLs = selectedURLs
        let items = selectedCells.map { cell -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: cell.item.url as NSURL)
            item.setDraggingFrame(iconRect(cell), contents: icons.image(for: cell.item, points: metrics.icon, scale: scale))
            return item
        }
        guard !items.isEmpty else { return }
        dragActive = true
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : [.move, .copy, .delete]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .delete { controller?.trash(draggedURLs) }
        draggedURLs = []
        endDrag()
        controller?.refreshSoon()
    }

    private func endDrag() {
        dragActive = false
        edgeHover = nil
        dropHighlighted = false
        closePageGaps()
        showOnlyCurrentPage()
        redraw()
        refreshHover()
    }

    // MARK: - Dropping in

    private func isOwnDrag(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as AnyObject?) === self
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        if isOwnDrag(sender) { return .move }
        return sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragActive = true
        updateVisibility()
        if !isOwnDrag(sender) {
            dropHighlighted = true
            redraw()
        }
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let along = sideways ? point.x : point.y
        let length = sideways ? bounds.width : bounds.height
        let direction = along > length - 34 ? 1 : along < 34 ? -1 : 0
        let now = CACurrentMediaTime()
        if direction == 0 {
            edgeHover = nil
        } else if edgeHover?.direction != direction {
            edgeHover = (direction, now)
        } else if let hover = edgeHover, now - hover.since > 0.7 {
            turnPage(by: direction, allowingNewPage: true)
            edgeHover = (direction, now + 0.4)
        }
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // own drags are still running when they leave; the session end cleans up
        if let sender, isOwnDrag(sender) {
            edgeHover = nil
        } else {
            endDrag()
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        if !isOwnDrag(sender) { endDrag() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        redraw()
        let point = convert(sender.draggingLocation, from: nil)

        if isOwnDrag(sender) {
            let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
            for index in cells.indices where selection.contains(cells[index].item.url.path) {
                let from = shown(cells[index].origin)
                cells[index].origin = shown(CGPoint(x: from.x + delta.x, y: from.y + delta.y))
                cells[index].page = currentPage
                controller?.setPosition(cells[index].spot, for: cells[index].item.url)
            }
            return true
        }

        let first = ZoneSpot(origin: shown(CGPoint(x: point.x - metrics.cellWidth / 2, y: point.y - metrics.icon / 2)),
                             page: currentPage)
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            var spots = [first]
            if urls.count > 1 {
                spots = []
                var page = currentPage
                while spots.count < urls.count {
                    let free = freeSlots(on: page, avoiding: cells).map { ZoneSpot(origin: $0, page: page) }
                    spots += free.prefix(urls.count - spots.count)
                    page += 1
                }
            }
            controller?.adopt(urls, at: spots, copy: !sender.draggingSourceOperationMask.contains(.move))
            return true
        }

        // file promises (browser images, mail attachments)
        let receivers = (sender.draggingPasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        guard !receivers.isEmpty, let root = controller?.store.root else { return false }
        strayHint = first
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: root, options: [:], operationQueue: promiseQueue) { [weak self] _, _ in
                DispatchQueue.main.async { self?.controller?.refreshSoon() }
            }
        }
        return true
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 49: toggleQuickLook(nil)
        case 36, 76: beginRename(nil)
        case 51 where command: trashSelection(nil)
        case 31 where command, 125 where command: openSelection(nil)
        case 124, 125, 121: turnPage(by: 1)      // right, down, page down
        case 123, 126, 116: turnPage(by: -1)     // left, up, page up
        case 53:
            selection = []
            redraw()
        default: super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        selection = Set(cells.filter { $0.page == currentPage }.map(\.item.url.path))
        redraw()
    }

    // MARK: - Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        // Control-press is held back until it is known to be a click or a drag (see mouseUp).
        if event.type == .leftMouseDown, event.modifierFlags.contains(.control) { return nil }
        return contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    private func contextMenu(at point: CGPoint) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector, on: Bool = false) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
        }
        if let index = cellIndex(at: point) {
            let path = cells[index].item.url.path
            if !selection.contains(path) { selection = [path] }
            redraw()
            add("Open", #selector(openSelection(_:)))
            add("Quick Look", #selector(toggleQuickLook(_:)))
            if selection.count == 1 { add("Rename", #selector(beginRename(_:))) }
            add("Show in Finder", #selector(revealSelection(_:)))
            menu.addItem(.separator())
            add("Keep \(controller?.retentionDays ?? 7) More Days", #selector(keepSelection(_:)))
            add("Move to Trash", #selector(trashSelection(_:)))
        } else {
            add("Clean Up", #selector(cleanUpByMenu(_:)))
            let sortMenu = NSMenu()
            for (title, order) in [("Name", CleanUpOrder.name), ("Date Added", .dateAdded), ("Time Left", .timeLeft)] {
                let item = sortMenu.addItem(withTitle: title, action: #selector(cleanUpByMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = order.rawValue
            }
            menu.addItem(withTitle: "Clean Up By", action: nil, keyEquivalent: "").submenu = sortMenu
            menu.addItem(.separator())
            add("Settings…", #selector(showSettings(_:)))
            add("Launch at Login", #selector(toggleLogin(_:)), on: controller?.launchesAtLogin ?? false)
            menu.addItem(.separator())
            add("Quit Landfill", #selector(quit(_:)))
        }
        return menu
    }

    @objc private func openSelection(_ sender: Any?) { controller?.open(selectedURLs) }
    @objc private func keepSelection(_ sender: Any?) { controller?.touch(selectedURLs) }
    @objc private func trashSelection(_ sender: Any?) { controller?.trash(selectedURLs) }
    @objc private func revealSelection(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting(selectedURLs) }
    @objc private func cleanUpByMenu(_ sender: NSMenuItem) {
        cleanUp(by: CleanUpOrder(rawValue: sender.tag) ?? .position)
    }

    @objc private func showSettings(_ sender: Any?) { controller?.showSettings() }
    @objc private func toggleLogin(_ sender: Any?) { controller?.toggleLaunchAtLogin() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    // MARK: - Rename

    @objc private func beginRename(_ sender: Any?) {
        guard selection.count == 1, let cell = selectedCells.first else { return }
        let name = cell.item.name
        let field = NSTextField(string: name)
        field.frame = labelRect(cell).insetBy(dx: -2, dy: 0)
        field.frame.size.height = metrics.text + 9
        field.font = .systemFont(ofSize: metrics.text)
        field.alignment = .center
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
        renameField = field
        renamingURL = cell.item.url
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(
            location: 0, length: ((name as NSString).deletingPathExtension as NSString).length)
    }

    private func finishRename(commit: Bool) {
        guard let field = renameField, let url = renamingURL else { return }
        renameField = nil
        renamingURL = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if commit, !name.isEmpty, name != url.lastPathComponent {
            controller?.rename(url, to: name)
        }
        refreshHover()
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishRename(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishRename(commit: false)
        return true
    }

    // MARK: - Quick Look

    @objc private func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if !selection.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKey()
            window?.makeFirstResponder(self)
            panel.makeKeyAndOrderFront(nil)
            controller?.touch(selectedURLs)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedURLs.indices.contains(index) ? selectedURLs[index] as NSURL : nil
    }
}

final class PageView: ZoneBackgroundView {
    let content = PageContentView()

    init(frame: NSRect, page: Int, zone: ZoneView, style: WidgetStyle) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        content.zone = zone
        content.page = page
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(content)
        apply(style)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class PageContentView: NSView {
    weak var zone: ZoneView?
    var page = 0 { didSet { if page != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { zone?.drawContents(ofPage: page) }
}

final class OverlayView: NSView {
    weak var zone: ZoneView?

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { zone?.drawOverlay() }
}
