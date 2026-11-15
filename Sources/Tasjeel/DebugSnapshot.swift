import AppKit
import AVFoundation
import TasjeelCore

/// Development aid: when `TASJEEL_SNAPSHOT` names a folder, the app writes
/// pictures of its own windows there shortly after launch and then quits.
/// Set `TASJEEL_SNAPSHOT_EDITOR=look,camera,zoom,audio` (any subset) to also
/// open the newest recording in the editor and capture each of those tabs.
/// Set `TASJEEL_SNAPSHOT_RECORD=<seconds>` to make a short recording through
/// the same path as the Start Recording button (add `TASJEEL_SNAPSHOT_CAMERA=1`
/// to include the first camera). It never takes keyboard focus, so it can run
/// while the Mac is in use.
@MainActor
enum DebugSnapshot {
    static var isActive: Bool {
        !(ProcessInfo.processInfo.environment["TASJEEL_SNAPSHOT"] ?? "").isEmpty
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard isActive, let folder = env["TASJEEL_SNAPSHOT"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            write(windowMatching: "library", to: directory.appendingPathComponent("library.png"))

            if let seconds = env["TASJEEL_SNAPSHOT_RECORD"].flatMap(Double.init) {
                await record(seconds: seconds, camera: env["TASJEEL_SNAPSHOT_CAMERA"] != nil, into: directory)
            }

            let tabs = (env["TASJEEL_SNAPSHOT_EDITOR"] ?? "").split(separator: ",").map(String.init)
            if !tabs.isEmpty, let entry = AppState.shared.items.first {
                AppState.shared.open(entry)
                guard let model = EditorWindows.shared.model(for: entry.id) else { return }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let seconds = env["TASJEEL_SNAPSHOT_TIME"].flatMap(Double.init) { model.seek(toSource: seconds) }
                for tab in tabs {
                    model.tab = EditorModel.Tab(rawValue: tab.capitalized) ?? .look
                    if tab == "zoom", let zoom = model.edit.zooms.first { model.selection = .zoom(zoom.id) }
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    write(windowMatching: "editor", to: directory.appendingPathComponent("editor-\(tab).png"))
                }
                // The video preview is drawn by the system outside the view
                // tree, so report its state and render the same frame separately.
                let item = model.player.currentItem
                let surface = NSApp.windows.compactMap { $0.contentView.flatMap(findPlayer) }.first
                print("preview: item=\(item?.status.rawValue ?? -1) error=\(item?.error?.localizedDescription ?? "none") readyForDisplay=\(surface?.playerLayer.isReadyForDisplay ?? false) playing=\(model.isPlaying) time=\(model.currentTime)")
                if let frame = await model.renderedFrame() {
                    try? NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("frame.png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// Drives a real recording: countdown, floating controls, pause, stop.
    private static func record(seconds: Double, camera: Bool, into directory: URL) async {
        let app = AppState.shared
        let previousCamera = app.cameraID
        let previousCountdown = app.countdown
        if camera { app.cameraID = app.cameras.first?.id ?? "" }
        app.countdown = true
        defer {
            app.cameraID = previousCamera
            app.countdown = previousCountdown
        }

        app.startRecording()
        var waited = 0.0
        while app.phase != .recording, app.phase != .idle, waited < 20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        guard app.phase == .recording else {
            print("record: did not start (phase=\(app.phase), alert=\(app.alert ?? "none"))")
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1_000_000_000))
        app.togglePause()
        try? await Task.sleep(nanoseconds: 700_000_000)
        for panel in NSApp.windows where panel is NSPanel && panel.isVisible {
            guard let view = panel.contentView, view.bounds.width > 200, view.bounds.height < 80,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("hud.png"))
        }
        let panels = NSApp.windows.filter { $0 is NSPanel && $0.isVisible }.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }
        app.togglePause()
        try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1_000_000_000))
        let elapsed = app.elapsed
        app.stopRecording()
        waited = 0
        while app.phase != .idle, waited < 20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        if let newest = app.items.first {
            let r = newest.recording
            print("record: ok duration=\(String(format: "%.2f", r.duration)) elapsed=\(String(format: "%.2f", elapsed)) screen=\(r.screen.width)x\(r.screen.height) audio=\(r.audioTracks.map(\.rawValue)) camera=\(r.camera.map { "\($0.width)x\($0.height) offset=\(String(format: "%.3f", $0.offset))" } ?? "none") corner=\(r.edit.camera.corner.rawValue) panels=\(panels) alert=\(app.alert ?? "none")")
        } else {
            print("record: nothing saved (alert=\(app.alert ?? "none"))")
        }
    }

    private static func findPlayer(in view: NSView) -> PlayerNSView? {
        if let player = view as? PlayerNSView { return player }
        for sub in view.subviews {
            if let found = findPlayer(in: sub) { return found }
        }
        return nil
    }

    private static func write(windowMatching name: String, to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains(name) == true }),
              let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
