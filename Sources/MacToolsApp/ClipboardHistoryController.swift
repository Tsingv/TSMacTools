import AppKit
import MacToolsCore

private final class FloatingClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension ClipboardHistoryItem {
    var previewImage: NSImage? {
        previewImageData.flatMap { NSImage(data: $0) }
    }
}

/// Polls the general pasteboard the way Maccy does and presents a keyboard-first history panel.
@MainActor
final class ClipboardHistoryController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private var store = ClipboardHistoryStore()
    private var settings: ClipboardSettings = .default
    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private var suppressNextChange = false
    private var panel: NSPanel?
    private var searchField: NSSearchField?
    private var table: NSTableView?
    private var footer: NSTextField?
    private var visible: [ClipboardHistoryItem] = []
    private var query = ""
    private var previousApplication: NSRunningApplication?
    private var previousWindow: AXUIElement?
    private var keyMonitor: Any?
    private let historyURL: URL

    private static let ownMarker = NSPasteboard.PasteboardType("local.clearain.MacTools.clipboard")
    private static let stringType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let fileURLType = NSPasteboard.PasteboardType("public.file-url")

    init(historyDirectory: URL) {
        historyURL = historyDirectory.appendingPathComponent("clipboard-history.json")
        super.init()
        load()
    }

    func apply(settings: ClipboardSettings) {
        self.settings = settings.sanitized
        store.apply(settings: self.settings)
        save()
        restartTimer()
    }

    func start() {
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func clearHistory(includingPinned: Bool) {
        store.clear(includingPinned: includingPinned)
        save()
        if settings.clearSystemClipboard && includingPinned {
            NSPasteboard.general.clearContents()
            suppressNextChange = true
            changeCount = NSPasteboard.general.changeCount
        }
        if panel?.isVisible == true { reloadVisible() }
    }

    func togglePopup() {
        if panel?.isVisible == true {
            closePopup()
        } else {
            showPopup()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        guard settings.enabled else { return }
        let timer = Timer(timeInterval: settings.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        if suppressNextChange {
            suppressNextChange = false
            return
        }
        guard settings.enabled else { return }
        if settings.ignoreEvents {
            if settings.ignoreOnlyNextEvent {
                settings.ignoreEvents = false
                settings.ignoreOnlyNextEvent = false
                store.apply(settings: settings)
            }
            return
        }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        if store.settings.shouldIgnore(types: types) { return }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if store.settings.shouldIgnore(application: app) { return }

        var representations: [ClipboardRepresentation] = []
        let items = pasteboard.pasteboardItems ?? []
        for item in items {
            let itemTypes = item.types.map(\.rawValue)
            if store.settings.shouldIgnore(types: Set(itemTypes)) { continue }
            let text = item.string(forType: Self.stringType)
            if store.settings.shouldIgnore(plainText: text) { continue }
            for type in item.types where ClipboardSettings.isPersistableType(type.rawValue) {
                if let data = item.data(forType: type), !data.isEmpty {
                    representations.append(ClipboardRepresentation(type: type.rawValue, data: data))
                }
            }
        }
        guard store.record(ClipboardHistoryItem(representations: representations, application: app)) != nil else { return }
        save()
        if panel?.isVisible == true { reloadVisible() }
    }

    private func showPopup() {
        query = ""
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = front
            previousWindow = front.flatMap(Self.focusedWindow)
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        reloadVisible()
        if let screen = NSScreen.main {
            let frame = panel.frame
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2 + 80
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        searchField?.stringValue = ""
        panel.makeFirstResponder(searchField)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel?.isKeyWindow == true else { return event }
                return self.handle(event) ? nil : event
            }
        }
    }

    private func closePopup() {
        panel?.orderOut(nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        let previous = previousApplication
        let window = previousWindow
        previousApplication = nil
        previousWindow = nil
        previous?.activate(options: [.activateIgnoringOtherApps])
        if let previous, let window {
            let appElement = AXUIElementCreateApplication(previous.processIdentifier)
            AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    private static func focusedWindow(of application: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.delegate = self
        panel.isReleasedWhenClosed = false

        let search = NSSearchField()
        search.placeholderString = "Search clipboard"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        searchField = search

        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.title = "History"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(copySelection)
        table.target = self
        table.translatesAutoresizingMaskIntoConstraints = false
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(labelWithString: "")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        self.footer = footer

        let root = NSView()
        root.addSubview(search)
        root.addSubview(scroll)
        root.addSubview(footer)
        panel.contentView = root
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        return panel
    }

    func controlTextDidChange(_ notification: Notification) {
        query = searchField?.stringValue ?? ""
        reloadVisible()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let option = NSEvent.modifierFlags.contains(.option)
            let shift = NSEvent.modifierFlags.contains(.shift)
            if option {
                pasteSelection(plain: shift)
            } else {
                copySelection()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closePopup()
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard let table, table.numberOfRows > 0 else { return }
        let next = min(max((table.selectedRow < 0 ? 0 : table.selectedRow) + delta, 0), table.numberOfRows - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        visible[row].previewImageData == nil ? 28 : 84
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visible[row]
        let rowView = NSView()
        let field = NSTextField(labelWithString: (item.pinned ? "\u{1F4CC} " : "") + item.title)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 2
        field.toolTip = item.plainText ?? item.title
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rowView.addSubview(field)

        var leading = rowView.leadingAnchor
        if let preview = item.previewImage {
            let imageView = NSImageView()
            imageView.image = preview
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            rowView.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 72),
                imageView.heightAnchor.constraint(equalToConstant: 72)
            ])
            leading = imageView.trailingAnchor
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leading, constant: 8),
            field.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: rowView.centerYAnchor)
        ])
        return rowView
    }

    @objc private func copySelection() {
        activate(plain: false, paste: false)
    }

    private func pasteSelection(plain: Bool) {
        activate(plain: plain, paste: settings.pasteAutomatically)
    }

    private func selectedItem() -> ClipboardHistoryItem? {
        guard let table else { return visible.first }
        let row = table.selectedRow
        if row >= 0, row < visible.count { return visible[row] }
        return visible.first
    }

    private func activate(plain: Bool, paste: Bool) {
        guard let item = selectedItem() else { return }
        write(item, plain: plain)
        closePopup()
        if paste { postPaste() }
    }

    private func write(_ item: ClipboardHistoryItem, plain: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let representations = plain ? item.plainTextRepresentations : item.representations
        let files = representations.filter { $0.type == Self.fileURLType.rawValue }
        let others = representations.filter { $0.type != Self.fileURLType.rawValue }
        for representation in others {
            pasteboard.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
        }
        if !files.isEmpty {
            let objects: [NSPasteboardItem] = files.map { representation in
                let object = NSPasteboardItem()
                object.setData(representation.data, forType: Self.fileURLType)
                return object
            }
            pasteboard.writeObjects(objects)
        }
        pasteboard.setString("", forType: Self.ownMarker)
        suppressNextChange = true
        changeCount = pasteboard.changeCount
    }

    private func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let keyCode: CGKeyCode = 0x09 // V
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    func windowDidResignKey(_ notification: Notification) {
        closePopup()
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option), event.charactersIgnoringModifiers?.lowercased() == "p" {
            guard let item = selectedItem() else { return true }
            store.togglePin(item.id)
            save()
            reloadVisible()
            return true
        }
        if flags.contains(.option), flags.contains(.command), event.keyCode == 51 {
            store.clear(includingPinned: flags.contains(.shift))
            save()
            reloadVisible()
            return true
        }
        if flags.contains(.option), event.keyCode == 51 {
            guard let item = selectedItem() else { return true }
            store.delete(item.id)
            save()
            reloadVisible()
            return true
        }
        if let shortcut = event.charactersIgnoringModifiers?.lowercased(), shortcut.count == 1,
           let item = store.orderedItems.first(where: { $0.pinned && $0.pinShortcut == shortcut }) {
            write(item, plain: flags.contains(.option) && flags.contains(.shift))
            closePopup()
            if flags.contains(.option) && settings.pasteAutomatically { postPaste() }
            return true
        }
        return false
    }

    private func reloadVisible() {
        visible = store.filtered(query: query)
        table?.reloadData()
        if !visible.isEmpty {
            table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        footer?.stringValue = settings.showFooter
            ? "\u{21B5} copy   \u{2325}\u{21B5} paste   \u{2325}\u{21E7}\u{21B5} plain   \u{2325}P pin   \u{2325}\u{232B} delete"
            : ""
        footer?.isHidden = !settings.showFooter
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode(ClipboardHistoryStore.self, from: data) else { return }
        store = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: historyURL, options: .atomic)
    }
}
