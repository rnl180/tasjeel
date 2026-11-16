@preconcurrency import AVFoundation
import Foundation

public enum ExportCodec: String, CaseIterable, Sendable {
    case h264, hevc

    public var label: String { self == .h264 ? "H.264 (plays everywhere)" : "HEVC (smaller file)" }
}

public struct ExportSettings: Equatable, Sendable {
    /// Long side in pixels; nil keeps the recording's resolution.
    public var longSide: Int?
    public var fps: Int
    public var codec: ExportCodec

    public init(longSide: Int? = nil, fps: Int = 30, codec: ExportCodec = .h264) {
        self.longSide = longSide
        self.fps = fps
        self.codec = codec
    }
}

public enum ExportError: LocalizedError {
    case cannotCreateSession
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateSession: return "This Mac could not start the export."
        case .failed(let reason): return "Export failed: \(reason)"
        }
    }
}

public enum Exporter {
    /// Renders the edit to an MP4. `progress` is called with 0 ... 1.
    public static func export(_ built: BuiltComposition, to url: URL, codec: ExportCodec,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let preset = codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw ExportError.cannotCreateSession
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true

        try? FileManager.default.removeItem(at: url)

        let monitor = Task {
            for await state in session.states(updateInterval: 0.15) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }

        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError { throw error }
            throw ExportError.failed(error.localizedDescription)
        }
        progress(1)
    }
}
