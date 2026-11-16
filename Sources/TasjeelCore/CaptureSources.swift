import AppKit
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

public struct DisplaySource: Identifiable, Hashable, @unchecked Sendable {
    public let display: SCDisplay
    public let name: String

    public var id: CGDirectDisplayID { display.displayID }
    public var detail: String { "\(display.width) × \(display.height)" }
}

public struct WindowSource: Identifiable, Hashable, @unchecked Sendable {
    public let window: SCWindow
    public let appName: String
    public let title: String

    public var id: CGWindowID { window.windowID }
    public var name: String { title.isEmpty || title == appName ? appName : "\(appName) — \(title)" }
}

public struct DeviceOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ShareableSources: @unchecked Sendable {
    public let displays: [DisplaySource]
    public let windows: [WindowSource]
    /// This app, so its own windows can be left out of display recordings.
    public let ownApplication: SCRunningApplication?
}

public enum CaptureSources {
    /// Displays and windows that can be recorded. Throws when Screen Recording
    /// permission has not been granted.
    public static func shareable() async throws -> ShareableSources {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier

        let names = await MainActor.run { () -> [CGDirectDisplayID: String] in
            var map: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    map[number.uint32Value] = screen.localizedName
                }
            }
            return map
        }
        let displays = content.displays.enumerated().map { index, display in
            DisplaySource(display: display, name: names[display.displayID] ?? "Display \(index + 1)")
        }

        let windows = content.windows.compactMap { window -> WindowSource? in
            guard window.windowLayer == 0, window.frame.width >= 160, window.frame.height >= 120,
                  let app = window.owningApplication, app.processID != pid,
                  !app.applicationName.isEmpty else { return nil }
            return WindowSource(window: window, appName: app.applicationName, title: window.title ?? "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return ShareableSources(displays: displays, windows: windows,
                                ownApplication: content.applications.first { $0.processID == pid })
    }

    public enum ScreenshotError: LocalizedError {
        case timedOut

        public var errorDescription: String? {
            "macOS did not hand over the picture of that window. It may be waiting for you to allow screen recording, or the window may have closed."
        }
    }

    /// A picture of one window as it is now, at full Retina resolution,
    /// without its shadow or the pointer. Gives up after `timeout` seconds:
    /// macOS sometimes never answers (a permission question left open, a
    /// window that closed meanwhile).
    public static func screenshot(of window: SCWindow, timeout: Double = 10) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(Int(filter.contentRect.width * scale), 2)
        configuration.height = max(Int(filter.contentRect.height * scale), 2)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        // The capture cannot be cancelled, so whichever finishes first wins
        // and the other is left to end by itself.
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                guard once.claim() else { return }
                if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? ScreenshotError.timedOut) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(throwing: ScreenshotError.timedOut) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false

        func claim() -> Bool {
            lock.withLock {
                if taken { return false }
                taken = true
                return true
            }
        }
    }

    /// The window a person means by `words` ("Safari", "simulator", part of
    /// a title): an app with exactly that name first, then any window whose
    /// name contains the words. Of several, the largest.
    public static func window(matching words: String, in windows: [WindowSource]) -> WindowSource? {
        let wanted = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        func largest(_ list: [WindowSource]) -> WindowSource? {
            list.max { $0.window.frame.width * $0.window.frame.height < $1.window.frame.width * $1.window.frame.height }
        }
        return largest(windows.filter { $0.appName.lowercased() == wanted })
            ?? largest(windows.filter { $0.name.lowercased().contains(wanted) })
    }

    public static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    public static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
}
