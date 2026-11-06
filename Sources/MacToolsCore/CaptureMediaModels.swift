import CoreGraphics
import Foundation

/// Screenshot annotation and screen-recording preferences.
///
/// Recording defaults favor energy efficiency: modest frame rate, capped resolution,
/// hardware H.264, shallow stream queues, and one-hertz status updates.
public struct CaptureMediaSettings: Equatable, Codable, Sendable {
    public enum RecordingResolution: String, Codable, CaseIterable, Sendable {
        /// Cap the longest edge near 1280 px.
        case energy
        /// Cap the longest edge near 1920 px.
        case balanced
        /// Keep the display's native pixel size.
        case native

        public var displayName: String {
            switch self {
            case .energy: "Energy (<=1280)"
            case .balanced: "Balanced (<=1920)"
            case .native: "Native"
            }
        }

        public var maxLongEdge: Int? {
            switch self {
            case .energy: 1280
            case .balanced: 1920
            case .native: nil
            }
        }
    }

    public var screenshotSaveDirectory: String
    public var recordingSaveDirectory: String
    public var copyScreenshotToClipboard: Bool
    public var saveScreenshotToDisk: Bool
    public var recordingResolution: RecordingResolution
    public var recordingFrameRate: Int
    public var recordingBitrateKbps: Int
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var showMouseCursorInRecording: Bool

    public init(
        screenshotSaveDirectory: String = CaptureMediaSettings.defaultScreenshotDirectory,
        recordingSaveDirectory: String = CaptureMediaSettings.defaultRecordingDirectory,
        copyScreenshotToClipboard: Bool = true,
        saveScreenshotToDisk: Bool = true,
        recordingResolution: RecordingResolution = .energy,
        recordingFrameRate: Int = 15,
        recordingBitrateKbps: Int = 2_500,
        captureSystemAudio: Bool = true,
        captureMicrophone: Bool = false,
        showMouseCursorInRecording: Bool = true
    ) {
        self.screenshotSaveDirectory = screenshotSaveDirectory
        self.recordingSaveDirectory = recordingSaveDirectory
        self.copyScreenshotToClipboard = copyScreenshotToClipboard
        self.saveScreenshotToDisk = saveScreenshotToDisk
        self.recordingResolution = recordingResolution
        self.recordingFrameRate = recordingFrameRate
        self.recordingBitrateKbps = recordingBitrateKbps
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.showMouseCursorInRecording = showMouseCursorInRecording
    }

    public static let `default` = CaptureMediaSettings()

    public static var defaultScreenshotDirectory: String {
        NSHomeDirectory() + "/Pictures/TSMacTools/Screenshots"
    }

    public static var defaultRecordingDirectory: String {
        NSHomeDirectory() + "/Movies/TSMacTools/Recordings"
    }

    public static let frameRateRange = 8 ... 30
    public static let bitrateRange = 800 ... 20_000

    public var sanitized: CaptureMediaSettings {
        var copy = self
        copy.recordingFrameRate = min(
            max(recordingFrameRate, Self.frameRateRange.lowerBound),
            Self.frameRateRange.upperBound
        )
        copy.recordingBitrateKbps = min(
            max(recordingBitrateKbps, Self.bitrateRange.lowerBound),
            Self.bitrateRange.upperBound
        )
        let screenshotTrimmed = screenshotSaveDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordingTrimmed = recordingSaveDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let screenshot = (screenshotTrimmed as NSString).expandingTildeInPath
        let recording = (recordingTrimmed as NSString).expandingTildeInPath
        copy.screenshotSaveDirectory = screenshot.isEmpty ? Self.defaultScreenshotDirectory : screenshot
        copy.recordingSaveDirectory = recording.isEmpty ? Self.defaultRecordingDirectory : recording
        return copy
    }

