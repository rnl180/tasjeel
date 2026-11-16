import CoreGraphics
import Foundation
import ImageIO

/// What Tasjeel remembers about one of the user's projects (a product, an
/// app, a business), so that no video has to start by explaining it again.
///
/// It is kept as `project.json` in the project's folder and written out as
/// `PROJECT.md`, a brief any AI agent can read.
public struct ProjectMemory: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Software with screens to show: a web app, a phone app, a Mac app.
        case app
        case other
    }

    /// Something learned in a chat or told to Tasjeel by an AI agent.
    public struct Learned: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var text: String
        public var date: Date

        public init(id: UUID = UUID(), text: String, date: Date = Date()) {
            self.id = id
            self.text = text
            self.date = date
        }
    }

    /// For app projects: how to find the app on this Mac and get around it.
    public struct App: Codable, Equatable, Sendable {
        /// "Web", "iPhone", "Android", "Mac": any that apply.
        public var platforms: [String] = []
        /// The app's name, or part of its window's title, as it appears on
        /// this Mac (for a phone app, "Simulator"). Used to take screenshots.
        public var window = ""
        public var address = ""
        /// How to reach the screens worth showing.
        public var guide = ""

        public init(platforms: [String] = [], window: String = "", address: String = "", guide: String = "") {
            self.platforms = platforms
            self.window = window
            self.address = address
            self.guide = guide
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            platforms = try values.decodeIfPresent([String].self, forKey: .platforms) ?? []
            window = try values.decodeIfPresent(String.self, forKey: .window) ?? ""
            address = try values.decodeIfPresent(String.self, forKey: .address) ?? ""
            guide = try values.decodeIfPresent(String.self, forKey: .guide) ?? ""
        }
    }

    public static let platforms = ["Web", "iPhone", "Android", "Mac"]

    public var name: String
    public var kind: Kind
    /// What it is, in a sentence or two.
    public var summary: String
    public var audience: String
    /// How it talks: "plain and confident", "playful", and what to avoid.
    public var voice: String
    public var features: [String]
    /// Figures and customers' words that are true and may be shown.
    public var facts: [String]
    public var links: [String]
    /// Colours written like "#8F7CFF"; empty when not chosen.
    public var accent: String
    public var background: String
    public var text: String
    /// The logo, as one of the project's files ("assets/logo.svg").
    public var logo: String
    public var app: App
    public var notes: String
    public var learned: [Learned]

    public init(name: String, kind: Kind = .app, summary: String = "", audience: String = "", voice: String = "",
                features: [String] = [], facts: [String] = [], links: [String] = [], accent: String = "", background: String = "",
                text: String = "", logo: String = "", app: App = App(), notes: String = "", learned: [Learned] = []) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.audience = audience
        self.voice = voice
        self.features = features
        self.facts = facts
        self.links = links
        self.accent = accent
        self.background = background
        self.text = text
        self.logo = logo
        self.app = app
        self.notes = notes
        self.learned = learned
    }

    /// Reads files written by other versions: anything missing is empty.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try values.decodeIfPresent(String.self, forKey: key) ?? "" }
        func list(_ key: CodingKeys) throws -> [String] { try values.decodeIfPresent([String].self, forKey: key) ?? [] }
        name = try text(.name)
        kind = (try? values.decodeIfPresent(Kind.self, forKey: .kind)) ?? .other
        summary = try text(.summary)
        audience = try text(.audience)
        voice = try text(.voice)
        features = try list(.features)
        facts = try list(.facts)
        links = try list(.links)
        accent = try text(.accent)
        background = try text(.background)
        self.text = try text(.text)
        logo = try text(.logo)
        app = try values.decodeIfPresent(App.self, forKey: .app) ?? App()
        notes = try text(.notes)
        learned = try values.decodeIfPresent([Learned].self, forKey: .learned) ?? []
    }

    /// True when nothing but the name has been filled in.
    public var isEmpty: Bool {
        var blank = ProjectMemory(name: name, kind: kind)
        blank.app.platforms = app.platforms
        return self == blank
    }

    /// Adds facts that are not already there (compared without regard to
    /// case or punctuation at the ends). Returns the ones that were new.
    @discardableResult
    public mutating func remember(_ facts: [String], date: Date = Date()) -> [String] {
        func key(_ text: String) -> String {
            text.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        }
        var known = Set((learned.map(\.text) + self.facts + features).map(key))
        var added: [String] = []
        for fact in facts {
            let clean = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 3, clean.count <= 400, known.insert(key(clean)).inserted else { continue }
            learned.append(Learned(text: clean, date: date))
            added.append(clean)
        }
        return added
    }
}

