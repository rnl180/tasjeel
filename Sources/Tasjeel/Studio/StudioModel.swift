import AppKit
import AVFoundation
import SwiftUI
import TasjeelCore

/// The Studio window's state: one project's chat, materials, storyboard and
/// rendered video.
@MainActor
final class StudioModel: ObservableObject {
    let root: URL
    let ai = AIConfig.shared
    let player = AVPlayer()

    @Published private(set) var workspace: StudioWorkspace
    @Published private(set) var projects: [Project] = []

    // Chat
    @Published private(set) var messages: [StudioMessage] = []
    @Published var draft = ""
    /// Set while the model is answering: its reply so far.
    @Published private(set) var writing: Writing?
    @Published var chatError: String?

    // Materials
    @Published private(set) var materials: [StudioMaterial] = []
    @Published private(set) var addingMaterials = false
    @Published var materialError: String?

    // Storyboard
    @Published private(set) var storyboard: String?
    @Published private(set) var outline: Storyboard.Outline?
    /// What is wrong with the storyboard file, when it was edited by hand
    /// into something Tasjeel cannot build.
    @Published private(set) var storyboardProblems: [String] = []

    // Video
    @Published var format = "wide" { didSet { if format != oldValue { refreshVideo() } } }
    @Published private(set) var render: RenderJob?
    @Published var renderError: String?
    /// The rendered video for the chosen size, when there is one.
    @Published private(set) var videoURL: URL?
    /// True when the storyboard changed after that video was made.
    @Published private(set) var videoIsStale = false
    @Published var askDownload = false
    private var formatsToRender: [String] = []

    struct Project: Identifiable, Equatable {
        var workspace: StudioWorkspace
        var title: String
        var id: URL { workspace.directory }
    }

    struct Writing: Equatable {
        var text: String
        var engine: String
    }

    struct RenderJob: Equatable {
        var fraction: Double?
        var label: String
    }

    private var chatTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var loadedVideo: (url: URL, date: Date)?

    init(root: URL = StudioWorkspace.defaultRoot, opening directory: URL? = nil) {
        self.root = root
        if let directory {
            workspace = StudioWorkspace(directory: directory)
        } else if let recent = StudioWorkspace.all(in: root).first {
            workspace = recent
        } else {
            workspace = StudioWorkspace(directory: root.appendingPathComponent("Video", isDirectory: true))
        }
        try? workspace.prepare()
        load()
    }

    var title: String { outline?.title ?? workspace.name }
    var isBusy: Bool { writing != nil }

    // MARK: - Projects

    private func load() {
        let chat = workspace.loadChat()
        messages = chat.messages
        materials = chat.materials
        draft = ""
        chatError = nil
        materialError = nil
        renderError = nil
        reloadStoryboard()
        reloadProjects()
    }

    private func reloadProjects() {
        projects = StudioWorkspace.all(in: root).map { workspace in
            var title = workspace.name
            if let text = workspace.loadStoryboard(), let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = object["title"] as? String, !name.isEmpty {
                title = name
            }
            return Project(workspace: workspace, title: title)
        }
    }

    func open(_ project: StudioWorkspace) {
        guard project != workspace else { return }
        stopEverything()
        workspace = project
        try? project.prepare()
        storyboard = nil
        outline = nil
        storyboardProblems = []
        loadedVideo = nil
        player.replaceCurrentItem(with: nil)
        load()
    }

    func newProject() {
        guard let created = try? StudioWorkspace.create(in: root) else { return }
        open(created)
    }

