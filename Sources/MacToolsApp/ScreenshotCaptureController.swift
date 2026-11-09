import AppKit
import CoreGraphics
import Foundation
import MacToolsCore

@MainActor
final class ScreenshotCaptureController {
    private var sessions: [ScreenshotOverlaySession] = []
    private var settings: CaptureMediaSettings = .default
    /// App that owned focus before the floating annotation overlay activated.
    private var previousFrontmostApplication: NSRunningApplication?
    var onStatus: ((String, String) -> Void)?
    /// Fired when an annotation overlay becomes active or fully dismisses.
    var onActiveChange: ((Bool) -> Void)?

    func apply(_ settings: CaptureMediaSettings) {
        self.settings = settings.sanitized
    }

    var isActive: Bool { !sessions.isEmpty }

    func beginCapture() {
        cancel(restoreFocus: true)

        if !ensureScreenRecordingPermission() {
            return
        }

        let displays = NSScreen.screens
        guard !displays.isEmpty else {
            onStatus?("Screenshot", "No displays are available.")
            return
        }

        var freezeFrames: [(NSScreen, CGImage, CGFloat)] = []
        for screen in displays {
            guard let image = captureFreezeFrame(for: screen) else { continue }
            freezeFrames.append((screen, image, screen.backingScaleFactor))
        }
        guard !freezeFrames.isEmpty else {
            remindScreenRecordingAuthorization(promptAlreadyShown: true)
            return
        }

        rememberPreviousFrontmostApplication()

        for (screen, image, scale) in freezeFrames {
            let session = ScreenshotOverlaySession(
                screen: screen,
                freezeImage: image,
                scale: scale,
                settings: settings,
                onFinished: { [weak self] result in
                    self?.finish(with: result)
                },
                onCancel: { [weak self] in
                    self?.cancel(restoreFocus: true)
                }
            )
            sessions.append(session)
            session.show()
        }
        onActiveChange?(true)
    }

    func cancel() {
        cancel(restoreFocus: true)
    }

    private func cancel(restoreFocus: Bool) {
        let wasActive = !sessions.isEmpty
        sessions.forEach { $0.close() }
        sessions.removeAll()
        if wasActive {
            onActiveChange?(false)
        }
        if restoreFocus {
            restorePreviousFrontmostApplication()
        } else {
            previousFrontmostApplication = nil
        }
    }

    private func finish(with result: ScreenshotCaptureResult) {
        // Close the overlay first, restore the prior app, then show a non-activating toast.
        cancel(restoreFocus: true)
        do {
            var savedURL: URL?
            if settings.saveScreenshotToDisk || result.copyOnly {
                // Copy also lands a file so clipboard metadata can include the path.
                savedURL = try save(result.pngData)
            }

            if settings.copyScreenshotToClipboard || result.copyOnly {
                writeClipboard(image: result.image, pngData: result.pngData, fileURL: savedURL)
            }

            if let savedURL {
                onStatus?("Screenshot Saved", savedURL.path)
            } else if result.copyOnly || settings.copyScreenshotToClipboard {
                onStatus?("Screenshot Copied", "Image copied to the clipboard.")
            }
        } catch {
            onStatus?("Screenshot Error", error.localizedDescription)
        }
    }