/// A project on disk:
///
///     ~/Movies/Tasjeel Studio/Orbit/
///         PROJECT.md      the brief: what is remembered, written for an AI agent
///         project.json    the same memory, as Tasjeel keeps it
///         assets/         logo, screenshots, recordings: shared by every video
///         assets.json     what each of those files is
///         videos/
///             Launch video/   one Studio video (see StudioWorkspace)
public struct ProjectFolder: Equatable, Identifiable, Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func == (a: ProjectFolder, b: ProjectFolder) -> Bool {
        a.directory.resolvingSymlinksInPath().path == b.directory.resolvingSymlinksInPath().path
    }

    public var id: String { directory.resolvingSymlinksInPath().path }
    public var folderName: String { directory.lastPathComponent }
    public var memoryURL: URL { directory.appendingPathComponent("project.json") }
    public var briefURL: URL { directory.appendingPathComponent("PROJECT.md") }
    public var assetsURL: URL { directory.appendingPathComponent(Self.assetsFolder, isDirectory: true) }
    public var assetsListURL: URL { directory.appendingPathComponent("assets.json") }
    public var videosURL: URL { directory.appendingPathComponent(Self.videosFolder, isDirectory: true) }

    static let assetsFolder = "assets"
    static let videosFolder = "videos"

    public var exists: Bool { FileManager.default.fileExists(atPath: memoryURL.path) }

    // MARK: - Finding and creating

    /// Projects in `root`, the most recently worked on first.
    public static func all(in root: URL = StudioWorkspace.defaultRoot) -> [ProjectFolder] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.map(ProjectFolder.init).filter(\.exists)
            .map { ($0, $0.lastChanged) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var lastChanged: Date {
        func changed(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return ([changed(memoryURL)] + videos().flatMap { [changed($0.chatURL), changed($0.storyboardURL)] }).max() ?? .distantPast
    }

    /// Makes a project. The folder is named after it ("Orbit", "Orbit 2").
    public static func create(named name: String, kind: ProjectMemory.Kind = .app, in root: URL = StudioWorkspace.defaultRoot) throws -> ProjectFolder {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = ProjectFolder(directory: freeFolder(named: title.isEmpty ? "Project" : title, in: root))
        try FileManager.default.createDirectory(at: project.assetsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.videosURL, withIntermediateDirectories: true)
        try project.save(ProjectMemory(name: title.isEmpty ? project.folderName : title, kind: kind))
        return project
    }

    /// A folder in `parent` that does not exist yet, named as asked or with
    /// a number after it.
    public static func freeFolder(named name: String, in parent: URL) -> URL {
        // Characters a folder name cannot hold.
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        base = String(base.prefix(60)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if base.isEmpty { base = "Untitled" }
        var url = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return url
    }

    /// Names a new project has before the user has named it.
    public static let placeholderNames: Set<String> = ["My Project", "New Project", "Project", "Untitled"]

    /// Once a project made as "New Project" has a real name, its folder
    /// takes that name too, so it can be found in the Finder. Returns the
    /// project in its new place, or nil when nothing was moved.
    public func renamedForItsName() -> ProjectFolder? {
        let name = loadMemory().name
        let base = folderName.replacingOccurrences(of: " \\d+$", with: "", options: .regularExpression)
        guard Self.placeholderNames.contains(base), !Self.placeholderNames.contains(name), !name.isEmpty else { return nil }
        let moved = ProjectFolder(directory: Self.freeFolder(named: name, in: directory.deletingLastPathComponent()))
        guard (try? FileManager.default.moveItem(at: directory, to: moved.directory)) != nil else { return nil }
        try? moved.writeBrief()
        return moved
    }

    // MARK: - Memory

    public func loadMemory() -> ProjectMemory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: memoryURL), var memory = try? decoder.decode(ProjectMemory.self, from: data) else {
            return ProjectMemory(name: folderName)
        }
        if memory.name.isEmpty { memory.name = folderName }
        return memory
    }

    /// Saves the memory and rewrites the brief to match.
    public func save(_ memory: ProjectMemory) throws {
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videosURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(memory).write(to: memoryURL, options: .atomic)
        try writeBrief(memory)
    }

    /// Adds facts to the memory. Returns the ones that were new.
    @discardableResult
    public func remember(_ facts: [String]) throws -> [String] {
        var memory = loadMemory()
        let added = memory.remember(facts)
        if !added.isEmpty { try save(memory) }
        return added
    }

    /// Rewrites `PROJECT.md` from the memory, the files and the videos.
    public func writeBrief(_ memory: ProjectMemory? = nil) throws {
        let text = ProjectBrief.markdown(memory ?? loadMemory(), assets: loadAssets(), videos: videos().map(ProjectBrief.Video.init),
                                         folder: directory, tool: ProjectBrief.toolPath)
        try Data(text.utf8).write(to: briefURL, options: .atomic)
    }

    // MARK: - Assets

    public func loadAssets() -> [StudioMaterial] {
        let stored = (try? Data(contentsOf: assetsListURL)).flatMap { try? JSONDecoder().decode([StudioMaterial].self, from: $0) } ?? []
        return stored.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.file).path) }
    }

    public func saveAssets(_ assets: [StudioMaterial]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(assets).write(to: assetsListURL, options: .atomic)
        try writeBrief()
    }

    /// Copies a file into the project's assets and lists it.
    @discardableResult
    public func addAsset(from source: URL, named preferred: String? = nil, note: String? = nil) async throws -> StudioMaterial {
        let asset = try await StudioMaterial.importing(source, into: assetsURL, base: directory, named: preferred, note: note)
        try saveAssets(loadAssets() + [asset])
        return asset
    }

    /// Downloads a picture (a website's icon) into the project's assets.
    /// Nil when it cannot be fetched or is not a picture Tasjeel can use.
    /// A picture already downloaded with the same note is used again, so
    /// asking twice does not add it twice.
    public func addPicture(downloadedFrom url: URL, named name: String, note: String? = nil, session: URLSession = .shared) async -> StudioMaterial? {
        if let note, let have = loadAssets().first(where: { $0.note == note }) { return have }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh) Tasjeel", forHTTPHeaderField: "User-Agent")
        guard Storyboard.imageTypes.contains(url.pathExtension.lowercased()),
              let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100, data.count < 5_000_000 else { return nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tasjeel-\(UUID().uuidString).\(url.pathExtension.lowercased())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (try? data.write(to: temporary)) != nil else { return nil }
        return try? await addAsset(from: temporary, named: name, note: note)
    }

    /// Saves a picture (a screenshot) into the project's assets as a PNG.
    @discardableResult
    public func addPicture(_ image: CGImage, named name: String, note: String?) throws -> StudioMaterial {
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let file = StudioMaterial.freeName(for: name, type: "png", fallback: "screenshot", in: assetsURL)
        let url = assetsURL.appendingPathComponent(file)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw StudioMaterial.ImportError.unreadable(file)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StudioMaterial.ImportError.unreadable(file) }
        let asset = StudioMaterial(file: "\(Self.assetsFolder)/\(file)", kind: .picture, width: image.width, height: image.height, note: note)
        try saveAssets(loadAssets() + [asset])
        return asset
    }

    public func removeAsset(_ asset: StudioMaterial) throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(asset.file))
        try saveAssets(loadAssets().filter { $0.file != asset.file })
    }

    // MARK: - Videos

    /// The project's videos, the most recently changed first.
    public func videos() -> [StudioWorkspace] {
        StudioWorkspace.all(in: videosURL)
    }

    public func newVideo(named name: String = "Video") throws -> StudioWorkspace {
        try FileManager.default.createDirectory(at: videosURL, withIntermediateDirectories: true)
        return try StudioWorkspace.create(in: videosURL, named: name)
    }

    // MARK: - Videos made before there were projects

    /// Earlier versions kept each video directly in the Studio folder with
    /// its own materials. Each such video becomes a project of its own, so
    /// nothing made before is lost.
    public static func adoptLooseVideos(in root: URL = StudioWorkspace.defaultRoot) {
        let fm = FileManager.default
        for loose in StudioWorkspace.all(in: root) where !ProjectFolder(directory: loose.directory).exists {
            let chat = loose.loadChat()
            guard !chat.messages.isEmpty || !chat.materials.isEmpty || loose.loadStoryboard() != nil else {
                try? fm.removeItem(at: loose.directory)
                continue
            }
            // The folder becomes the project; its contents move one level down.
            let holding = root.appendingPathComponent(".adopting-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.moveItem(at: loose.directory, to: holding)
                let project = ProjectFolder(directory: loose.directory)
                try fm.createDirectory(at: project.videosURL, withIntermediateDirectories: true)
                let video = project.videosURL.appendingPathComponent(loose.name, isDirectory: true)
                try fm.moveItem(at: holding, to: video)
                // Its materials become the project's assets, under the same names.
                let old = video.appendingPathComponent(StudioWorkspace.materialsFolder)
                if fm.fileExists(atPath: old.path) {
                    try fm.moveItem(at: old, to: project.assetsURL)
                } else {
                    try fm.createDirectory(at: project.assetsURL, withIntermediateDirectories: true)
                }
                func moved(_ text: String) -> String {
                    text.replacingOccurrences(of: "\"\(StudioWorkspace.materialsFolder)/", with: "\"\(assetsFolder)/")
                }
                let workspace = StudioWorkspace(directory: video)
                if let storyboard = try? String(contentsOf: workspace.storyboardURL, encoding: .utf8) {
                    try workspace.saveStoryboard(moved(storyboard))
                }
                var title = loose.name
                if let data = try? Data(contentsOf: workspace.storyboardURL),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let brand = (object["brand"] as? [String: Any])?["name"] as? String, !brand.isEmpty {
                    title = brand
                }
                try project.save(ProjectMemory(name: title, kind: .other))
                let assets = chat.materials.map { material -> StudioMaterial in
                    var asset = material
                    asset.file = assetsFolder + "/" + material.name
                    return asset
                }
                var kept = chat
                kept.materials = []
                kept.messages = kept.messages.map { message in
                    var message = message
                    message.storyboard = message.storyboard.map(moved)
                    return message
                }
                try project.saveAssets(assets)
                try workspace.save(kept)
            } catch {
                // Put it back as it was rather than leave it half moved.
                if fm.fileExists(atPath: holding.path), !fm.fileExists(atPath: loose.directory.path) {
                    try? fm.moveItem(at: holding, to: loose.directory)
                }
            }
        }
    }
}

