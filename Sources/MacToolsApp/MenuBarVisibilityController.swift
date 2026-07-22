import AppKit
import ApplicationServices
import CoreServices

struct MenuBarApplicationItem: Sendable {
    let localizedName: String
    let isAllowed: Bool
    let applicationURL: URL?
}

enum MenuBarVisibilityError: LocalizedError {
    case unsupportedSystem
    case accessibilityPermissionRequired
    case systemSettingsUnavailable
    case applicationListUnavailable
    case applicationControlNotFound(String)
    case systemSettingsRejectedAction(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            "The application menu bar visibility controls require macOS 26 or later."
        case .accessibilityPermissionRequired:
            "Accessibility permission is required to operate the matching switch in System Settings."
        case .systemSettingsUnavailable:
            "System Settings could not be opened."
        case .applicationListUnavailable:
            "The application controls in System Settings > Menu Bar are not available."
        case let .applicationControlNotFound(name):
            "The ‘Allow in the Menu Bar’ switch for \(name) could not be found in System Settings."
        case let .systemSettingsRejectedAction(name):
            "System Settings did not change the menu bar visibility for \(name)."
        }
    }
}

private final class WorkspaceOpenResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedApplication: NSRunningApplication?
    private var storedError: Error?

    func store(application: NSRunningApplication?, error: Error?) {
        lock.lock()
        storedApplication = application
        storedError = error
        lock.unlock()
    }

    func load() -> (application: NSRunningApplication?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (storedApplication, storedError)
    }
}

private struct SystemSettingsApplicationRow {
    let localizedName: String
    let isAllowed: Bool
    let control: AXUIElement
}

private struct PositionedAccessibilityLabel {
    let text: String
    let position: CGPoint
}

final class MenuBarVisibilityController: @unchecked Sendable {
    private let workerQueue = DispatchQueue(label: "local.clearain.MacTools.menu-bar-visibility")
    private let systemSettingsBundleIdentifier = "com.apple.systempreferences"
    private let systemSettingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
    private let menuBarSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
    private let controlCenterLocalizationURL = URL(
        fileURLWithPath: "/System/Library/ExtensionKit/Extensions/ControlCenterSettings.appex/Contents/Resources/Localizable.loctable"
    )
    private var installedApplicationURLsByName: [String: URL]?