    private func rememberPreviousFrontmostApplication() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            previousFrontmostApplication = nil
            return
        }
        previousFrontmostApplication = frontmost
    }

    private func restorePreviousFrontmostApplication() {
        guard let previous = previousFrontmostApplication,
              previous.bundleIdentifier != Bundle.main.bundleIdentifier,
              !previous.isTerminated else {
            previousFrontmostApplication = nil
            return
        }
        previousFrontmostApplication = nil
        previous.activate(options: [.activateIgnoringOtherApps])
    }

    private func writeClipboard(image: NSImage, pngData: Data, fileURL: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var wrote = false
        if pasteboard.writeObjects([image]) {
            wrote = true
        }
        pasteboard.setData(pngData, forType: .png)

        if let fileURL {
            pasteboard.writeObjects([fileURL as NSURL])
            pasteboard.setString(fileURL.path, forType: .string)
            pasteboard.setString(fileURL.absoluteString, forType: .URL)
            wrote = true
        }

        if !wrote {
            pasteboard.setData(pngData, forType: .png)
        }
    }

    private func save(_ data: Data) throws -> URL {
        let directory = URL(
            fileURLWithPath: settings.screenshotSaveDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = directory.appendingPathComponent("Screenshot-\(formatter.string(from: Date())).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func ensureScreenRecordingPermission() -> Bool {
        if ScreenRecordingPermission.status() == .granted {
            return true
        }
        // Show the native consent sheet first; only guide to Settings if still denied.
        let granted = ScreenRecordingPermission.requestAccess()
        if granted || ScreenRecordingPermission.status() == .granted {
            return true
        }
        remindScreenRecordingAuthorization(promptAlreadyShown: true)
        return false
    }

    private func remindScreenRecordingAuthorization(promptAlreadyShown: Bool) {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = ScreenRecordingPermission.authorizationGuidance
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
        onStatus?(
            "Screen Recording Permission Required",
            ScreenRecordingPermission.authorizationGuidance
        )
        _ = promptAlreadyShown
    }

    private func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func captureFreezeFrame(for screen: NSScreen) -> CGImage? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(truncating: screenNumber)
        // Prefer the display snapshot so multi-monitor freezes stay aligned to each overlay.
        if let image = CGDisplayCreateImage(displayID) {
            return image
        }
        let frame = screen.frame
        let cgRect = CGRect(
            x: frame.origin.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
        return CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
    }
}

private struct ScreenshotCaptureResult {
    let image: NSImage
    let pngData: Data
    let copyOnly: Bool
}

@MainActor
private final class ScreenshotOverlaySession: NSObject {
    private let screen: NSScreen
    private let freezeImage: CGImage
    private let scale: CGFloat
    private let settings: CaptureMediaSettings
    private let onFinished: (ScreenshotCaptureResult) -> Void
    private let onCancel: () -> Void

    private var window: NSPanel?
    private var overlayView: ScreenshotOverlayView?

    init(
        screen: NSScreen,
        freezeImage: CGImage,
        scale: CGFloat,
        settings: CaptureMediaSettings,
        onFinished: @escaping (ScreenshotCaptureResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screen = screen
        self.freezeImage = freezeImage
        self.scale = scale
        self.settings = settings
        self.onFinished = onFinished
        self.onCancel = onCancel
    }

    func show() {
        // Floating HUD panel: stays above content, skips Mission Control / Window menu layout,
        // but can still become key so Return/Escape and text tools work during annotation.
        let window = ScreenshotOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.setFrame(screen.frame, display: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .transient,
            .ignoresCycle
        ]
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true

        let view = ScreenshotOverlayView(
            freezeImage: freezeImage,
            scale: scale,
            onCommit: { [weak self] selection, annotations, copyOnly in
                self?.commit(selection: selection, annotations: annotations, copyOnly: copyOnly)
            },
            onCancel: { [weak self] in
                self?.onCancel()
            }
        )
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
        self.overlayView = view
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        overlayView = nil
    }

    private func commit(selection: CGRect, annotations: [CaptureAnnotationItem], copyOnly: Bool) {
        let overlaySize = screen.frame.size
        guard let rendered = CaptureAnnotationRenderer.render(
            image: freezeImage,
            selection: selection,
            annotations: annotations,
            overlaySize: overlaySize
        ),
        let png = CaptureAnnotationRenderer.pngData(from: rendered) else {
            onCancel()
            return
        }
        let size = NSSize(
            width: CGFloat(rendered.width) / max(scale, 1),
            height: CGFloat(rendered.height) / max(scale, 1)
        )
        let image = NSImage(cgImage: rendered, size: size)
        onFinished(ScreenshotCaptureResult(image: image, pngData: png, copyOnly: copyOnly))
    }
}

private final class ScreenshotOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ScreenshotOverlayView: NSView, NSTextViewDelegate {
    private let freezeImage: CGImage
    private let scale: CGFloat
    private let onCommit: (CGRect, [CaptureAnnotationItem], Bool) -> Void
    private let onCancel: () -> Void

    private var phase: Phase = .selecting
    private var dragStart: CGPoint?
    private var selection = CGRect.zero
    private var activeHandle: CaptureAnnotationGeometry.SelectionHandle?
    private var handleStartSelection = CGRect.zero
    private var annotations: [CaptureAnnotationItem] = []
    private var draft: CaptureAnnotationItem?
    private var tool: CaptureAnnotationTool = .arrow
    private var color: CaptureAnnotationColor = .red
    private var lineWidth: CGFloat = 3
    private var fontSize: CGFloat = 16
    private var blurRadius: CGFloat = 14
    private var nextSequence = 1
    private var toolbar: ScreenshotAnnotationToolbar?
    private var cursorTracking: NSTrackingArea?
    private var textEditor: ScreenshotTextEditor?
    private var textOrigin: CGPoint?
    private var scrollAccumulator: CGFloat = 0

    private enum Phase {
        case selecting
        case adjusting
        case annotating
    }

    init(
        freezeImage: CGImage,
        scale: CGFloat,
        onCommit: @escaping (CGRect, [CaptureAnnotationItem], Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.freezeImage = freezeImage
        self.scale = scale
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsScale = scale
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Match CGImage top-left cropping so preview selection equals the saved crop.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateTracking()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }

    private func updateTracking() {
        if let cursorTracking {
            removeTrackingArea(cursorTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTracking = area
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        // NSImage respects isFlipped; raw CGImage draws would appear upside-down.
        let freeze = NSImage(cgImage: freezeImage, size: bounds.size)
        freeze.draw(in: bounds)

        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fill(bounds)

        if selection.width > 1, selection.height > 1 {
            context.saveGState()
            context.clip(to: selection)
            freeze.draw(in: bounds)
            context.restoreGState()

            for annotation in annotations {
                drawAnnotation(annotation, in: context)
            }
            if let draft {
                drawAnnotation(draft, in: context)
            }

            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(2)
            context.stroke(selection)

            if phase != .selecting {
                for handle in CaptureAnnotationGeometry.SelectionHandle.allCases where handle != .move {
                    let handleRect = handle.rect(in: selection)
                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(handleRect)
                    context.setStrokeColor(NSColor.systemBlue.cgColor)
                    context.stroke(handleRect)
                }
            }
        }
        context.restoreGState()
    }

    private func drawAnnotation(_ annotation: CaptureAnnotationItem, in context: CGContext) {
        let nsColor = NSColor(
            calibratedRed: annotation.color.red,
            green: annotation.color.green,
            blue: annotation.color.blue,
            alpha: annotation.color.alpha
        )
        context.setStrokeColor(nsColor.cgColor)
        context.setFillColor(nsColor.cgColor)
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)

        switch annotation.tool {
        case .select:
            break
        case .arrow:
            let geometry = CaptureAnnotationRenderer.arrowGeometry(
                from: annotation.start,
                to: annotation.end,
                lineWidth: annotation.lineWidth
            )
            context.saveGState()
            context.setLineCap(.butt)
            context.beginPath()
            context.move(to: geometry.shaftStart)
            context.addLine(to: geometry.shaftEnd)
            context.strokePath()
            context.restoreGState()
            context.beginPath()
            context.move(to: geometry.tip)
            context.addLine(to: geometry.left)
            context.addLine(to: geometry.right)
            context.closePath()
            context.fillPath()
        case .rectangle:
            context.stroke(annotation.bounds)
        case .ellipse:
            context.strokeEllipse(in: annotation.bounds)
        case .mosaic:
            if let blurred = CaptureAnnotationRenderer.blurredRegion(
                of: freezeImage,
                rect: annotation.bounds,
                radius: annotation.blurRadius,
                overlaySize: bounds.size
            ) {
                // NSImage respects isFlipped; raw CGContext.draw would vertically offset the blur.
                let preview = NSImage(cgImage: blurred.cgImage, size: blurred.drawRect.size)
                preview.draw(in: blurred.drawRect)
            } else {
                context.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
                context.fill(annotation.bounds)
            }
        case .sequence:
            let radius = max(10, annotation.lineWidth * 4)
            let rect = CGRect(
                x: annotation.end.x - radius,
                y: annotation.end.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fillEllipse(in: rect)
            let label = "\(max(1, annotation.sequenceNumber))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: max(11, annotation.fontSize * 0.75)),
                .foregroundColor: NSColor.white
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(
                at: CGPoint(x: annotation.end.x - size.width / 2, y: annotation.end.y - size.height / 2),
                withAttributes: attrs
            )
        case .text:
            let label = (annotation.text.isEmpty ? "Text" : annotation.text) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: annotation.fontSize),
                .foregroundColor: nsColor
            ]
            label.draw(at: annotation.end, withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEditorIfNeeded()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .selecting:
            dragStart = point
            selection = CGRect(origin: point, size: .zero)
        case .adjusting, .annotating:
            if tool == .select {
                if let handle = CaptureAnnotationGeometry.handle(at: point, in: selection) {
                    activeHandle = handle
                    handleStartSelection = selection
                    dragStart = point
                    needsDisplay = true
                    return
                }
                return
            }

            if let handle = CaptureAnnotationGeometry.handle(at: point, in: selection),
               handle != .move {
                activeHandle = handle
                handleStartSelection = selection
                dragStart = point
                needsDisplay = true
                return
            }

            guard selection.contains(point) else { return }
            if tool == .text {
                beginTextEditor(at: point)
                return
            }
            let sequence = tool == .sequence ? nextSequence : 0
            draft = CaptureAnnotationItem(
                tool: tool,
                color: color,
                start: point,
                end: point,
                sequenceNumber: sequence,
                lineWidth: lineWidth,
                fontSize: fontSize,
                blurRadius: blurRadius
            )
            dragStart = point
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .selecting:
            guard let dragStart else { return }
            selection = CaptureAnnotationGeometry.clamp(
                CaptureAnnotationGeometry.normalizedSelection(from: dragStart, to: point),
                to: bounds
            )
        case .adjusting, .annotating:
            if let activeHandle, let dragStart {
                let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
                selection = CaptureAnnotationGeometry.clamp(
                    activeHandle.applying(delta: delta, to: handleStartSelection),
                    to: bounds
                )
            } else if var draft {
                draft.end = point
                self.draft = draft
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            activeHandle = nil
            needsDisplay = true
        }
        switch phase {
        case .selecting:
            guard selection.width >= 8, selection.height >= 8 else {
                selection = .zero
                return
            }
            phase = .annotating
            presentToolbar()
        case .adjusting, .annotating:
            if let draft {
                let isPointTool = draft.tool == .sequence
                let hasSize = abs(draft.end.x - draft.start.x) >= 2 || abs(draft.end.y - draft.start.y) >= 2
                if isPointTool || hasSize {
                    if draft.tool == .sequence {
                        nextSequence += 1
                    }
                    annotations.append(draft)
                }
                self.draft = nil
            }
            positionToolbar()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard phase == .annotating || phase == .adjusting else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY == 0 ? event.deltaY : event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }

        // Scroll up increases size/intensity. Quantize precise trackpad/smooth deltas
        // so one physical notch becomes one step instead of a large jump.
        scrollAccumulator += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 6 : 0.4
        guard abs(scrollAccumulator) >= threshold else { return }
        let step: CGFloat = scrollAccumulator > 0 ? 1 : -1
        scrollAccumulator = 0

        switch tool {
        case .mosaic:
            blurRadius = min(
                max(blurRadius + step * 2, CaptureAnnotationItem.blurRadiusRange.lowerBound),
                CaptureAnnotationItem.blurRadiusRange.upperBound
            )
            if var draft, draft.tool == .mosaic {
                draft.blurRadius = blurRadius
                self.draft = draft
            }
            if var last = annotations.last, last.tool == .mosaic, draft == nil {
                last.blurRadius = blurRadius
                annotations[annotations.count - 1] = last
            }
        case .text:
            fontSize = min(
                max(fontSize + step, CaptureAnnotationItem.fontSizeRange.lowerBound),
                CaptureAnnotationItem.fontSizeRange.upperBound
            )
            textEditor?.apply(fontSize: fontSize, color: color)
            if var last = annotations.last, last.tool == .text {
                last.fontSize = fontSize
                annotations[annotations.count - 1] = last
            }
        case .select:
            break
        default:
            lineWidth = min(
                max(lineWidth + step, CaptureAnnotationItem.lineWidthRange.lowerBound),
                CaptureAnnotationItem.lineWidthRange.upperBound
            )
            if var draft {
                draft.lineWidth = lineWidth
                self.draft = draft
            }
            if var last = annotations.last, draft == nil, last.tool == tool {
                last.lineWidth = lineWidth
                annotations[annotations.count - 1] = last
            }
        }
        toolbar?.updateAdjustmentSummary(tool: tool, lineWidth: lineWidth, fontSize: fontSize, blurRadius: blurRadius)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if textEditor != nil {
            // NSTextView remains first responder for IME composition; Escape cancels the box.
            if event.keyCode == 53 {
                textEditor?.removeFromSuperview()
                textEditor = nil
                textOrigin = nil
                window?.makeFirstResponder(self)
            }
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            undoLastAnnotation()
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            commit(copyOnly: true)
            return
        }
        switch event.keyCode {
        case 36, 76: // Return / Enter
            commit(copyOnly: true)
        case 53: // Escape
            onCancel()
        case 51: // Delete
            undoLastAnnotation()
        default:
            super.keyDown(with: event)
        }
    }

    private func undoLastAnnotation() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    private func commit(copyOnly: Bool) {
        commitTextEditorIfNeeded()
        guard selection.width >= 8, selection.height >= 8 else {
            onCancel()
            return
        }
        onCommit(selection, annotations, copyOnly)
    }

    private func presentToolbar() {
        let bar = ScreenshotAnnotationToolbar(
            selectedTool: tool,
            selectedColor: color,
            lineWidth: lineWidth,
            fontSize: fontSize,
            blurRadius: blurRadius,
            onTool: { [weak self] tool in
                self?.commitTextEditorIfNeeded()
                self?.tool = tool
                self?.toolbar?.updateAdjustmentSummary(
                    tool: tool,
                    lineWidth: self?.lineWidth ?? 3,
                    fontSize: self?.fontSize ?? 16,
                    blurRadius: self?.blurRadius ?? 14
                )
            },
            onColor: { [weak self] color in
                self?.color = color
                self?.textEditor?.apply(fontSize: self?.fontSize ?? 16, color: color)
            },
            onCopy: { [weak self] in
                self?.commit(copyOnly: true)
            },
            onSave: { [weak self] in
                self?.commit(copyOnly: false)
            },
            onCancel: { [weak self] in
                self?.onCancel()
            },
            onUndo: { [weak self] in
                self?.undoLastAnnotation()
            }
        )
        addSubview(bar)
        toolbar = bar
        positionToolbar()
    }

    private func positionToolbar() {
        guard let toolbar else { return }
        let size = toolbar.fittingSize
        let x = min(max(selection.midX - size.width / 2, 12), bounds.width - size.width - 12)
        let y = min(max(selection.maxY + 12, 12), bounds.height - size.height - 12)
        toolbar.setFrameOrigin(CGPoint(x: x, y: y))
        toolbar.setFrameSize(size)
    }

    private func beginTextEditor(at point: CGPoint) {
        commitTextEditorIfNeeded()
        let editor = ScreenshotTextEditor(fontSize: fontSize, color: color)
        editor.delegate = self
        let width = min(max(180, selection.width * 0.5), selection.width - 8)
        let height = max(fontSize + 18, 36)
        let origin = CGPoint(
            x: min(max(point.x, selection.minX + 4), selection.maxX - width - 4),
            y: min(max(point.y, selection.minY + 4), selection.maxY - height - 4)
        )
        editor.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        addSubview(editor)
        window?.makeFirstResponder(editor.textView)
        textEditor = editor
        textOrigin = origin
    }

    private func commitTextEditorIfNeeded() {
        guard let textEditor, let textOrigin else { return }
        let text = textEditor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        textEditor.removeFromSuperview()
        self.textEditor = nil
        self.textOrigin = nil
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }
        annotations.append(
            CaptureAnnotationItem(
                tool: .text,
                color: color,
                start: textOrigin,
                end: textOrigin,
                text: text,
                lineWidth: lineWidth,
                fontSize: fontSize,
                blurRadius: blurRadius
            )
        )
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) {
        commitTextEditorIfNeeded()
    }
}

@MainActor
private final class ScreenshotTextEditor: NSView {
    let textView: NSTextView
    private let scrollView: NSScrollView

    var string: String { textView.string }

    weak var delegate: NSTextViewDelegate? {
        didSet { textView.delegate = delegate }
    }

    init(fontSize: CGFloat, color: CaptureAnnotationColor) {
        scrollView = NSScrollView(frame: .zero)
        textView = NSTextView(frame: .zero)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 4

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.boldSystemFont(ofSize: fontSize)
        textView.textColor = NSColor(
            calibratedRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        textView.frame = bounds
    }

    func apply(fontSize: CGFloat, color: CaptureAnnotationColor) {
        textView.font = NSFont.boldSystemFont(ofSize: fontSize)
        textView.textColor = NSColor(
            calibratedRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
    }
}

@MainActor
private final class ScreenshotAnnotationToolbar: NSView {
    private let onTool: (CaptureAnnotationTool) -> Void
    private let onColor: (CaptureAnnotationColor) -> Void
    private let onCopy: () -> Void
    private let onSave: () -> Void
    private let onCancel: () -> Void
    private let onUndo: () -> Void
    private let summaryLabel = NSTextField(labelWithString: "")

    init(
        selectedTool: CaptureAnnotationTool,
        selectedColor: CaptureAnnotationColor,
        lineWidth: CGFloat,
        fontSize: CGFloat,
        blurRadius: CGFloat,
        onTool: @escaping (CaptureAnnotationTool) -> Void,
        onColor: @escaping (CaptureAnnotationColor) -> Void,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onUndo: @escaping () -> Void
    ) {
        self.onTool = onTool
        self.onColor = onColor
        self.onCopy = onCopy
        self.onSave = onSave
        self.onCancel = onCancel
        self.onUndo = onUndo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 10

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for tool in CaptureAnnotationTool.allCases {
            let button = NSButton(title: tool.displayName, target: self, action: #selector(chooseTool(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setButtonType(.momentaryPushIn)
            button.state = tool == selectedTool ? .on : .off
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            stack.addArrangedSubview(button)
        }

        for (index, color) in CaptureAnnotationColor.palette.enumerated() {
            let button = NSButton(title: "●", target: self, action: #selector(chooseColor(_:)))
            button.tag = index
            button.bezelStyle = .inline
            button.controlSize = .small
            button.contentTintColor = NSColor(
                calibratedRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
            if color == selectedColor {
                button.state = .on
            }
            stack.addArrangedSubview(button)
        }

        summaryLabel.font = NSFont.systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(summaryLabel)
        updateAdjustmentSummary(tool: selectedTool, lineWidth: lineWidth, fontSize: fontSize, blurRadius: blurRadius)

        stack.addArrangedSubview(actionButton("Undo", #selector(undoShot)))
        stack.addArrangedSubview(actionButton("Copy", #selector(copyShot)))
        stack.addArrangedSubview(actionButton("Save", #selector(saveShot)))
        stack.addArrangedSubview(actionButton("Cancel", #selector(cancelShot)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateAdjustmentSummary(
        tool: CaptureAnnotationTool,
        lineWidth: CGFloat,
        fontSize: CGFloat,
        blurRadius: CGFloat
    ) {
        switch tool {
        case .mosaic:
            summaryLabel.stringValue = String(format: "Blur %.0f  (scroll)", blurRadius)
        case .text:
            summaryLabel.stringValue = String(format: "Text %.0fpt  (scroll)", fontSize)
        case .select:
            summaryLabel.stringValue = "Select / resize"
        default:
            summaryLabel.stringValue = String(format: "Size %.0f  (scroll)", lineWidth)
        }
    }

    private func actionButton(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    @objc private func chooseTool(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let tool = CaptureAnnotationTool(rawValue: raw) else { return }
        onTool(tool)
        for case let button as NSButton in subviews.flatMap({ ($0 as? NSStackView)?.arrangedSubviews ?? [] }) {
            if let id = button.identifier?.rawValue, CaptureAnnotationTool(rawValue: id) != nil {
                button.state = id == raw ? .on : .off
            }
        }
    }

    @objc private func chooseColor(_ sender: NSButton) {
        guard CaptureAnnotationColor.palette.indices.contains(sender.tag) else { return }
        onColor(CaptureAnnotationColor.palette[sender.tag])
    }

    @objc private func undoShot() { onUndo() }
    @objc private func copyShot() { onCopy() }
    @objc private func saveShot() { onSave() }
    @objc private func cancelShot() { onCancel() }
}