// MARK: - The brief

/// Writes a project's memory out as Markdown: once in full for an AI agent
/// (`PROJECT.md`), and once as just the knowledge for the Studio's own model.
public enum ProjectBrief {
    /// One line about a video, for the list of files.
    public struct Video: Equatable, Sendable {
        public var folder: String
        public var title: String?
        public var rendered: [String]

        public init(folder: String, title: String? = nil, rendered: [String] = []) {
            self.folder = folder
            self.title = title
            self.rendered = rendered
        }

        public init(_ workspace: StudioWorkspace) {
            folder = workspace.name
            title = workspace.loadStoryboard().flatMap { text -> String? in
                let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                return object?["title"] as? String
            }
            rendered = Storyboard.formats.filter { FileManager.default.fileExists(atPath: workspace.renderedURL($0).path) }
        }
    }

    /// Where the Tasjeel command is, for the commands in the brief.
    public static var toolPath: String {
        let installed = "/Applications/Tasjeel.app/Contents/MacOS/Tasjeel"
        return FileManager.default.isExecutableFile(atPath: installed) ? installed : (Bundle.main.executablePath ?? installed)
    }

    /// What is known about the project, with nothing about files or tools.
    /// This is what the Studio's model reads before writing a video.
    public static func knowledge(_ memory: ProjectMemory) -> String {
        var parts: [String] = []
        func section(_ title: String, _ body: String) {
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append("## \(title)\n\n\(text)") }
        }
        func bullets(_ items: [String]) -> String {
            items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { "- \($0)" }.joined(separator: "\n")
        }

