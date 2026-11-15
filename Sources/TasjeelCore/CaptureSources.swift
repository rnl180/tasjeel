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

    public static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    public static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
}
