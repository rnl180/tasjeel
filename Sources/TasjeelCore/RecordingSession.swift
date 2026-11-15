import AppKit
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

public enum CaptureTarget: @unchecked Sendable {
    case display(SCDisplay)
    case window(SCWindow)
}

public struct RecordingOptions: @unchecked Sendable {
    public var target: CaptureTarget
    public var sourceName: String
    /// Left out of display recordings (the recorder's own controls).
    public var excluding: SCRunningApplication?
    public var systemAudio: Bool
    public var microphone: Bool
    public var microphoneID: String?
    public var fps: Int
    /// Recordings larger than this on their long side are scaled down.
    public var maxLongSide: Int

    public init(target: CaptureTarget, sourceName: String, excluding: SCRunningApplication? = nil, systemAudio: Bool = true,
                microphone: Bool = true, microphoneID: String? = nil, fps: Int = 30, maxLongSide: Int = 3840) {
        self.target = target
        self.sourceName = sourceName
        self.excluding = excluding
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.microphoneID = microphoneID
        self.fps = fps
        self.maxLongSide = maxLongSide
    }
}

/// Records mouse clicks so the editor can offer automatic zooms.
/// Mouse monitoring needs no extra permission (keyboard monitoring would).
@MainActor
final class ClickTracker {
    private var monitor: Any?
    private(set) var clicks: [(time: CMTime, point: CGPoint)] = []

    func start(clock: RecordingClock) {
        clicks = []
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard clock.offsetIfRunning() != nil else { return }
            // Cocoa measures from the bottom of the main display; flip to the
            // top-left origin that display and window frames use.
            let location = NSEvent.mouseLocation
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let point = CGPoint(x: location.x, y: mainHeight - location.y)
            let time = clock.adjustedNow()
            MainActor.assumeIsolated {
                self?.clicks.append((time, point))
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// One recording from start to finish: owns the folder, the screen recorder,
/// the camera file and the click log, and turns them into a `Recording`.
@MainActor
public final class RecordingSession {
    public let directory: URL
    public let options: RecordingOptions
    public let clock = RecordingClock()

    private let store: ProjectStore
    private let screen: ScreenRecorder
    private let camera: CameraController?
    private let clicks = ClickTracker()
    /// The captured area in global points, top-left origin.
    private let captureRect: CGRect
    private let createdAt = Date()
    private var beganAt: CMTime?

    public var onInterrupted: (@Sendable () -> Void)?

    public init(options: RecordingOptions, camera: CameraController?, store: ProjectStore) throws {
        self.options = options
        self.camera = camera
        self.store = store
        directory = try store.newRecordingDirectory()

        let filter: SCContentFilter
        switch options.target {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingApplications: options.excluding.map { [$0] } ?? [], exceptingWindows: [])
            captureRect = CGDisplayBounds(display.displayID)
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureRect = window.frame
        }

        // Record at the display's real pixel density, capped for huge screens.
        let scale = Double(filter.pointPixelScale)
        var width = Double(filter.contentRect.width) * scale
        var height = Double(filter.contentRect.height) * scale
        let long = max(width, height)
        if long > Double(options.maxLongSide) {
            let k = Double(options.maxLongSide) / long
            width *= k
            height *= k
        }
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

        screen = ScreenRecorder(
            config: .init(filter: filter, width: even(width), height: even(height), fps: options.fps,
                          systemAudio: options.systemAudio, microphone: options.microphone,
                          microphoneID: options.microphoneID,
                          outputURL: directory.appendingPathComponent(ProjectStore.screenName)),
            clock: clock
        )
    }

    /// Starts capturing without writing, so `begin()` is instant.
    public func arm() async throws {
        screen.onStreamStopped = { [weak self] _ in
            Task { @MainActor in self?.onInterrupted?() }
        }
        try await screen.arm()
    }

    public func begin() throws {
        try screen.begin()
        camera?.startRecording(to: directory.appendingPathComponent(ProjectStore.cameraName), clock: clock)
        clicks.start(clock: clock)
        beganAt = clock.adjustedNow()
    }

    public var isPaused: Bool { clock.isPaused }
    public func pause() { clock.pause() }
    public func resume() { clock.resume() }

    /// Seconds recorded so far, not counting pauses.
    public var elapsed: Double {
        guard let beganAt else { return 0 }
        return max(0, (clock.adjustedNow() - beganAt).seconds)
    }

    /// Stops everything and writes the project file.
    public func finish(title: String, cameraCorner: Corner = .bottomRight) async throws -> LibraryEntry {
        clicks.stop()
        let cameraResult = await camera?.stopRecording()
        let result: ScreenRecordingResult
        do {
            result = try await screen.finish()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let duration = result.duration
        let events: [ClickEvent] = clicks.clicks.compactMap { click in
            let t = (click.time - result.firstPTS).seconds
            let x = (click.point.x - captureRect.minX) / captureRect.width
            let y = (click.point.y - captureRect.minY) / captureRect.height
            guard t >= 0, t <= duration, (0 ... 1).contains(x), (0 ... 1).contains(y) else { return nil }
            return ClickEvent(t: t, x: x, y: y)
        }

        var cameraInfo: CameraInfo?
        if let cameraResult {
            cameraInfo = CameraInfo(file: ProjectStore.cameraName, width: cameraResult.width, height: cameraResult.height,
                                    offset: (cameraResult.firstPTS - result.firstPTS).seconds)
        }

        var recording = Recording(
            title: title,
            createdAt: createdAt,
            duration: duration,
            sourceName: options.sourceName,
            screen: MediaInfo(file: ProjectStore.screenName, width: result.width, height: result.height),
            camera: cameraInfo,
            audioTracks: result.audioTracks,
            clicks: events
        )
        recording.edit.camera.corner = cameraCorner
        try store.save(recording, in: directory)
        await ProjectStore.makeThumbnail(for: recording, in: directory)
        return LibraryEntry(recording: recording, directory: directory)
    }

    /// Stops and deletes the recording.
    public func cancel() async {
        clicks.stop()
        camera?.cancelRecording()
        await screen.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}