    func close() {
        stopEverything()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func stopEverything() {
        chatTask?.cancel()
        renderTask?.cancel()
        writing = nil
        render = nil
    }

    private func saveChat() {
        try? workspace.save(StudioChat(messages: messages, materials: materials))
    }

    // MARK: - Chat

    /// The engine that would answer now, or why none can.
    var engine: AIChoice {
        AIEngines.chooseWriter(ai.engine, ollamaModel: ai.ollamaModel, found: ai.found)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, writing == nil else { return }
        // Checked before the message is added, so nothing is lost when no
        // model is set up yet.
        if case .unavailable(let reason) = engine {
            chatError = reason
            return
        }
        draft = ""
        messages.append(StudioMessage(role: .user, text: text))
        saveChat()
        respond()
    }

    /// Answers the last message again after a failure.
    func retry() {
        guard writing == nil, messages.last?.role == .user else { return }
        respond()
    }

    private func respond() {
        let model: any TextModel
        do {
            model = try AIEngines.model(for: engine) { SecretStore.readKey() }
        } catch {
            chatError = error.localizedDescription
            return
        }
        chatError = nil
        writing = Writing(text: "", engine: model.displayName)
        let workspace = workspace, messages = messages, materials = materials, storyboard = storyboard
        chatTask = Task { [weak self] in
            do {
                let looks = model.seesImages ? await workspace.looks(at: materials) : StudioWorkspace.Looks()
                let answer = try await StoryboardWriter.answer(messages: messages, materials: materials, storyboard: storyboard,
                                                               directory: workspace.directory, model: model, looks: looks) { partial in
                    Task { @MainActor in
                        if self?.writing != nil, self?.workspace == workspace { self?.writing?.text = partial }
                    }
                }
                guard let self, !Task.isCancelled, self.workspace == workspace else { return }
                self.apply(answer)
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                if self?.workspace == workspace, !Task.isCancelled { self?.chatError = error.localizedDescription }
            }
            if self?.workspace == workspace { self?.writing = nil }
        }
    }

    func stopWriting() {
        chatTask?.cancel()
        writing = nil
    }

    private func apply(_ answer: StoryboardWriter.Answer) {
        messages.append(StudioMessage(role: .assistant, text: answer.reply, storyboard: answer.storyboard,
                                      problems: answer.problems.isEmpty ? nil : answer.problems))
        if let text = answer.storyboard {
            try? workspace.saveStoryboard(text)
            reloadStoryboard()
            reloadProjects()
        }
        saveChat()
    }

    /// True when `message` holds a storyboard other than the current one.
    func canRestore(_ message: StudioMessage) -> Bool {
        message.storyboard != nil && message.storyboard != storyboard && writing == nil
    }

    func restore(_ message: StudioMessage) {
        guard let text = message.storyboard else { return }
        try? workspace.saveStoryboard(text)
        reloadStoryboard()
    }

    func clearChat() {
        stopWriting()
        messages = []
        chatError = nil
        saveChat()
    }

    // MARK: - Storyboard

    /// Reads the storyboard file again. Called after every change, and when
    /// the app comes forward in case the file was edited by hand.
    func reloadStoryboard() {
        let text = workspace.loadStoryboard()
        let alreadyRead = outline != nil || !storyboardProblems.isEmpty || text == nil
        if text == storyboard, alreadyRead {
            refreshVideo()
            return
        }
        storyboard = text
        outline = nil
        storyboardProblems = []
        if let text, let data = text.data(using: .utf8) {
            do {
                let plan = try Storyboard.plan(from: data, baseDirectory: workspace.directory)
                let found = Storyboard.outline(of: plan)
                outline = found
                if !found.formats.contains(format) { format = found.formats.first ?? "wide" }
            } catch StoryboardError.invalid(let problems) {
                storyboardProblems = problems
            } catch {
                storyboardProblems = [error.localizedDescription]
            }
        }
        refreshVideo()
    }

    // MARK: - Materials

    func addMaterials(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        add(urls.map { (url: $0, name: nil, note: nil) })
    }

    /// Adds a recording from the library, along with what is said in it so
    /// the model can choose which part to show.
    func addRecording(_ entry: LibraryEntry) {
        let store = AppState.shared.store
        let note = StoryboardWriter.note(forRecording: entry.recording.title, transcript: store.loadTranscript(in: entry.directory),
                                         notes: store.loadNotes(in: entry.directory))
        add([(url: entry.screenURL, name: entry.recording.title, note: note)])
    }

    private func add(_ items: [(url: URL, name: String?, note: String?)]) {
        let workspace = workspace
        addingMaterials = true
        materialError = nil
        Task {
            var problems: [String] = []
            for item in items {
                do {
                    let material = try await workspace.addMaterial(from: item.url, named: item.name, note: item.note)
                    if self.workspace == workspace { materials.append(material) }
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            guard self.workspace == workspace else { return }
            addingMaterials = false
            if !problems.isEmpty { materialError = problems.joined(separator: "\n") }
            saveChat()
        }
    }

    func remove(_ material: StudioMaterial) {
        materials.removeAll { $0.id == material.id }
        workspace.removeMaterial(material)
        saveChat()
        // The storyboard may have used it.
        storyboard = nil
        reloadStoryboard()
    }

    func chooseMaterials() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.message = "Choose screenshots, a logo, or videos to make the video from."
        panel.prompt = "Add"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.addMaterials(urls) }
        }
    }

