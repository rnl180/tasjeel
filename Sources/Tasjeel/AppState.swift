import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import TasjeelCore
import UniformTypeIdentifiers

enum SourceKind: String {
    case display, window
}

enum RecordingPhase: Equatable {
    case idle
    case preparing
    case countdown(Int)
    case recording
    case paused
    case finishing

    var isActive: Bool { self != .idle }
    var isCapturing: Bool { self == .recording || self == .paused }
}

/// The recorder's settings and state, shared by the library window, the menu
/// bar item and the floating controls.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store = ProjectStore()
    let camera = CameraController()
    let overlays = OverlayController()
    private let defaults = UserDefaults.standard

    // Library
    @Published var items: [LibraryEntry] = []

    // What can be recorded
    @Published var displays: [DisplaySource] = []
    @Published var windows: [WindowSource] = []
    @Published var cameras: [DeviceOption] = []
    @Published var microphones: [DeviceOption] = []

    // Choices (remembered between launches). An empty ID means "off".
    @Published var sourceKind: SourceKind { didSet { defaults.set(sourceKind.rawValue, forKey: "sourceKind") } }
    @Published var displayID: CGDirectDisplayID = 0
    @Published var windowID: CGWindowID = 0
    @Published var cameraID: String { didSet { defaults.set(cameraID, forKey: "cameraID") } }
    @Published var microphoneID: String { didSet { defaults.set(microphoneID, forKey: "microphoneID") } }
    @Published var systemAudio: Bool { didSet { defaults.set(systemAudio, forKey: "systemAudio") } }
    @Published var fps: Int { didSet { defaults.set(fps, forKey: "fps") } }
    @Published var countdown: Bool { didSet { defaults.set(countdown, forKey: "countdown") } }

    // Recording
    @Published var phase = RecordingPhase.idle
    @Published var elapsed = 0.0
    @Published var hasScreenAccess = CGPreflightScreenCaptureAccess()
    @Published var alert: String?

    private var session: RecordingSession?
    private var timer: Timer?
    private var hiddenWindows: [NSWindow] = []

    private init() {
        defaults.register(defaults: ["systemAudio": true, "fps": 30, "countdown": true, "sourceKind": "display"])
        sourceKind = SourceKind(rawValue: defaults.string(forKey: "sourceKind") ?? "") ?? .display
        cameraID = defaults.string(forKey: "cameraID") ?? ""
        // First launch: use the default microphone, because a silent meeting
        // recording is worse than an unexpected one with sound.
        microphoneID = defaults.string(forKey: "microphoneID") ?? (AVCaptureDevice.default(for: .audio)?.uniqueID ?? "")
        systemAudio = defaults.bool(forKey: "systemAudio")
        fps = defaults.integer(forKey: "fps")
        countdown = defaults.bool(forKey: "countdown")

        reloadLibrary()
        refreshDevices()

        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hasScreenAccess = CGPreflightScreenCaptureAccess()
                if self.phase == .idle { Task { await self.refreshSources() } }
            }
        }
    }

    // MARK: - Library

    func reloadLibrary() {
        items = store.loadAll()
    }

    func open(_ item: LibraryEntry) {
        EditorWindows.shared.open(item)
    }

    func rename(_ item: LibraryEntry, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if EditorWindows.shared.rename(id: item.id, to: trimmed) {
            reloadLibrary()
            return
        }
        var recording = item.recording
        recording.title = trimmed
        try? store.save(recording, in: item.directory)
        reloadLibrary()
    }

    func trash(_ item: LibraryEntry) {
        EditorWindows.shared.close(id: item.id)
        do {
            try store.trash(item)
        } catch {
            alert = "Could not move the recording to the Trash: \(error.localizedDescription)"
        }
        reloadLibrary()
    }

    /// Lets the user pick a video file and adds a copy to the library.
    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video to edit in Tasjeel. The original file is not changed."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                do {
                    let entry = try await self.store.importVideo(at: url)
                    self.reloadLibrary()
                    self.open(entry)
                } catch {
                    self.alert = "That video could not be imported: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Builds a marketing video project from a storyboard file: choose the
    /// storyboard, choose where the project goes, and it opens in Finder.
    /// Opens the Studio, where a chat with an AI model writes the video.
    func openStudio() {
        StudioWindow.shared.open()
    }

    func buildFromStoryboard() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        open.allowsMultipleSelection = false
        open.message = "Choose a storyboard: a JSON file listing the scenes of your video."
        open.begin { response in
            guard response == .OK, let storyboard = open.url else { return }
            let save = NSSavePanel()
            save.title = "Save Video Project"
            save.nameFieldLabel = "Folder name:"
            save.nameFieldStringValue = storyboard.deletingPathExtension().lastPathComponent + " Video"
            save.directoryURL = storyboard.deletingLastPathComponent()
            save.canCreateDirectories = true
            save.begin { response in
                guard response == .OK, let folder = save.url else { return }
                Task { @MainActor in
                    let alert = NSAlert()
                    do {
                        let summary = try await StudioProject.build(storyboard: storyboard, in: folder)
                        let sizes = summary.formats.joined(separator: ", ")
                        alert.messageText = summary.created ? "The video project is ready" : "The video project was updated"
                        alert.informativeText = "\(summary.scenes) scenes, \(Format.clock(summary.seconds)) long, in \(sizes). Double-click Start in its folder to preview it, and Render to make the videos."
                        alert.addButton(withTitle: "Open Folder")
                        alert.addButton(withTitle: "Done")
                        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(folder) }
                    } catch {
                        alert.alertStyle = .warning
                        alert.messageText = "The video project could not be built"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
        }
    }

    func revealLibraryFolder() {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.root)
    }

    // MARK: - Sources and devices

    func refreshDevices() {
        cameras = CaptureSources.cameras().map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
        microphones = CaptureSources.microphones().map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
        if !cameraID.isEmpty, !cameras.contains(where: { $0.id == cameraID }) { cameraID = "" }
        if !microphoneID.isEmpty, !microphones.contains(where: { $0.id == microphoneID }) {
            microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? ""
        }
    }

    func refreshSources() async {
        hasScreenAccess = CGPreflightScreenCaptureAccess()
        guard hasScreenAccess, let sources = try? await CaptureSources.shareable() else { return }
        apply(sources)
    }

    private func apply(_ sources: ShareableSources) {
        displays = sources.displays
        windows = sources.windows
        if !displays.contains(where: { $0.id == displayID }) {
            displayID = displays.first { $0.id == CGMainDisplayID() }?.id ?? displays.first?.id ?? 0
        }
        if !windows.contains(where: { $0.id == windowID }) { windowID = windows.first?.id ?? 0 }
    }

    /// Asks macOS for Screen Recording permission and opens the right pane.
    func requestScreenAccess() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        hasScreenAccess = CGPreflightScreenCaptureAccess()
    }

    // MARK: - Recording

    /// The global shortcut and the menu bar both call this.
    func toggleRecording() {
        switch phase {
        case .idle: startRecording()
        case .recording, .paused: stopRecording()
        case .preparing, .countdown: cancelRecording()
        case .finishing: break
        }
    }

    func startRecording() {
        guard phase == .idle else { return }
        guard CGPreflightScreenCaptureAccess() else {
            hasScreenAccess = false
            requestScreenAccess()
            return
        }
        phase = .preparing
        Task { await start() }
    }

    private func start() async {
        do {
            // Ask for what is needed before anything is hidden or counted down.
            if !microphoneID.isEmpty, await !AVCaptureDevice.requestAccess(for: .audio) {
                throw StartError("Tasjeel is not allowed to use the microphone. Turn it on in System Settings › Privacy & Security › Microphone, or set Microphone to Off.")
            }
            if !cameraID.isEmpty, await !AVCaptureDevice.requestAccess(for: .video) {
                throw StartError("Tasjeel is not allowed to use the camera. Turn it on in System Settings › Privacy & Security › Camera, or set Camera to Off.")
            }

            let sources = try await CaptureSources.shareable()
            apply(sources)

            let target: CaptureTarget
            let name: String
            var screen = NSScreen.main
            switch sourceKind {
            case .display:
                guard let display = sources.displays.first(where: { $0.id == displayID }) else {
                    throw StartError("No display was found to record.")
                }
                target = .display(display.display)
                name = display.name
                screen = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
                } ?? screen
            case .window:
                guard let window = sources.windows.first(where: { $0.id == windowID }) else {
                    throw StartError("That window is no longer open. Pick another window to record.")
                }
                target = .window(window.window)
                name = window.name
            }

            let cameraDevice = cameraID.isEmpty ? nil : AVCaptureDevice(uniqueID: cameraID)
            let options = RecordingOptions(
                target: target, sourceName: name, excluding: sources.ownApplication, systemAudio: systemAudio,
                microphone: !microphoneID.isEmpty, microphoneID: microphoneID.isEmpty ? nil : microphoneID, fps: fps
            )
            let session = try RecordingSession(options: options, camera: cameraDevice == nil ? nil : camera, store: store)
            session.onInterrupted = {
                Task { @MainActor in AppState.shared.stopRecording() }
            }
            self.session = session

            hideWindows()
            overlays.showHUD(on: screen)
            if let cameraDevice {
                camera.setDevice(cameraDevice)
                overlays.showBubble(session: camera.session, on: screen)
            }

            try await session.arm()

            if countdown {
                for n in [3, 2, 1] {
                    guard self.session === session else { return }
                    phase = .countdown(n)
                    overlays.showCountdown(n, on: screen)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                overlays.hideCountdown()
            } else {
                // Give the camera a moment to deliver its first frame.
                try await Task.sleep(nanoseconds: cameraDevice == nil ? 250_000_000 : 900_000_000)
            }
            guard self.session === session else { return }

            try session.begin()
            elapsed = 0
            phase = .recording
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let session = self.session else { return }
                    self.elapsed = session.elapsed
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            let failed = session
            session = nil
            await failed?.cancel()
            endRecordingUI()
            alert = (error as? StartError)?.message ?? error.localizedDescription
            showLibrary()
        }
    }

    func togglePause() {
        guard let session else { return }
        if phase == .recording {
            session.pause()
            phase = .paused
        } else if phase == .paused {
            session.resume()
            phase = .recording
        }
    }

    func stopRecording() {
        guard phase.isCapturing, let session else { return }
        phase = .finishing
        let corner = overlays.bubbleCorner()
        Task {
            let result = await finish(session, corner: corner)
            endRecordingUI()
            switch result {
            case .success(let item):
                reloadLibrary()
                open(item)
            case .failure(let error):
                alert = error.localizedDescription
                showLibrary()
            }
        }
    }

    /// Finishes the recording without opening anything; used when quitting.
    func finishBeforeQuit() async {
        guard phase.isCapturing, let session else { return }
        phase = .finishing
        _ = await finish(session, corner: overlays.bubbleCorner())
        endRecordingUI()
    }

    private func finish(_ session: RecordingSession, corner: Corner) async -> Result<LibraryEntry, Error> {
        self.session = nil
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mm a"
        do {
            return .success(try await session.finish(title: "Recording \(formatter.string(from: Date()))", cameraCorner: corner))
        } catch {
            return .failure(error)
        }
    }

    func cancelRecording() {
        guard phase.isActive, phase != .finishing, let session else { return }
        self.session = nil
        phase = .finishing
        Task {
            await session.cancel()
            endRecordingUI()
            showLibrary()
        }
    }

    /// Asks before throwing a recording away.
    func confirmDiscard() {
        guard phase.isCapturing else {
            cancelRecording()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The \(Format.clock(elapsed)) recorded so far will be deleted."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { cancelRecording() }
    }

    private func endRecordingUI() {
        timer?.invalidate()
        timer = nil
        overlays.hideAll()
        camera.setDevice(nil)
        phase = .idle
        elapsed = 0
        for window in hiddenWindows { window.orderFront(nil) }
        hiddenWindows = []
    }

    /// Gets the app's own windows out of the way while recording.
    private func hideWindows() {
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        for window in hiddenWindows { window.orderOut(nil) }
    }

    func showLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue.contains("library") == true {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private struct StartError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
