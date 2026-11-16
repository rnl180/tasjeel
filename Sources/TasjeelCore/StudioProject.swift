@preconcurrency import AVFoundation
import Foundation

/// Builds a Remotion project from a storyboard: checks the storyboard, brings
/// its pictures and clips into the project, and writes the code that plays
/// the scenes in wide, square and tall.
public enum StudioProject {
    public static let dataPath = "src/storyboard.json"
    static let mediaFolder = "public/media"

    public struct Summary: Sendable {
        public let directory: URL
        /// False when an existing project was refreshed.
        public let created: Bool
        public let title: String
        public let scenes: Int
        public let seconds: Double
        public let formats: [String]
    }

    public enum BuildError: LocalizedError {
        case notAProject(String)

        public var errorDescription: String? {
            switch self {
            case .notAProject(let name):
                return "“\(name)” already exists and is not a Tasjeel storyboard project. Choose a new name."
            }
        }
    }

    /// True when `directory` does not exist yet, is empty, or already holds a
    /// project built from a storyboard.
    public static func canBuild(in directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue else { return false }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(dataPath).path) { return true }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.allSatisfy { $0 == ".DS_Store" }
    }

    /// Builds (or refreshes) the project. `progress` receives 0 ... 1 and a
    /// short description.
    ///
    /// Refreshing replaces the storyboard data and the media and leaves the
    /// code alone, so changes made to how scenes look survive a rebuild.
    public static func build(storyboard url: URL, in directory: URL,
                             progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> Summary {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoryboardError.unreadable(error.localizedDescription)
        }
        progress(0, "Checking the storyboard…")
        var plan = try Storyboard.plan(from: data, baseDirectory: url.deletingLastPathComponent())
        guard canBuild(in: directory) else { throw BuildError.notAProject(directory.lastPathComponent) }

        // Clips are checked before anything is written, so a storyboard with
        // a problem leaves no half-built folder behind.
        var problems: [String] = []
        var assets: [AVURLAsset] = []
        for clip in plan.clips {
            let asset = AVURLAsset(url: clip.source)
            assets.append(asset)
            let number = clip.scene + 1
            guard let length = try? await asset.load(.duration).seconds,
                  let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
                problems.append("Scene \(number) (screen): \"\(clip.source.lastPathComponent)\" could not be opened as a video.")
                continue
            }
            if clip.start + clip.seconds > length + 0.05 {
                let from = clip.start > 0 ? " starting at \(format(clip.start)) s" : ""
                problems.append("Scene \(number) (screen): the scene lasts \(format(clip.seconds)) s\(from), but \"\(clip.source.lastPathComponent)\" is only \(format(length)) s long. Shorten \"seconds\" or lower \"start\".")
            }
        }
        guard problems.isEmpty else { throw StoryboardError.invalid(problems) }

        let fresh = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path)
        let media = directory.appendingPathComponent(mediaFolder)
        // Media from an earlier build may no longer be used.
        try? FileManager.default.removeItem(at: media)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        for copy in plan.copies {
            try FileManager.default.copyItem(at: copy.source, to: directory.appendingPathComponent("public/\(copy.path)"))
        }

        var scenes = plan.storyboard["scenes"] as? [[String: Any]] ?? []
        for (index, clip) in plan.clips.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(plan.clips.count, 1)) * 0.9, "Preparing clip \(index + 1) of \(plan.clips.count)…")
            let size = try await trim(assets[index], clip: clip, to: directory.appendingPathComponent("public/\(clip.path)"))
            scenes[clip.scene]["videoWidth"] = Int(size.width)
            scenes[clip.scene]["videoHeight"] = Int(size.height)
        }
        plan.storyboard["scenes"] = scenes

        progress(0.95, "Writing the project…")
        let title = plan.storyboard["title"] as? String ?? "Video"
        try RemotionProject.writeTemplate(RemotionTemplate.studioFiles, to: directory, title: title)
        let json = try JSONSerialization.data(withJSONObject: plan.storyboard, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: directory.appendingPathComponent(dataPath), options: .atomic)
        progress(1, "Done")

        return Summary(directory: directory, created: fresh, title: title, scenes: plan.sceneCount, seconds: plan.duration,
                       formats: plan.storyboard["formats"] as? [String] ?? [])
    }

    /// Cuts out the part of a clip a scene uses and saves it as H.264, which
    /// Remotion plays everywhere (Tasjeel's own recordings are HEVC, which it
    /// does not). Returns the picture size of the result.
    private static func trim(_ asset: AVURLAsset, clip: Storyboard.Plan.Clip, to url: URL) async throws -> CGSize {
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = natural.applying(transform)
        let source = CGSize(width: abs(upright.width), height: abs(upright.height))
        // A scene is at most 1920 pixels across, so more would only make the
        // project bigger and slower.
        let large = max(source.width, source.height) > 1920
        let preset = large ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw StoryboardError.invalid(["Scene \(clip.scene + 1) (screen): this Mac could not convert \"\(clip.source.lastPathComponent)\"."])
        }
        // A little extra at the end, so the last frame is never missing.
        session.timeRange = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600),
                                        duration: CMTime(seconds: clip.seconds + 0.25, preferredTimescale: 600))
        try? FileManager.default.removeItem(at: url)
        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            if error is CancellationError { throw error }
            throw StoryboardError.invalid(["Scene \(clip.scene + 1) (screen): \"\(clip.source.lastPathComponent)\" could not be converted (\(error.localizedDescription))."])
        }
        let written = AVURLAsset(url: url)
        guard let result = try await written.loadTracks(withMediaType: .video).first else { return source }
        let (size, turn) = try await result.load(.naturalSize, .preferredTransform)
        let fitted = size.applying(turn)
        return CGSize(width: abs(fitted.width), height: abs(fitted.height))
    }

    private static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}