    // MARK: - Video

    /// Which rendered file to show, and whether it is out of date.
    private func refreshVideo() {
        let url = workspace.renderedURL(format)
        func changed(_ file: URL) -> Date? { try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard outline != nil, let made = changed(url) else {
            videoURL = nil
            videoIsStale = false
            if loadedVideo != nil {
                loadedVideo = nil
                player.replaceCurrentItem(with: nil)
            }
            return
        }
        videoURL = url
        videoIsStale = (changed(workspace.storyboardURL) ?? .distantPast) > made
        if loadedVideo?.url != url || loadedVideo?.date != made {
            loadedVideo = (url, made)
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
    }

    /// Builds the project and renders the chosen size, or every size.
    func createVideo(allSizes: Bool = false) {
        guard render == nil, let outline else { return }
        formatsToRender = allSizes ? outline.formats : [format]
        renderError = nil
        if StudioRenderer.needsDownload(project: workspace.videoURL, root: root) {
            guard StudioRenderer.findNode() != nil else {
                renderError = StudioRenderer.RenderError.noNode.localizedDescription
                return
            }
            askDownload = true
            return
        }
        startRender()
    }

    /// Continues after the user agreed to download Remotion.
    func startRender() {
        guard render == nil, !formatsToRender.isEmpty else { return }
        let workspace = workspace, formats = formatsToRender, root = root
        player.pause()
        render = RenderJob(fraction: nil, label: "Preparing the clips…")
        renderTask = Task { [weak self] in
            @Sendable func update(_ fraction: Double?, _ label: String) {
                Task { @MainActor in
                    if self?.render != nil, self?.workspace == workspace { self?.render = RenderJob(fraction: fraction, label: label) }
                }
            }
            do {
                _ = try await StudioProject.build(storyboard: workspace.storyboardURL, in: workspace.videoURL)
                for (index, format) in formats.enumerated() {
                    try Task.checkCancellation()
                    let name = formats.count > 1 ? "\(format.capitalized): " : ""
                    _ = try await StudioRenderer.render(project: workspace.videoURL, format: format, root: root) { fraction, label in
                        let done = fraction.map { (Double(index) + $0) / Double(formats.count) }
                        update(done, name + label)
                    }
                }
                guard let self, self.workspace == workspace, !Task.isCancelled else { return }
                self.render = nil
                self.refreshVideo()
                if formats.count > 1 {
                    NSWorkspace.shared.open(workspace.videoURL.appendingPathComponent("out"))
                } else if !DebugSnapshot.isActive {
                    await self.player.seek(to: .zero)
                    self.player.play()
                }
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                if self?.workspace == workspace, !Task.isCancelled { self?.renderError = error.localizedDescription }
            }
            if self?.workspace == workspace { self?.render = nil }
        }
    }

    func cancelRender() {
        renderTask?.cancel()
        render = nil
    }

    // MARK: - Finder

    func revealProject() {
        NSWorkspace.shared.open(workspace.directory)
    }

    func revealVideo() {
        if let videoURL { NSWorkspace.shared.activateFileViewerSelecting([videoURL]) }
    }

    func openStoryboardFile() {
        NSWorkspace.shared.open(workspace.storyboardURL)
    }

    /// Opens the built project in Remotion's own editor, for changing how
    /// scenes look.
    var remotionStarter: URL? {
        let url = workspace.videoURL.appendingPathComponent("Start.command")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// The Studio window. There is one; it shows one project at a time.
@MainActor
final class StudioWindow: NSObject, NSWindowDelegate {
    static let shared = StudioWindow()

    private var window: NSWindow?
    private(set) var model: StudioModel?

    func open(project directory: URL? = nil) {
        let quiet = DebugSnapshot.isActive
        if !quiet { NSApp.activate(ignoringOtherApps: true) }
        if let window, let model {
            if let directory { model.open(StudioWorkspace(directory: directory)) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = StudioModel(opening: directory)
        let host = NSHostingController(rootView: StudioView(model: model).preferredColorScheme(.dark))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Studio"
        window.backgroundColor = NSColor(Theme.window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1040, height: 660)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("studio")
        window.delegate = self
        self.window = window
        self.model = model
        if quiet { window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        model?.close()
        model = nil
        window = nil
    }

    /// The storyboard may have been edited in another app meanwhile.
    func windowDidBecomeKey(_ notification: Notification) {
        model?.reloadStoryboard()
    }
}
