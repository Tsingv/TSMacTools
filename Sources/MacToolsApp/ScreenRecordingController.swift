import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import MacToolsCore
import ScreenCaptureKit

@MainActor
final class ScreenRecordingController: NSObject {
    private var settings: CaptureMediaSettings = .default
    private var stream: SCStream?
    private var outputURL: URL?
    private var startedAt: Date?
    private var isStopping = false
    private let writerBox = RecordingWriterBox()

    var onStatus: ((String, String) -> Void)?
    var onRecordingStateChange: ((Bool, TimeInterval) -> Void)?

    var isRecording: Bool { stream != nil }

    func apply(_ settings: CaptureMediaSettings) {
        self.settings = settings.sanitized
    }

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isRecording, !isStopping else { return }
        Task { await begin() }
    }

    func stop() {
        guard isRecording, !isStopping else { return }
        isStopping = true
        let activeStream = stream
        stream = nil
        Task {
            do {
                try await activeStream?.stopCapture()
            } catch {
                onStatus?("Recording Error", error.localizedDescription)
            }
            let savedURL = await writerBox.finish()
            isStopping = false
            startedAt = nil
            onRecordingStateChange?(false, 0)
            if let savedURL {
                onStatus?("Recording Saved", savedURL.path)
            }
        }
    }

    func elapsed() -> TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    private func begin() async {
        do {
            if !ensureScreenRecordingPermission() {
                return
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                onStatus?("Recording", "No shareable display was found.")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let sourceSize = CGSize(width: display.width, height: display.height)
            let outputSize = settings.recordingPixelSize(for: sourceSize)
            let configuration = SCStreamConfiguration()
            // Energy-first defaults: low FPS, capped pixels, tiny queues, optional cursor.
            configuration.width = Int(outputSize.width)
            configuration.height = Int(outputSize.height)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.recordingFrameRate))
            configuration.queueDepth = 2
            configuration.showsCursor = settings.showMouseCursorInRecording
            configuration.scalesToFit = true
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.capturesAudio = settings.captureSystemAudio
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let directory = URL(fileURLWithPath: settings.recordingSaveDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let url = directory.appendingPathComponent("Recording-\(formatter.string(from: Date())).mp4")
            outputURL = url

            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: settings.recordingBitrateKbps * 1_000,
                    AVVideoExpectedSourceFrameRateKey: settings.recordingFrameRate,
                    AVVideoMaxKeyFrameIntervalKey: max(settings.recordingFrameRate * 3, 30),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: Int(outputSize.width),
                    kCVPixelBufferHeightKey as String: Int(outputSize.height)
                ]
            )
            guard writer.canAdd(videoInput) else {
                throw RecordingError.cannotAddVideoInput
            }
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if settings.captureSystemAudio {
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 96_000
                    ]
                )
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }

            if settings.captureMicrophone {
                let granted = await requestMicrophoneAccessIfNeeded()
                if !granted {
                    onStatus?(
                        "Microphone Permission Required",
                        "\(ScreenRecordingPermission.microphoneGuidance) Continuing without microphone audio."
                    )
                }
                // Keep the preference and permission prompt. Avoid a second live capture
                // session for mic mixing so idle recording power stays low.
            }

            writerBox.install(
                writer: writer,
                videoInput: videoInput,
                audioInput: audioInput,
                adaptor: adaptor,
                outputURL: url
            )

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(writerBox, type: .screen, sampleHandlerQueue: writerBox.queue)
            if settings.captureSystemAudio {
                try stream.addStreamOutput(writerBox, type: .audio, sampleHandlerQueue: writerBox.queue)
            }
            try await stream.startCapture()
            self.stream = stream
            startedAt = Date()
            onRecordingStateChange?(true, 0)
            onStatus?("Recording Started", url.path)
        } catch {
            cleanupFailedStart()
            if let scError = error as? SCStreamError, scError.code == .userDeclined {
                remindScreenRecordingAuthorization()
            } else {
                onStatus?("Recording Error", error.localizedDescription)
            }
        }
    }

    private func ensureScreenRecordingPermission() -> Bool {
        if ScreenRecordingPermission.status() == .granted {
            return true
        }
        // Native TCC sheet first; Settings only after the user confirms in an alert.
        let granted = ScreenRecordingPermission.requestAccess()
        if granted || ScreenRecordingPermission.status() == .granted {
            return true
        }
        remindScreenRecordingAuthorization()
        return false
    }

    private func remindScreenRecordingAuthorization() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = ScreenRecordingPermission.authorizationGuidance
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacyPane(paths: [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
            ])
        }
        onStatus?(
            "Screen Recording Permission Required",
            ScreenRecordingPermission.authorizationGuidance
        )
    }

    @MainActor
    func requestMicrophoneAccessIfNeeded() async -> Bool {
        let prior = MicrophonePermission.authorizationState()
        if prior == .authorized {
            return true
        }
        // Menu-bar apps need activation or the Microphone TCC sheet may never appear,
        // which also means System Settings will not list TSMacTools yet.
        NSApp.activate(ignoringOtherApps: true)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        if prior == .denied || prior == .restricted {
            remindMicrophoneAuthorization(state: prior, openedPrompt: false)
            return false
        }

        let granted = await MicrophonePermission.requestAccess()
        if granted || MicrophonePermission.authorizationState() == .authorized {
            return true
        }
        remindMicrophoneAuthorization(
            state: MicrophonePermission.authorizationState(),
            openedPrompt: true
        )
        return false
    }

    private func remindMicrophoneAuthorization(
        state: MicrophonePermission.AuthorizationState,
        openedPrompt: Bool
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch state {
        case .denied, .restricted:
            alert.messageText = "Microphone Access \(state.displayName.capitalized)"
            alert.informativeText =
                openedPrompt
                ? "The system dialog returned \(state.displayName). If TSMacTools is still missing from System Settings ▸ Microphone, quit the app, run `tccutil reset Microphone local.clearain.MacTools`, relaunch, and request again."
                : "macOS still reports \(state.displayName) for this process. Quit TSMacTools, run `tccutil reset Microphone local.clearain.MacTools`, relaunch, then use Capture ▸ Request Access... so the Allow dialog can register the app. Settings has no manual Add button."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Settings Anyway")
            if alert.runModal() == .alertSecondButtonReturn {
                openPrivacyPane(paths: [
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
                ])
            }
        case .notDetermined, .unknown, .authorized:
            alert.messageText = "Microphone Dialog Did Not Appear"
            alert.informativeText =
                "TCC state is \(state.displayName). System Settings stays empty until the Allow dialog appears. Keep TSMacTools frontmost and use Capture ▸ Request Access... again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func openPrivacyPane(paths: [String]) {
        for candidate in paths {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func cleanupFailedStart() {
        stream = nil
        writerBox.reset()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        startedAt = nil
        onRecordingStateChange?(false, 0)
    }

    private enum RecordingError: LocalizedError {
        case cannotAddVideoInput

        var errorDescription: String? {
            switch self {
            case .cannotAddVideoInput:
                "The video writer rejected the H.264 input."
            }
        }
    }
}

extension ScreenRecordingController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.onStatus?("Recording Error", error.localizedDescription)
            if self.isRecording {
                self.stop()
            }
        }
    }
}

