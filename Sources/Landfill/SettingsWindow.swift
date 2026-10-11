import AppKit

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static let dayChoices = [1, 2, 3, 5, 7, 14, 30]

    private weak var controller: ZoneController?
    private var window: NSWindow?
    private weak var loginCheckbox: NSButton?

    init(controller: ZoneController) {
        self.controller = controller
    }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let days = controller?.retentionDays ?? 7
        let choices = (Self.dayChoices + [days]).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }.sorted()

        let popup = NSPopUpButton()
        for choice in choices {
            popup.addItem(withTitle: choice == 1 ? "1 day" : "\(choice) days")
            popup.lastItem?.tag = choice
        }
        popup.selectItem(withTag: days)
        popup.target = self
        popup.action = #selector(retentionChanged(_:))

        let retention = NSStackView(views: [
            NSTextField(labelWithString: "Move files to the Trash after"),
            popup,
            NSTextField(labelWithString: "untouched"),
        ])
        retention.spacing = 6

        let note = NSTextField(wrappingLabelWithString:
            "Opening, previewing or saving a file starts its time over. The time keeps running while your Mac "
            + "is asleep or off. If you shorten it, files that would go at once get 24 more hours.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380

        let axis = NSPopUpButton()
        axis.addItems(withTitles: ["Up and Down", "Side to Side"])
        axis.selectItem(at: controller?.pagesTurnSideways == true ? 1 : 0)
        axis.target = self
        axis.action = #selector(axisChanged(_:))
        let pages = NSStackView(views: [NSTextField(labelWithString: "When the zone is full, pages turn"), axis])
        pages.spacing = 6

        let login = NSButton(checkboxWithTitle: "Open Landfill at login", target: self, action: #selector(loginChanged(_:)))
        login.state = controller?.launchesAtLogin == true ? .on : .off
        loginCheckbox = login

        let buttons = NSStackView(views: [
            NSButton(title: "Reset Zone Position", target: self, action: #selector(resetZone(_:))),
            NSButton(title: "Show Files in Finder", target: self, action: #selector(revealFiles(_:))),
        ])

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let about = NSTextField(labelWithString: "Landfill \(version)")
        about.textColor = .secondaryLabelColor
        let quit = NSButton(title: "Quit Landfill", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [about, spacer, quit])

        let hide = NSButton(checkboxWithTitle: "Hide the zone until the pointer is over it",
                            target: self, action: #selector(hideChanged(_:)))
        hide.state = controller?.hidesUntilHover == false ? .off : .on

        let stack = NSStackView(views: [retention, note, pages, hide, login, buttons, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(22, after: buttons)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Landfill Settings"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(stack.fittingSize)
        window.center()
        return window
    }

    @objc private func retentionChanged(_ sender: NSPopUpButton) {
        controller?.setRetentionDays(sender.selectedTag())
    }

    @objc private func hideChanged(_ sender: NSButton) {
        controller?.hidesUntilHover = sender.state == .on
    }

    @objc private func axisChanged(_ sender: NSPopUpButton) {
        controller?.pagesTurnSideways = sender.indexOfSelectedItem == 1
    }

    @objc private func loginChanged(_ sender: NSButton) {
        controller?.toggleLaunchAtLogin()
        sender.state = controller?.launchesAtLogin == true ? .on : .off
    }

    @objc private func resetZone(_ sender: Any?) { controller?.resetFrame() }
    @objc private func revealFiles(_ sender: Any?) { controller?.revealFiles() }
}