    func applications(
        completion: @escaping @MainActor (Result<[MenuBarApplicationItem], Error>) -> Void
    ) {
        workerQueue.async { [self] in
            let result = Result {
                let rows = try self.applicationRows()
                let applicationURLs = self.applicationURLs(for: rows.map(\.localizedName))
                return rows.map {
                    MenuBarApplicationItem(
                        localizedName: $0.localizedName,
                        isAllowed: $0.isAllowed,
                        applicationURL: applicationURLs[self.normalizeSearchText($0.localizedName)]
                    )
                }
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func setAllowed(
        _ allowed: Bool,
        localizedName: String,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        workerQueue.async { [self] in
            let result = Result {
                try self.setAllowedSynchronously(allowed, localizedName: localizedName)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func applicationRows() throws -> [SystemSettingsApplicationRow] {
        guard #available(macOS 26.0, *) else {
            throw MenuBarVisibilityError.unsupportedSystem
        }
        guard AXIsProcessTrusted() else {
            throw MenuBarVisibilityError.accessibilityPermissionRequired
        }

        let application = try openMenuBarSettings()
        let accessibilityApplication = AXUIElementCreateApplication(application.processIdentifier)
        let deadline = Date().addingTimeInterval(6)
        repeat {
            let rows = systemSettingsApplicationRows(in: accessibilityApplication)
            if !rows.isEmpty {
                return rows.sorted {
                    $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        throw MenuBarVisibilityError.applicationListUnavailable
    }

    private func applicationURLs(for localizedNames: [String]) -> [String: URL] {
        if installedApplicationURLsByName == nil {
            installedApplicationURLsByName = indexInstalledApplications()
        }
        var indexedURLs = installedApplicationURLsByName ?? [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleURL = application.bundleURL else {
                continue
            }
            indexApplication(bundleURL, localizedName: application.localizedName, into: &indexedURLs)
        }
        return Dictionary(uniqueKeysWithValues: localizedNames.compactMap { localizedName in
            let normalizedName = normalizeSearchText(localizedName)
            return indexedURLs[normalizedName].map { (normalizedName, $0) }
        })
    }

    private func indexInstalledApplications() -> [String: URL] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
        ]
        var indexedURLs: [String: URL] = [:]
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let applicationURL as URL in enumerator where applicationURL.pathExtension.lowercased() == "app" {
                indexApplication(applicationURL, localizedName: nil, into: &indexedURLs)
                enumerator.skipDescendants()
            }
        }
        for bundleIdentifier in ["com.apple.accessibility.LiveTranscriptionAgent"] {
            if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                indexApplication(applicationURL, localizedName: nil, into: &indexedURLs)
            }
        }
        let liveCaptionsURL = URL(
            fileURLWithPath: "/System/Library/PrivateFrameworks/AccessibilitySharedSupport.framework/Versions/A/Resources/Live Captions.app"
        )
        if fileManager.fileExists(atPath: liveCaptionsURL.path) {
            indexApplication(liveCaptionsURL, localizedName: nil, into: &indexedURLs)
        }
        return indexedURLs
    }

    private func indexApplication(
        _ applicationURL: URL,
        localizedName: String?,
        into indexedURLs: inout [String: URL]
    ) {
        let bundle = Bundle(url: applicationURL)
        let localizedFileName = try? applicationURL.resourceValues(forKeys: [.localizedNameKey]).localizedName
        let metadataDisplayName = MDItemCreate(kCFAllocatorDefault, applicationURL.path as CFString)
            .flatMap { MDItemCopyAttribute($0, kMDItemDisplayName) as? String }
        let names = [
            localizedName,
            bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
            bundle?.localizedInfoDictionary?["CFBundleName"] as? String,
            bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
            metadataDisplayName,
            localizedFileName,
            FileManager.default.displayName(atPath: applicationURL.path),
            applicationURL.deletingPathExtension().lastPathComponent,
        ].compactMap { $0?.replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards]) }
        for name in names {
            indexedURLs[normalizeSearchText(name)] = applicationURL
        }
    }

    private func setAllowedSynchronously(_ allowed: Bool, localizedName: String) throws {
        let normalizedName = normalizeSearchText(localizedName)
        guard let row = try applicationRows().first(where: {
            normalizeSearchText($0.localizedName) == normalizedName
        }) else {
            throw MenuBarVisibilityError.applicationControlNotFound(localizedName)
        }
        if row.isAllowed == allowed {
            return
        }

        let pressError = AXUIElementPerformAction(row.control, kAXPressAction as CFString)
        guard pressError == .success else {
            throw MenuBarVisibilityError.systemSettingsRejectedAction(localizedName)
        }
        for _ in 0..<25 {
            if accessibilityBooleanValue(row.control) == allowed {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw MenuBarVisibilityError.systemSettingsRejectedAction(localizedName)
    }

    private func openMenuBarSettings() throws -> NSRunningApplication {
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false

        let result = WorkspaceOpenResult()
        NSWorkspace.shared.open(
            [menuBarSettingsURL],
            withApplicationAt: systemSettingsURL,
            configuration: configuration
        ) { application, error in
            result.store(application: application, error: error)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw MenuBarVisibilityError.systemSettingsUnavailable
        }
        let openResult = result.load()
        guard openResult.error == nil,
              let application = openResult.application
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: systemSettingsBundleIdentifier).first else {
            throw openResult.error ?? MenuBarVisibilityError.systemSettingsUnavailable
        }
        return application
    }

    private func systemSettingsApplicationRows(
        in application: AXUIElement
    ) -> [SystemSettingsApplicationRow] {
        let headings = localizedAllowInMenuBarHeadings()
        guard let headingElement = findElement(in: application, containingAnyText: headings),
              let headingPosition = accessibilityPoint(headingElement),
              let section = closestApplicationSection(containing: headingElement) else {
            return []
        }
        let labels = positionedLabels(in: section).filter { $0.position.y > headingPosition.y }

        var rows: [SystemSettingsApplicationRow] = []
        for control in visibilityControls(in: section, limit: 2_000) {
            guard let controlPosition = accessibilityPoint(control),
                  controlPosition.y > headingPosition.y,
                  let isAllowed = accessibilityBooleanValue(control),
                  let localizedName = labels
                    .filter({
                        $0.position.x < controlPosition.x
                            && abs($0.position.y - controlPosition.y) <= 12
                    })
                    .min(by: {
                        abs($0.position.y - controlPosition.y)
                            < abs($1.position.y - controlPosition.y)
                    })?.text else {
                continue
            }
            rows.append(
                SystemSettingsApplicationRow(
                    localizedName: localizedName,
                    isAllowed: isAllowed,
                    control: control
                )
            )
        }

        var seenNames = Set<String>()
        return rows.filter {
            seenNames.insert(normalizeSearchText($0.localizedName)).inserted
        }
    }

    private func localizedAllowInMenuBarHeadings() -> [String] {
        var headings = Set(["Allow in the Menu Bar"])
        if let data = try? Data(contentsOf: controlCenterLocalizationURL),
           let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let localizations = propertyList as? [String: Any] {
            for localization in localizations.values {
                guard let strings = localization as? [String: Any],
                      let heading = strings["Allow in the Menu Bar"] as? String else {
                    continue
                }
                headings.insert(heading)
            }
        }
        return Array(headings)
    }

    private func findElement(in root: AXUIElement, containingAnyText texts: [String]) -> AXUIElement? {
        let normalizedTexts = texts.map(normalizeSearchText).filter { !$0.isEmpty }
        guard !normalizedTexts.isEmpty else {
            return nil
        }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, queue.count < 5_000 {
            let (element, depth) = queue[index]
            index += 1
            let elementStrings = directSearchableStrings(for: element).map(normalizeSearchText)
            if normalizedTexts.contains(where: { heading in
                elementStrings.contains(where: { $0 == heading })
            }) {
                return element
            }
            if depth < 25 {
                queue.append(contentsOf: accessibilityElements(element, attribute: kAXChildrenAttribute).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private func closestApplicationSection(containing heading: AXUIElement) -> AXUIElement? {
        var ancestor = accessibilityElement(heading, attribute: kAXParentAttribute)
        for _ in 0..<8 {
            guard let current = ancestor else {
                break
            }
            let count = visibilityControls(in: current, limit: 2_000).count
            if count >= 2 {
                return current
            }
            ancestor = accessibilityElement(current, attribute: kAXParentAttribute)
        }
        return nil
    }

    private func visibilityControls(in root: AXUIElement, limit: Int) -> [AXUIElement] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var controls: [AXUIElement] = []
        while index < queue.count, index < limit {
            let (element, depth) = queue[index]
            index += 1
            let role = accessibilityString(element, attribute: kAXRoleAttribute)
            if isVisibilityControlRole(role, element: element) {
                controls.append(element)
            }
            if depth < 12 {
                queue.append(contentsOf: accessibilityElements(element, attribute: kAXChildrenAttribute).map { ($0, depth + 1) })
            }
        }
        return controls
    }

    private func positionedLabels(in root: AXUIElement) -> [PositionedAccessibilityLabel] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var labels: [PositionedAccessibilityLabel] = []
        while index < queue.count, index < 2_000 {
            let (element, depth) = queue[index]
            index += 1
            if accessibilityString(element, attribute: kAXRoleAttribute) == kAXStaticTextRole as String,
               let position = accessibilityPoint(element) {
                for string in directSearchableStrings(for: element) where isPlausibleApplicationName(string) {
                    labels.append(
                        PositionedAccessibilityLabel(
                            text: string.trimmingCharacters(in: .whitespacesAndNewlines),
                            position: position
                        )
                    )
                }
            }
            if depth < 12 {
                queue.append(contentsOf: accessibilityElements(element, attribute: kAXChildrenAttribute).map { ($0, depth + 1) })
            }
        }
        return labels
    }

    private func directSearchableStrings(for element: AXUIElement) -> [String] {
        [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXValueDescriptionAttribute,
            kAXValueAttribute,
        ].compactMap { accessibilityString(element, attribute: $0) }
    }

    private func isPlausibleApplicationName(_ value: String) -> Bool {
        let normalized = normalizeSearchText(value)
        return !normalized.isEmpty
            && normalized.count <= 120
            && !normalized.contains("turning off")
            && !normalized.contains("menu bar item")
            && !normalized.contains("application isn")
            && !normalized.contains("关闭菜单栏")
    }

    private func accessibilityBooleanValue(_ element: AXUIElement) -> Bool? {
        guard let value = accessibilityValue(element, attribute: kAXValueAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "1", "true", "on", "yes":
                return true
            case "0", "false", "off", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func accessibilityPoint(_ element: AXUIElement) -> CGPoint? {
        guard let value = accessibilityValue(element, attribute: kAXPositionAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func isVisibilityControlRole(_ role: String?, element: AXUIElement) -> Bool {
        role == kAXCheckBoxRole as String
            || role == "AXSwitch"
            || (role == kAXButtonRole as String && accessibilityBooleanValue(element) != nil)
    }

    private func accessibilityString(_ element: AXUIElement, attribute: String) -> String? {
        accessibilityValue(element, attribute: attribute) as? String
    }

    private func accessibilityElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = accessibilityValue(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func accessibilityElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let values = accessibilityValue(element, attribute: attribute) as? [AnyObject] else {
            return []
        }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }

    private func accessibilityValue(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func normalizeSearchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

@MainActor
private final class MenuBarVisibilityRowView: NSView {
    let localizedName: String
    private let interactionButton = NSButton()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let checkmarkView = NSImageView()
    private let progressIndicator = NSProgressIndicator()
    private var rowTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    var toggleHandler: ((Bool) -> Void)?

    init(item: MenuBarApplicationItem) {
        localizedName = item.localizedName
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))

        let sourceIcon = item.applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(named: NSImage.applicationIconName)
        if let icon = sourceIcon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            iconView.image = icon
        }
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.stringValue = item.localizedName
        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        checkmarkView.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "Shown in the menu bar"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        checkmarkView.contentTintColor = .labelColor
        checkmarkView.imageScaling = .scaleProportionallyDown

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        interactionButton.title = ""
        interactionButton.setButtonType(.toggle)
        interactionButton.isBordered = false
        interactionButton.isTransparent = true
        interactionButton.focusRingType = .none
        interactionButton.toolTip = item.localizedName
        interactionButton.target = self
        interactionButton.action = #selector(toggleRow(_:))

        [iconView, nameLabel, checkmarkView, progressIndicator, interactionButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmarkView.leadingAnchor, constant: -8),

            checkmarkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkView.widthAnchor.constraint(equalToConstant: 14),
            checkmarkView.heightAnchor.constraint(equalToConstant: 14),

            progressIndicator.centerXAnchor.constraint(equalTo: checkmarkView.centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: checkmarkView.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 14),
            progressIndicator.heightAnchor.constraint(equalToConstant: 14),

            interactionButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            interactionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            interactionButton.topAnchor.constraint(equalTo: topAnchor),
            interactionButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(isAllowed: item.isAllowed, isEnabled: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rowTrackingArea {
            removeTrackingArea(rowTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        rowTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isPointerInside = true
        updateHighlightAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerInside = false
        updateHighlightAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPointerInside {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 4, dy: 1),
                xRadius: 5,
                yRadius: 5
            ).fill()
        }
        super.draw(dirtyRect)
    }

    func apply(isAllowed: Bool, isEnabled: Bool) {
        interactionButton.state = isAllowed ? .on : .off
        interactionButton.isEnabled = isEnabled
        checkmarkView.isHidden = !isEnabled || !isAllowed
        if isEnabled {
            progressIndicator.stopAnimation(nil)
        } else {
            progressIndicator.startAnimation(nil)
        }
    }

    @objc private func toggleRow(_ sender: NSButton) {
        toggleHandler?(sender.state == .on)
    }

    private func updateHighlightAppearance() {
        let foregroundColor: NSColor = isPointerInside ? .selectedMenuItemTextColor : .labelColor
        nameLabel.textColor = foregroundColor
        checkmarkView.contentTintColor = foregroundColor
        nameLabel.cell?.backgroundStyle = isPointerInside ? .emphasized : .normal
        needsDisplay = true
    }
}

@MainActor
final class MenuBarVisibilityMenuController: NSObject, NSMenuDelegate {
    private let visibilityController = MenuBarVisibilityController()
    private let errorHandler: (Error) -> Void
    private var cachedApplications: [MenuBarApplicationItem] = []
    private var pendingApplicationNames = Set<String>()
    private var isLoading = false
    let menu = NSMenu(title: "Menu Bar Icons")

    init(errorHandler: @escaping (Error) -> Void) {
        self.errorHandler = errorHandler
        super.init()
        menu.delegate = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        refreshApplications()
    }

    private func refreshApplications() {
        guard !isLoading else {
            return
        }
        isLoading = true
        visibilityController.applications { [weak self] result in
            guard let self else {
                return
            }
            self.isLoading = false
            switch result {
            case let .success(applications):
                self.cachedApplications = applications
                self.applyApplicationsToMenu()
            case let .failure(error):
                self.cachedApplications = []
                self.showMenuError(error)
            }
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        if cachedApplications.isEmpty {
            addUnavailableItem(title: isLoading ? "Loading…" : "Loading Applications…")
            return
        }
        for application in cachedApplications {
            let item = NSMenuItem(title: application.localizedName, action: nil, keyEquivalent: "")
            let rowView = MenuBarVisibilityRowView(item: application)
            rowView.toggleHandler = { [weak self, weak rowView] allowed in
                guard let self, let rowView else {
                    return
                }
                self.toggleApplication(
                    localizedName: application.localizedName,
                    allowed: allowed,
                    rowView: rowView
                )
            }
            item.view = rowView
            menu.addItem(item)
        }
    }

    private func applyApplicationsToMenu() {
        let rows = menu.items.compactMap { $0.view as? MenuBarVisibilityRowView }
        let rowsByName = Dictionary(uniqueKeysWithValues: rows.map { ($0.localizedName, $0) })
        guard rows.count == cachedApplications.count,
              cachedApplications.allSatisfy({ rowsByName[$0.localizedName] != nil }) else {
            rebuildMenu()
            return
        }

        for application in cachedApplications {
            guard !pendingApplicationNames.contains(application.localizedName) else {
                continue
            }
            rowsByName[application.localizedName]?.apply(
                isAllowed: application.isAllowed,
                isEnabled: true
            )
        }
    }

    private func toggleApplication(
        localizedName: String,
        allowed: Bool,
        rowView: MenuBarVisibilityRowView
    ) {
        guard pendingApplicationNames.insert(localizedName).inserted else {
            return
        }
        rowView.apply(isAllowed: allowed, isEnabled: false)
        visibilityController.setAllowed(
            allowed,
            localizedName: localizedName
        ) { [weak self] result in
            guard let self else {
                return
            }
            self.pendingApplicationNames.remove(localizedName)
            if case let .failure(error) = result {
                self.errorHandler(error)
            }
            self.refreshApplications()
        }
    }

    private func showMenuError(_ error: Error) {
        menu.removeAllItems()
        addUnavailableItem(title: error.localizedDescription)
        errorHandler(error)
    }

    private func addUnavailableItem(title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}
