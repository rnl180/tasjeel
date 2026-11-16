import AppKit
@preconcurrency import AVFoundation
import Foundation
import ImageIO

/// Something handed to the Studio to make a video from: a screenshot, a logo,
/// a recording.
public struct StudioMaterial: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case picture, video
    }

    /// Where it is, relative to the project folder: "materials/demo.mov".
    /// This is exactly what a storyboard writes to use it.
    public var file: String
    public var kind: Kind
    public var width: Int
    public var height: Int
    /// Length in seconds, for videos.
    public var seconds: Double?
    /// What is known about it beyond its picture: for a Tasjeel recording,
    /// its title and what is said in it.
    public var note: String?

    public var id: String { file }
    public var name: String { (file as NSString).lastPathComponent }

    public init(file: String, kind: Kind, width: Int, height: Int, seconds: Double? = nil, note: String? = nil) {
        self.file = file
        self.kind = kind
        self.width = width
        self.height = height
        self.seconds = seconds
        self.note = note
    }
}

/// One line of the conversation between the user and the model.
public struct StudioMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public var id: UUID
    public var role: Role
    public var text: String
    public var date: Date
    /// The storyboard as this answer left it, when the answer changed it.
    /// Kept so an earlier version can be brought back.
    public var storyboard: String?
    /// Problems that made Tasjeel turn down the storyboard in this answer.
    public var problems: [String]?

    public init(id: UUID = UUID(), role: Role, text: String, date: Date = Date(), storyboard: String? = nil, problems: [String]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.storyboard = storyboard
        self.problems = problems
    }
}

/// What a Studio project remembers besides its storyboard.
public struct StudioChat: Codable, Equatable, Sendable {
    public var messages: [StudioMessage] = []
    public var materials: [StudioMaterial] = []

    public init(messages: [StudioMessage] = [], materials: [StudioMaterial] = []) {
        self.messages = messages
        self.materials = materials
    }
}