    public func recordingPixelSize(for source: CGSize) -> CGSize {
        let width = max(source.width, 1)
        let height = max(source.height, 1)
        guard let maxEdge = recordingResolution.maxLongEdge else {
            return CGSize(width: width.rounded(), height: height.rounded())
        }
        let longest = max(width, height)
        guard longest > CGFloat(maxEdge) else {
            return CGSize(width: width.rounded(), height: height.rounded())
        }
        let scale = CGFloat(maxEdge) / longest
        // Even dimensions keep hardware encoders happier and avoid odd-size padding work.
        func evenFloor(_ value: CGFloat) -> CGFloat {
            max(2, (value / 2).rounded(.down) * 2)
        }
        return CGSize(
            width: evenFloor(width * scale),
            height: evenFloor(height * scale)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case screenshotSaveDirectory
        case recordingSaveDirectory
        case copyScreenshotToClipboard
        case saveScreenshotToDisk
        case recordingResolution
        case recordingFrameRate
        case recordingBitrateKbps
        case captureSystemAudio
        case captureMicrophone
        case showMouseCursorInRecording
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screenshotSaveDirectory = try container.decodeIfPresent(String.self, forKey: .screenshotSaveDirectory)
            ?? Self.defaultScreenshotDirectory
        recordingSaveDirectory = try container.decodeIfPresent(String.self, forKey: .recordingSaveDirectory)
            ?? Self.defaultRecordingDirectory
        copyScreenshotToClipboard = try container.decodeIfPresent(Bool.self, forKey: .copyScreenshotToClipboard) ?? true
        saveScreenshotToDisk = try container.decodeIfPresent(Bool.self, forKey: .saveScreenshotToDisk) ?? true
        recordingResolution = try container.decodeIfPresent(RecordingResolution.self, forKey: .recordingResolution) ?? .energy
        recordingFrameRate = try container.decodeIfPresent(Int.self, forKey: .recordingFrameRate) ?? 15
        recordingBitrateKbps = try container.decodeIfPresent(Int.self, forKey: .recordingBitrateKbps) ?? 2_500
        captureSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? true
        captureMicrophone = try container.decodeIfPresent(Bool.self, forKey: .captureMicrophone) ?? false
        showMouseCursorInRecording = try container.decodeIfPresent(Bool.self, forKey: .showMouseCursorInRecording) ?? true
        self = sanitized
    }
}

public enum CaptureAnnotationTool: String, Codable, CaseIterable, Sendable {
    case select
    case arrow
    case rectangle
    case ellipse
    case mosaic
    case sequence
    case text

    public var displayName: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rectangle: "Box"
        case .ellipse: "Circle"
        case .mosaic: "Mosaic"
        case .sequence: "Sequence"
        case .text: "Text"
        }
    }
}

public struct CaptureAnnotationColor: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = CaptureAnnotationColor(red: 1, green: 0.23, blue: 0.19)
    public static let orange = CaptureAnnotationColor(red: 1, green: 0.58, blue: 0)
    public static let yellow = CaptureAnnotationColor(red: 1, green: 0.8, blue: 0)
    public static let green = CaptureAnnotationColor(red: 0.2, green: 0.78, blue: 0.35)
    public static let blue = CaptureAnnotationColor(red: 0.04, green: 0.52, blue: 1)
    public static let purple = CaptureAnnotationColor(red: 0.69, green: 0.32, blue: 0.87)
    public static let white = CaptureAnnotationColor(red: 1, green: 1, blue: 1)
    public static let black = CaptureAnnotationColor(red: 0.1, green: 0.1, blue: 0.1)

    public static let palette: [CaptureAnnotationColor] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black
    ]
}

public struct CaptureAnnotationItem: Equatable, Sendable {
    public var id: UUID
    public var tool: CaptureAnnotationTool
    public var color: CaptureAnnotationColor
    public var start: CGPoint
    public var end: CGPoint
    public var text: String
    public var sequenceNumber: Int
    /// Stroke width for arrow/box/circle/sequence ring preview sizing.
    public var lineWidth: CGFloat
    /// Point size for text annotations.
    public var fontSize: CGFloat
    /// Gaussian blur radius for mosaic annotations.
    public var blurRadius: CGFloat

