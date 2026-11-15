@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A recording together with the folder it lives in.
public struct LibraryEntry: Identifiable, Equatable, Sendable {
    public var recording: Recording
    public let directory: URL

    public var id: UUID { recording.id }
    public var thumbnailURL: URL { directory.appendingPathComponent(ProjectStore.thumbnailName) }
    public var screenURL: URL { directory.appendingPathComponent(recording.screen.file) }

    public init(recording: Recording, directory: URL) {
        self.recording = recording
        self.directory = directory
    }

    /// Bytes on disk for the whole recording folder.
    public var sizeOnDisk: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// The library on disk: one folder per recording inside ~/Movies/Tasjeel.
///
///     ~/Movies/Tasjeel/2026-11-16 09.30.12/
///         project.json   metadata and the edit (cuts, look, zooms)
///         screen.mov     screen + system audio + microphone
///         camera.mov     webcam, when one was recorded
///         thumb.jpg
public final class ProjectStore: @unchecked Sendable {
    public static let projectName = "project.json"
    public static let screenName = "screen.mov"
    public static let cameraName = "camera.mov"
    public static let thumbnailName = "thumb.jpg"

    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let override = ProcessInfo.processInfo.environment["TASJEEL_LIBRARY"], !override.isEmpty {
            // Lets a development build use a scratch library instead of the real one.
            self.root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
            self.root = movies.appendingPathComponent("Tasjeel", isDirectory: true)
        }
    }

    public func newRecordingDirectory(date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var url = root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(formatter.string(from: date)) (\(n))", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func loadAll() -> [LibraryEntry] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var items: [LibraryEntry] = []
        for folder in folders {
            let file = folder.appendingPathComponent(Self.projectName)
            guard let data = try? Data(contentsOf: file),
                  let recording = try? decoder.decode(Recording.self, from: data) else { continue }
            items.append(LibraryEntry(recording: recording, directory: folder))
        }
        return items.sorted { $0.recording.createdAt > $1.recording.createdAt }
    }

    public func save(_ recording: Recording, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: directory.appendingPathComponent(Self.projectName), options: .atomic)
    }

    /// Adds an existing video file to the library so it can be edited like a
    /// recording. The file is copied; the original is left alone.
    public func importVideo(at source: URL, camera: URL? = nil, title: String? = nil) async throws -> LibraryEntry {
        let directory = try newRecordingDirectory()
        do {
            let screenName = "screen." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased())
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(screenName))
            let asset = AVURLAsset(url: directory.appendingPathComponent(screenName))
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw BuildError.missingVideo }
            let size = try await video.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            let audioCount = try await asset.loadTracks(withMediaType: .audio).count

            var cameraInfo: CameraInfo?
            if let camera {
                let cameraName = "camera." + (camera.pathExtension.isEmpty ? "mov" : camera.pathExtension.lowercased())
                try FileManager.default.copyItem(at: camera, to: directory.appendingPathComponent(cameraName))
                let cameraAsset = AVURLAsset(url: directory.appendingPathComponent(cameraName))
                if let track = try await cameraAsset.loadTracks(withMediaType: .video).first {
                    let cameraSize = try await track.load(.naturalSize)
                    cameraInfo = CameraInfo(file: cameraName, width: Int(cameraSize.width), height: Int(cameraSize.height), offset: 0)
                }
            }

            let recording = Recording(
                title: title ?? source.deletingPathExtension().lastPathComponent,
                duration: duration,
                sourceName: "Imported video",
                screen: MediaInfo(file: screenName, width: Int(size.width), height: Int(size.height)),
                camera: cameraInfo,
                audioTracks: Array(repeating: .system, count: audioCount)
            )
            try save(recording, in: directory)
            await Self.makeThumbnail(for: recording, in: directory)
            return LibraryEntry(recording: recording, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Moves the recording's folder to the Trash, so it can be put back.
    public func trash(_ item: LibraryEntry) throws {
        try FileManager.default.trashItem(at: item.directory, resultingItemURL: nil)
    }

    /// Writes `thumb.jpg` from a frame near the start of the screen recording.
    public static func makeThumbnail(for recording: Recording, in directory: URL) async {
        let asset = AVURLAsset(url: directory.appendingPathComponent(recording.screen.file))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let at = CMTime(seconds: min(1.0, recording.duration / 2), preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: at) else { return }
        let url = directory.appendingPathComponent(thumbnailName)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
