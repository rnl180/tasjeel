import CoreGraphics
import Foundation

// MARK: - Time

/// A half-open range of seconds, `start ..< end`.
public struct TimeSpan: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
    public func contains(_ t: Double) -> Bool { t >= start && t < end }
}

// MARK: - Recorded media

/// A mouse click captured while recording. `x`/`y` are normalised to the
/// captured area with the origin at the top-left corner.
public struct ClickEvent: Codable, Hashable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

public struct MediaInfo: Codable, Hashable, Sendable {
    public var file: String
    public var width: Int
    public var height: Int

    public init(file: String, width: Int, height: Int) {
        self.file = file
        self.width = width
        self.height = height
    }
}

public struct CameraInfo: Codable, Hashable, Sendable {
    public var file: String
    public var width: Int
    public var height: Int
    /// Seconds between the first screen frame and the first camera frame.
    public var offset: Double

    public init(file: String, width: Int, height: Int, offset: Double) {
        self.file = file
        self.width = width
        self.height = height
        self.offset = offset
    }
}

public enum AudioTrackKind: String, Codable, Sendable {
    case system
    case mic
}

// MARK: - Edit state

public enum AspectPreset: String, Codable, CaseIterable, Sendable {
    case source, wide, classic, square, vertical

    /// Width / height, or nil to follow the recording.
    public var ratio: Double? {
        switch self {
        case .source: return nil
        case .wide: return 16.0 / 9.0
        case .classic: return 4.0 / 3.0
        case .square: return 1
        case .vertical: return 9.0 / 16.0
        }
    }

    public var label: String {
        switch self {
        case .source: return "Auto"
        case .wide: return "16:9"
        case .classic: return "4:3"
        case .square: return "1:1"
        case .vertical: return "9:16"
        }
    }
}

public struct Backdrop: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case none, color, gradient }

    public var kind: Kind
    public var colorHex: String
    public var gradientID: String

    public init(kind: Kind = .none, colorHex: String = "#101116", gradientID: String = "dusk") {
        self.kind = kind
        self.colorHex = colorHex
        self.gradientID = gradientID
    }

    public static let none = Backdrop(kind: .none)
    public static func gradient(_ id: String) -> Backdrop { Backdrop(kind: .gradient, gradientID: id) }
    public static func color(_ hex: String) -> Backdrop { Backdrop(kind: .color, colorHex: hex) }
}

public enum CameraShape: String, Codable, CaseIterable, Sendable {
    case circle, rounded, wide

    public var label: String {
        switch self {
        case .circle: return "Circle"
        case .rounded: return "Square"
        case .wide: return "Wide"
        }
    }
}

public enum Corner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public struct CameraStyle: Codable, Hashable, Sendable {
    public var visible: Bool
    public var shape: CameraShape
    /// Height of the camera overlay as a fraction of the canvas' short side.
    public var size: Double
    public var corner: Corner
    public var mirrored: Bool

    public init(visible: Bool = true, shape: CameraShape = .circle, size: Double = 0.24,
                corner: Corner = .bottomRight, mirrored: Bool = true) {
        self.visible = visible
        self.shape = shape
        self.size = size
        self.corner = corner
        self.mirrored = mirrored
    }
}

/// A stretch of the recording that is magnified around a focus point.
/// Times are in source (un-cut) seconds; `x`/`y` are normalised, top-left origin.
public struct ZoomSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var scale: Double
    public var x: Double
    public var y: Double

    public init(id: UUID = UUID(), start: Double, end: Double, scale: Double = 1.8, x: Double = 0.5, y: Double = 0.5) {
        self.id = id
        self.start = start
        self.end = end
        self.scale = scale
        self.x = x
        self.y = y
    }
}

/// Everything the editor can change. Edits never touch the recorded files.
public struct EditState: Codable, Equatable, Sendable {
    /// The parts of the recording that are kept, in source seconds, sorted.
    public var segments: [TimeSpan]
    public var aspect: AspectPreset
    public var background: Backdrop
    /// Fraction of the canvas' short side.
    public var padding: Double
    /// Fraction of the canvas' short side.
    public var cornerRadius: Double
    /// 0 ... 1
    public var shadow: Double
    public var camera: CameraStyle
    public var zooms: [ZoomSegment]
    public var micVolume: Double
    public var systemVolume: Double

    public init(duration: Double) {
        segments = [TimeSpan(start: 0, end: duration)]
        aspect = .source
        background = .none
        padding = 0
        cornerRadius = 0
        shadow = 0.6
        camera = CameraStyle()
        zooms = []
        micVolume = 1
        systemVolume = 1
    }

    // Decoding tolerates missing keys so older project files keep opening.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = try c.decodeIfPresent([TimeSpan].self, forKey: .segments) ?? []
        aspect = try c.decodeIfPresent(AspectPreset.self, forKey: .aspect) ?? .source
        background = try c.decodeIfPresent(Backdrop.self, forKey: .background) ?? .none
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 0
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0.6
        camera = try c.decodeIfPresent(CameraStyle.self, forKey: .camera) ?? CameraStyle()
        zooms = try c.decodeIfPresent([ZoomSegment].self, forKey: .zooms) ?? []
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1
        systemVolume = try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 1
    }

    public var keptDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// The "Studio" look: wallpaper, padding, rounded corners.
    public mutating func applyStudioLook() {
        background = .gradient("dusk")
        padding = 0.06
        cornerRadius = 0.018
        shadow = 0.7
    }

    public mutating func applyPlainLook() {
        background = .none
        padding = 0
        cornerRadius = 0
    }
}

// MARK: - Recording

public struct Recording: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    /// Length of the raw recording in seconds.
    public var duration: Double
    /// What was captured, for display ("Built-in Display", "Safari — Docs").
    public var sourceName: String
    public var screen: MediaInfo
    public var camera: CameraInfo?
    /// Audio tracks inside the screen file, in track order.
    public var audioTracks: [AudioTrackKind]
    public var clicks: [ClickEvent]
    public var edit: EditState

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), duration: Double, sourceName: String,
                screen: MediaInfo, camera: CameraInfo? = nil, audioTracks: [AudioTrackKind] = [],
                clicks: [ClickEvent] = [], edit: EditState? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.sourceName = sourceName
        self.screen = screen
        self.camera = camera
        self.audioTracks = audioTracks
        self.clicks = clicks
        self.edit = edit ?? EditState(duration: duration)
    }

    public var screenSize: CGSize { CGSize(width: screen.width, height: screen.height) }
}