    public static let lineWidthRange: ClosedRange<CGFloat> = 2...24
    public static let fontSizeRange: ClosedRange<CGFloat> = 12...64
    public static let blurRadiusRange: ClosedRange<CGFloat> = 2...48

    public init(
        id: UUID = UUID(),
        tool: CaptureAnnotationTool,
        color: CaptureAnnotationColor,
        start: CGPoint,
        end: CGPoint,
        text: String = "",
        sequenceNumber: Int = 0,
        lineWidth: CGFloat = 3,
        fontSize: CGFloat = 16,
        blurRadius: CGFloat = 14
    ) {
        self.id = id
        self.tool = tool
        self.color = color
        self.start = start
        self.end = end
        self.text = text
        self.sequenceNumber = sequenceNumber
        self.lineWidth = min(max(lineWidth, Self.lineWidthRange.lowerBound), Self.lineWidthRange.upperBound)
        self.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.blurRadius = min(max(blurRadius, Self.blurRadiusRange.lowerBound), Self.blurRadiusRange.upperBound)
    }

    public var bounds: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

public enum CaptureAnnotationGeometry {
    public static func normalizedSelection(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = max(1, min(result.width, bounds.width))
        result.size.height = max(1, min(result.height, bounds.height))
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }

    public static func handle(
        at point: CGPoint,
        in rect: CGRect,
        tolerance: CGFloat = 8
    ) -> SelectionHandle? {
        for candidate in SelectionHandle.allCases where candidate != .move {
            if candidate.rect(in: rect).insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return candidate
            }
        }
        if rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
            return .move
        }
        return nil
    }

    public enum SelectionHandle: CaseIterable {
        case move
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left

        public func rect(in selection: CGRect) -> CGRect {
            let size: CGFloat = 8
            let midX = selection.midX - size / 2
            let midY = selection.midY - size / 2
            switch self {
            case .move:
                return selection
            case .topLeft:
                return CGRect(x: selection.minX - size / 2, y: selection.maxY - size / 2, width: size, height: size)
            case .top:
                return CGRect(x: midX, y: selection.maxY - size / 2, width: size, height: size)
            case .topRight:
                return CGRect(x: selection.maxX - size / 2, y: selection.maxY - size / 2, width: size, height: size)
            case .right:
                return CGRect(x: selection.maxX - size / 2, y: midY, width: size, height: size)
            case .bottomRight:
                return CGRect(x: selection.maxX - size / 2, y: selection.minY - size / 2, width: size, height: size)
            case .bottom:
                return CGRect(x: midX, y: selection.minY - size / 2, width: size, height: size)
            case .bottomLeft:
                return CGRect(x: selection.minX - size / 2, y: selection.minY - size / 2, width: size, height: size)
            case .left:
                return CGRect(x: selection.minX - size / 2, y: midY, width: size, height: size)
            }
        }

        public func applying(delta: CGPoint, to rect: CGRect) -> CGRect {
            var result = rect
            switch self {
            case .move:
                result.origin.x += delta.x
                result.origin.y += delta.y
            case .topLeft:
                result.origin.x += delta.x
                result.size.width -= delta.x
                result.size.height += delta.y
            case .top:
                result.size.height += delta.y
            case .topRight:
                result.size.width += delta.x
                result.size.height += delta.y
            case .right:
                result.size.width += delta.x
            case .bottomRight:
                result.origin.y += delta.y
                result.size.width += delta.x
                result.size.height -= delta.y
            case .bottom:
                result.origin.y += delta.y
                result.size.height -= delta.y
            case .bottomLeft:
                result.origin.x += delta.x
                result.origin.y += delta.y
                result.size.width -= delta.x
                result.size.height -= delta.y
            case .left:
                result.origin.x += delta.x
                result.size.width -= delta.x
            }
            if result.width < 8 {
                result.size.width = 8
            }
            if result.height < 8 {
                result.size.height = 8
            }
            return result
        }
    }
}