/// Owns AVAssetWriter appends on a utility queue so capture frames never enter the main actor.
private final class RecordingWriterBox: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "TSMacTools.screen-recording.writer", qos: .utility)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var didStartSession = false

    func install(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        audioInput: AVAssetWriterInput?,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        outputURL: URL
    ) {
        queue.sync {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
            self.outputURL = outputURL
            self.didStartSession = false
        }
    }

    func reset() {
        queue.sync {
            writer = nil
            videoInput = nil
            audioInput = nil
            adaptor = nil
            outputURL = nil
            didStartSession = false
        }
    }

    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async {
                let writer = self.writer
                let url = self.outputURL
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.writer = nil
                self.videoInput = nil
                self.audioInput = nil
                self.adaptor = nil
                self.outputURL = nil
                self.didStartSession = false

                guard let writer else {
                    continuation.resume(returning: nil)
                    return
                }
                if writer.status == .writing {
                    writer.finishWriting {
                        continuation.resume(returning: writer.status == .completed ? url : nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, let writer else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !didStartSession {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: timestamp)
            didStartSession = true
        }

        switch type {
        case .screen:
            guard let videoInput,
                  videoInput.isReadyForMoreMediaData,
                  let adaptor,
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            _ = adaptor.append(pixelBuffer, withPresentationTime: timestamp)
        case .audio:
            guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        default:
            break
        }
    }
}