        var opening = memory.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if memory.kind == .app {
            let platforms = memory.app.platforms.isEmpty ? "" : " (\(memory.app.platforms.joined(separator: ", ")))"
            opening += (opening.isEmpty ? "" : "\n\n") + "Kind of project: an app\(platforms)."
        }
        if !opening.isEmpty { parts.append(opening) }

        section("Who it is for", memory.audience)
        section("How it talks", memory.voice)
        section("What it does", bullets(memory.features))
        section("Facts that are true and may be shown", bullets(memory.facts))
        section("Links", bullets(memory.links))

        var brand: [String] = []
        if !memory.logo.isEmpty { brand.append("Logo: `\(memory.logo)`") }
        for (label, value) in [("Accent colour", memory.accent), ("Background colour", memory.background), ("Text colour", memory.text)] where !value.isEmpty {
            brand.append("\(label): \(value)")
        }
        section("Brand", bullets(brand))

        if memory.kind == .app {
            var app: [String] = []
            if !memory.app.address.isEmpty { app.append("Address: \(memory.app.address)") }
            if !memory.app.window.isEmpty { app.append("On this Mac its window is called: \(memory.app.window)") }
            var body = bullets(app)
            let guide = memory.app.guide.trimmingCharacters(in: .whitespacesAndNewlines)
            if !guide.isEmpty { body += (body.isEmpty ? "" : "\n\n") + "Getting around it:\n\n\(guide)" }
            section("The app", body)
        }