/// A Studio project on disk:
///
///     ~/Movies/Tasjeel Studio/Launch video/
///         storyboard.json   the video, as written by the chat (or by hand)
///         chat.json         the conversation and the list of materials
///         materials/        the pictures and clips that were added
///         video/            the Remotion project built from the storyboard
///             out/          the rendered videos
public struct StudioWorkspace: Equatable, Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Two ways of writing the same folder are the same project.
    public static func == (a: StudioWorkspace, b: StudioWorkspace) -> Bool {
        a.directory.resolvingSymlinksInPath().path == b.directory.resolvingSymlinksInPath().path
    }

    public var name: String { directory.lastPathComponent }
    public var storyboardURL: URL { directory.appendingPathComponent("storyboard.json") }
    public var chatURL: URL { directory.appendingPathComponent("chat.json") }
    public var materialsURL: URL { directory.appendingPathComponent(Self.materialsFolder, isDirectory: true) }
    public var videoURL: URL { directory.appendingPathComponent("video", isDirectory: true) }

    public func renderedURL(_ format: String) -> URL { videoURL.appendingPathComponent("out/\(format).mp4") }

    static let materialsFolder = "materials"

    // MARK: - Finding and creating projects

    /// Where Studio projects are kept. `TASJEEL_STUDIO` points a development
    /// build somewhere else.
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["TASJEEL_STUDIO"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Tasjeel Studio", isDirectory: true)
    }

    /// Projects in `root`, the most recently changed first.
    public static func all(in root: URL = defaultRoot) -> [StudioWorkspace] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        func changed(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return folders
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("chat.json").path) }
            .map { (StudioWorkspace(directory: $0), max(changed($0.appendingPathComponent("chat.json")), changed($0.appendingPathComponent("storyboard.json")))) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Makes a new, empty project called "Video", "Video 2", and so on.
    public static func create(in root: URL = defaultRoot, named base: String = "Video") throws -> StudioWorkspace {
        var url = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        let workspace = StudioWorkspace(directory: url)
        try workspace.prepare()
        return workspace
    }

    /// Creates the folders and an empty chat, if they are not there yet.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: materialsURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: chatURL.path) { try save(StudioChat()) }
    }

    // MARK: - Chat and storyboard

    public func loadChat() -> StudioChat {
        guard let data = try? Data(contentsOf: chatURL) else { return StudioChat() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var chat = (try? decoder.decode(StudioChat.self, from: data)) ?? StudioChat()
        // A material whose file was deleted in the Finder is forgotten.
        chat.materials.removeAll { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.file).path) }
        return chat
    }

    public func save(_ chat: StudioChat) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(chat).write(to: chatURL, options: .atomic)
    }

    /// The storyboard file's text, or nil when there is none yet.
    public func loadStoryboard() -> String? {
        guard let text = try? String(contentsOf: storyboardURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    public func saveStoryboard(_ text: String) throws {
        try Data(text.utf8).write(to: storyboardURL, options: .atomic)
    }

    // MARK: - Materials

    public enum MaterialError: LocalizedError {
        case unsupported(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                return "“\(name)” is not a kind of file the Studio can use. Add pictures (.png, .jpg, .webp, .svg) or videos (.mp4, .mov, .m4v)."
            case .unreadable(let name):
                return "“\(name)” could not be opened."
            }
        }
    }

    /// Copies a file into the project and describes it. On the Mac's usual
    /// disk format the copy takes no extra space until one of them changes.
    public func addMaterial(from source: URL, named preferred: String? = nil, note: String? = nil) async throws -> StudioMaterial {
        let type = source.pathExtension.lowercased()
        let kind: StudioMaterial.Kind
        if Storyboard.imageTypes.contains(type) {
            kind = .picture
        } else if Storyboard.videoTypes.contains(type) {
            kind = .video
        } else {
            throw MaterialError.unsupported(source.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: materialsURL, withIntermediateDirectories: true)
        let name = Self.freeName(for: preferred ?? source.deletingPathExtension().lastPathComponent, type: type,
                                 fallback: kind == .picture ? "picture" : "clip", in: materialsURL)
        let destination = materialsURL.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)

        var material = StudioMaterial(file: "\(Self.materialsFolder)/\(name)", kind: kind, width: 0, height: 0, note: note)
        do {
            switch kind {
            case .picture:
                guard let size = Self.pictureSize(destination) else { throw MaterialError.unreadable(source.lastPathComponent) }
                material.width = Int(size.width)
                material.height = Int(size.height)
            case .video:
                let asset = AVURLAsset(url: destination)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw MaterialError.unreadable(source.lastPathComponent)
                }
                let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
                let upright = natural.applying(transform)
                material.width = Int(abs(upright.width))
                material.height = Int(abs(upright.height))
                material.seconds = (try await asset.load(.duration).seconds * 10).rounded(.down) / 10
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error is MaterialError ? error : MaterialError.unreadable(source.lastPathComponent)
        }
        return material
    }

    public func removeMaterial(_ material: StudioMaterial) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(material.file))
    }

    /// A plain file name the model can copy without mistakes: lower-case
    /// letters, digits and hyphens. "Résumé Screen (2).PNG" becomes
    /// "resume-screen-2.png".
    static func freeName(for title: String, type: String, fallback: String, in folder: URL) -> String {
        var base = RemotionProject.packageName(for: title)
        if base == "tasjeel-recording" { base = fallback }
        base = String(base.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var name = "\(base).\(type)"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(n).\(type)"
            n += 1
        }
        return name
    }

    static func pictureSize(_ url: URL) -> CGSize? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        // Drawings (.svg) have no pixels of their own.
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        return image.size
    }

    // MARK: - Pictures for the model

    /// What the model is shown of the materials: each picture, and a few
    /// frames of each video, made small. `labels` says in words what each
    /// picture is, in the same order, to go in the request.
    public struct Looks: Sendable {
        public var images: [ModelImage] = []
        public var labels: [String: [String]] = [:]

        public init() {}
    }

    /// At most `limit` pictures in all, so a request stays a sensible size.
    public func looks(at materials: [StudioMaterial], limit: Int = 12) async -> Looks {
        var looks = Looks()
        // Every material gets one picture before any video gets a second.
        var wanted: [(material: StudioMaterial, time: Double?)] = materials.map { ($0, $0.kind == .video ? ($0.seconds ?? 0) * 0.15 : nil) }
        for material in materials where material.kind == .video {
            let length = material.seconds ?? 0
            if length >= 8 { wanted.append((material, length * 0.5)) }
            if length >= 20 { wanted.append((material, length * 0.85)) }
        }
        var shown: [(file: String, time: Double?, image: ModelImage)] = []
        for item in wanted.prefix(limit) {
            let url = directory.appendingPathComponent(item.material.file)
            let picture: CGImage?
            if let time = item.time {
                picture = await Self.frame(of: url, at: time)
            } else {
                picture = Self.picture(url)
            }
            guard let picture, let data = Self.jpeg(picture) else { continue }
            shown.append((item.material.file, item.time, ModelImage(mediaType: "image/jpeg", data: data)))
        }
        // In the order of the materials, a video's frames in order of time.
        let order = Dictionary(uniqueKeysWithValues: materials.enumerated().map { ($1.file, $0) })
        shown.sort { (order[$0.file] ?? 0, $0.time ?? 0) < (order[$1.file] ?? 0, $1.time ?? 0) }
        for (index, item) in shown.enumerated() {
            looks.images.append(item.image)
            let label = item.time.map { "picture \(index + 1) (a frame at \(NotesFormat.stamp($0)))" } ?? "picture \(index + 1)"
            looks.labels[item.file, default: []].append(label)
        }
        return looks
    }

    public static let longSide: CGFloat = 1024

    /// A picture file made small. Also draws .svg files.
    public static func picture(_ url: URL, longSide: CGFloat = longSide) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: longSide]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        // Drawings (.svg): let AppKit draw them.
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(longSide / max(image.size.width, image.size.height), 4)
        var rect = CGRect(x: 0, y: 0, width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// One frame of a video, made small.
    public static func frame(of url: URL, at seconds: Double, longSide: CGFloat = longSide) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longSide, height: longSide)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// JPEG on white, since a see-through logo would otherwise turn black.
    static func jpeg(_ image: CGImage) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flat = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
