import AppKit

/// Desktop widgets sit in 180 pt cells. The grid is read from the widgets on screen.
struct WidgetGrid {
    static let defaultPitch: CGFloat = 180
    /// How far the visible tile sits inside its cell.
    static let tileInset: CGFloat = 8

    var pitch = WidgetGrid.defaultPitch
    var widgets: [NSRect] = []

    /// Only reads window frames, so no permission is needed.
    static func current() -> WidgetGrid {
        let owners = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .map { Int($0.processIdentifier) })
        guard !owners.isEmpty, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return WidgetGrid() }

        var grid = WidgetGrid()
        for window in windows {
            // desktop widgets sit below normal windows
            guard let owner = window[kCGWindowOwnerPID as String] as? Int, owners.contains(owner),
                  let layer = window[kCGWindowLayer as String] as? Int, layer < 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 100, rect.height >= 100, rect.width < 1200 else { continue }
            grid.widgets.append(NSRect(x: rect.minX, y: primary.frame.height - rect.maxY,
                                       width: rect.width, height: rect.height))
        }
        if let smallest = grid.widgets.map({ min($0.width, $0.height) }).min() {
            grid.pitch = smallest / max(1, (smallest / defaultPitch).rounded())
        }
        return grid
    }

    func size(columns: Int, rows: Int) -> CGSize {
        CGSize(width: CGFloat(columns) * pitch, height: CGFloat(rows) * pitch)
    }

    func snap(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        let size = self.size(columns: max(1, Int((frame.width / pitch).rounded())),
                             rows: max(1, Int((frame.height / pitch).rounded())))
        let area = screen?.visibleFrame
        let onScreen = widgets.filter { area == nil || area!.intersects($0) }
        let nearest = onScreen.min { distance(from: frame, to: $0) < distance(from: frame, to: $1) }
        let anchor = nearest.map { CGPoint(x: $0.minX, y: $0.maxY) }
            ?? CGPoint(x: area?.minX ?? frame.minX, y: area?.maxY ?? frame.maxY)

        var x = anchor.x + ((frame.minX - anchor.x) / pitch).rounded() * pitch
        var top = anchor.y + ((frame.maxY - anchor.y) / pitch).rounded() * pitch
        if let area, size.width <= area.width, size.height <= area.height {
            while x + size.width > area.maxX { x -= pitch }
            while x < area.minX { x += pitch }
            while top > area.maxY { top -= pitch }
            while top - size.height < area.minY { top += pitch }
        }
        let snapped = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        return clearOfWidgets(snapped, wanted: frame, within: area)
    }

    /// Widgets draw above the zone, so don't sit under one.
    private func clearOfWidgets(_ snapped: NSRect, wanted: NSRect, within area: NSRect?) -> NSRect {
        func isFree(_ rect: NSRect) -> Bool {
            !widgets.contains { $0.intersects(rect.insetBy(dx: 1, dy: 1)) }
        }
        if isFree(snapped) { return snapped }
        var best: NSRect?
        var bestDistance = CGFloat.infinity
        for column in -8...8 {
            for row in -8...8 {
                let candidate = snapped.offsetBy(dx: CGFloat(column) * pitch, dy: CGFloat(row) * pitch)
                if let area, !area.insetBy(dx: -1, dy: -1).contains(candidate) { continue }
                let away = hypot(candidate.minX - wanted.minX, candidate.maxY - wanted.maxY)
                if away < bestDistance, isFree(candidate) {
                    best = candidate
                    bestDistance = away
                }
            }
        }
        return best ?? snapped
    }

    private func distance(from a: NSRect, to b: NSRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return hypot(dx, dy)
    }
}