        section("Notes", memory.notes)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        section("Learned along the way", memory.learned.map { "- \($0.text) (\(day.string(from: $0.date)))" }.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// The whole brief: the knowledge, the files, and how an AI agent can
    /// add to the project with Tasjeel's commands.
    public static func markdown(_ memory: ProjectMemory, assets: [StudioMaterial], videos: [Video], folder: URL, tool: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func short(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }
        let here = short(folder.path)
        let command = "\"\(tool)\""
        // The commands that make a video name one that exists, if any does.
        let video = videos.first?.folder ?? "Launch"

        var parts = ["# \(memory.name)", """
        > The project brief, kept by Tasjeel. It is rewritten whenever the project's memory or files change, so do not edit it by hand: change the memory in Tasjeel (Studio, then Project) or with the commands at the end.
        """]

        let known = knowledge(memory)
        parts.append(known.isEmpty || memory.isEmpty ? "Nothing has been written down about this project yet." : known)

        var files = "Everything is in `\(here)`.\n\n"
        if assets.isEmpty {
            files += "`assets/` is empty: no logo, screenshots or recordings have been added yet."
        } else {
            files += "In `assets/`:\n\n" + assets.map { asset -> String in
                var line = "- `\(asset.file)`: "
                switch asset.kind {
                case .picture:
                    line += "picture, \(asset.width) by \(asset.height)"
                case .video:
                    line += "video, \(NotesFormat.stamp(asset.seconds ?? 0)) long, \(asset.width) by \(asset.height)"
                }
                // Only the first line of a note: a recording's note holds its whole transcript.
                if let first = asset.note?.split(separator: "\n").first { line += ". \(first)" }
                return line
            }.joined(separator: "\n")
        }
        if !videos.isEmpty {
            files += "\n\nIn `videos/`:\n\n" + videos.map { video -> String in
                var line = "- `videos/\(video.folder)/`"
                if let title = video.title { line += ": \"\(title)\"" }
                line += video.rendered.isEmpty ? " (not rendered yet)" : ", rendered as " + video.rendered.map { "`video/out/\($0).mp4`" }.joined(separator: ", ")
                return line
            }.joined(separator: "\n")
        }
        parts.append("## Files\n\n" + files)

        var agents = """
        ## For AI agents

        You are helping with the project described above. Treat this file as what is known about it.

        - Use only what is written here, what the person tells you, and what you can see in `assets/`. Never invent a customer's words, a name or a figure: marketing made from this project is published under the owner's name.
        - Put new pictures and clips in the project with the commands below rather than by copying files in, so that they are listed here.
        - When the person tells you something lasting about the project, save it with `--remember` so the next agent knows it too.

        Commands (run in a terminal on this Mac):

        ```bash
        # Print this brief again, up to date
        \(command) --project "\(here)" --brief

        # Remember a fact about the project
        \(command) --project "\(here)" --remember "The free plan allows three projects"

        # See which app windows are open, then take a screenshot of one into assets/
        \(command) --project "\(here)" --windows
        \(command) --project "\(here)" --screenshot "\(memory.app.window.isEmpty ? "Safari" : memory.app.window)" --name "settings-screen"

        # Add a picture or a video file to assets/
        \(command) --project "\(here)" --add "/path/to/file.png"

        # Write or change a video by describing it, then render it
        \(command) --studio "\(here)/videos/\(video)" --say "A 20-second launch video for the new export screen"
        \(command) --studio "\(here)/videos/\(video)" --render wide
        ```

        Paths may start with `~`; Tasjeel expands it. Screenshots need the terminal you run in to be allowed under System Settings, Privacy & Security, Screen & System Audio Recording. A screenshot shows the window as it is at that moment. Tasjeel takes the picture but does not click or type, so get the app to the screen you want first, with whatever you have for that (a browser tool for a web app, a simulator tool for a phone app), or ask the person to open it.
        """
        if memory.kind == .app {
            agents += "\n\nTo show the app in a video, take a screenshot of each screen that matters, name it for what it shows, then ask for the video. A video is described in `storyboard.json` inside its folder; the format is at https://github.com/rnl180/tasjeel/blob/main/docs/storyboard.md."
        } else {
            agents += "\n\nA video is described in `storyboard.json` inside its folder; the format is at https://github.com/rnl180/tasjeel/blob/main/docs/storyboard.md."
        }
        parts.append(agents)
        return parts.joined(separator: "\n\n") + "\n"
    }
}
