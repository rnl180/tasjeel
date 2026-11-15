import AppKit
import AVFoundation
import SwiftUI
import TasjeelCore

/// Everything one editor window knows: the recording, the current edit, the
/// player, and undo history. Views read from here and call its methods.
@MainActor
final class EditorModel: ObservableObject {
    enum Selection: Equatable {
        case none
        case segment(Int)
        case gap(Int)
        case zoom(UUID)
    }

    enum Tab: String, CaseIterable {
        case look = "Look", camera = "Camera", zoom = "Zoom", audio = "Audio", transcript = "Transcript"
    }

    let directory: URL
    private let store: ProjectStore

    @Published private(set) var recording: Recording
    @Published private(set) var edit: EditState
    /// Length of the raw recording.
    @Published private(set) var duration: Double
    /// Playhead position in source time (the raw recording's clock).
    @Published private(set) var currentTime = 0.0
    @Published private(set) var isPlaying = false
    @Published var selection = Selection.none
    @Published var tab = Tab.look
    @Published var timelineZoom = 1.0
    @Published private(set) var thumbnails: [(time: Double, image: CGImage)] = []
    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?
    @Published private(set) var hasCamera = false
    @Published private(set) var canvasAspect: CGFloat = 16.0 / 10.0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    @Published private(set) var transcript: Transcript?
    /// Set while a transcript is being created.
    @Published private(set) var transcription: TranscriptionJob?
    @Published var transcriptError: String?
    @Published private(set) var languages: [TranscriptionLanguage] = []

    @Published private(set) var exportProgress: Double?
    @Published var exportedURL: URL?
    @Published var exportError: String?

    let player = AVPlayer()

    private var media: LoadedMedia?
    private var built: BuiltComposition?
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var lastMutationKey: String?
    private var lastMutationAt = Date.distantPast
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var pendingSeek: CMTime?
    private var seeking = false
    private var saveTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?

    struct TranscriptionJob: Equatable {
        var progress: Double
        var status: String
    }

    init(item: LibraryEntry, store: ProjectStore) {
        directory = item.directory
        self.store = store
        recording = item.recording
        edit = item.recording.edit
        duration = item.recording.duration
        transcript = store.loadTranscript(in: item.directory)
        player.actionAtItemEnd = .pause
    }

    // MARK: - Derived

    var timeMap: TimeMap { TimeMap(segments: edit.segments) }
    var gaps: [TimeSpan] { timeMap.gaps(total: duration) }
    var finalDuration: Double { edit.keptDuration }
    var hasCuts: Bool { !gaps.isEmpty }
    var hasMic: Bool { recording.audioTracks.contains(.mic) }
    var hasSystemAudio: Bool { recording.audioTracks.contains(.system) }
    var screenSize: CGSize { media?.screenSize ?? recording.screenSize }

    var selectedZoom: ZoomSegment? {
        if case .zoom(let id) = selection { return edit.zooms.first { $0.id == id } }
        return nil
    }

    // MARK: - Loading

    func load() async {
        guard media == nil, loadError == nil else { return }
        do {
            let media = try await CompositionBuilder.load(recording: recording, directory: directory)
            self.media = media
            duration = media.screenDuration.seconds
            hasCamera = media.cameraVideo != nil

            // Repair anything out of range (e.g. a project edited by hand).
            var clean = edit
            clean.segments = clean.segments
                .map { TimeSpan(start: max(0, $0.start), end: min(duration, $0.end)) }
                .filter { $0.duration > 0.01 }
                .sorted { $0.start < $1.start }
            if clean.segments.isEmpty { clean.segments = [TimeSpan(start: 0, end: duration)] }
            edit = clean

            try rebuild(keeping: 0)
            installObservers()
            isReady = true
            await loadThumbnails(from: media)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, self.pendingSeek == nil else { return }
                self.currentTime = self.timeMap.source(fromComposition: time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.isPlaying = false
            }
        }
    }

    private func loadThumbnails(from media: LoadedMedia) async {
        let generator = AVAssetImageGenerator(asset: media.screenAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 200)
        // Nearest keyframe is fine for a filmstrip and far quicker.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let count = 28
        let times = (0 ..< count).map { CMTime(seconds: (Double($0) + 0.5) / Double(count) * duration, preferredTimescale: 600) }
        var loaded: [(time: Double, image: CGImage)] = []
        for await result in generator.images(for: times) {
            if case .success(let requested, let image, _) = result {
                loaded.append((requested.seconds, image))
                loaded.sort { $0.time < $1.time }
                thumbnails = loaded
            }
        }
    }

    /// The filmstrip frame closest to `time`.
    func thumbnail(near time: Double) -> CGImage? {
        thumbnails.min { abs($0.time - time) < abs($1.time - time) }?.image
    }

    // MARK: - Building the preview

    /// Rebuilds the cut list. Needed when cuts or the canvas shape change.
    private func rebuild(keeping sourceTime: Double) throws {
        guard let media else { return }
        let long = min(1920, Int(max(media.screenSize.width, media.screenSize.height)))
        let size = CompositionBuilder.canvasSize(aspect: edit.aspect, source: media.screenSize, longSide: long)
        let built = try CompositionBuilder.build(media: media, recording: recording, edit: edit, renderSize: size, fps: 30,
                                                 captions: transcript?.segments ?? [])
        self.built = built
        canvasAspect = size.width / size.height

        let wasPlaying = isPlaying
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        player.replaceCurrentItem(with: item)
        seek(toSource: sourceTime)
        if wasPlaying { player.play() }
    }

    /// Applies look, camera, zoom and volume changes to the running preview.
    private func restyle() {
        guard let built, let item = player.currentItem else { return }
        let updated = CompositionBuilder.restyled(built, edit: edit, captions: transcript?.segments ?? [])
        self.built = updated
        item.videoComposition = updated.videoComposition
        item.audioMix = updated.audioMix
        if !isPlaying {
            // Redraw the paused frame with the new look.
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: - Playback

    func togglePlay() {
        guard isReady else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if player.currentTime().seconds >= finalDuration - 0.05 { seek(toSource: edit.segments.first?.start ?? 0) }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Moves the playhead. Times inside a cut snap to the next kept frame.
    func seek(toSource time: Double) {
        let map = timeMap
        let composition = map.composition(fromSource: min(max(time, 0), duration))
        currentTime = map.source(fromComposition: composition)
        pendingSeek = CMTime(seconds: composition, preferredTimescale: 600)
        if !seeking { performSeek() }
    }

    // While dragging the playhead, only the newest position is worth seeking
    // to; anything requested during a seek replaces what was queued.
    private func performSeek() {
        guard let target = pendingSeek else { return }
        pendingSeek = nil
        seeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                self.performSeek()
            }
        }
    }

    func step(frames: Int) {
        pause()
        seek(toSource: currentTime + Double(frames) / 30)
    }

    // MARK: - Editing

    /// Changes the edit, records an undo step, and updates the preview.
    /// Changes that share a `key` within a second (a slider drag) undo as one.
    func mutate(_ key: String? = nil, _ change: (inout EditState) -> Void) {
        var next = edit
        change(&next)
        guard next != edit else { return }
        let now = Date()
        let continuing = key != nil && key == lastMutationKey && now.timeIntervalSince(lastMutationAt) < 1
        if !continuing {
            undoStack.append(edit)
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        lastMutationKey = key
        lastMutationAt = now
        apply(next)
    }

    private func apply(_ next: EditState) {
        let previous = edit
        edit = next
        if previous.segments != next.segments || previous.aspect != next.aspect {
            do {
                try rebuild(keeping: currentTime)
            } catch {
                edit = previous
            }
        } else {
            restyle()
        }
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        scheduleSave()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edit)
        lastMutationKey = nil
        selection = .none
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        lastMutationKey = nil
        selection = .none
        apply(next)
    }

    /// A two-way binding to one field of the edit, for sliders and pickers.
    func binding<T: Equatable>(_ keyPath: WritableKeyPath<EditState, T>, key: String) -> Binding<T> {
        Binding(get: { self.edit[keyPath: keyPath] }, set: { value in self.mutate(key) { $0[keyPath: keyPath] = value } })
    }

    // MARK: Cuts

    private var splitIndex: Int? {
        edit.segments.firstIndex { currentTime > $0.start + 0.1 && currentTime < $0.end - 0.1 }
    }

    var canSplit: Bool { splitIndex != nil }

    /// Cuts the clip in two at the playhead.
    func split() {
        guard let index = splitIndex else { return }
        let time = currentTime
        mutate { edit in
            let span = edit.segments[index]
            edit.segments.replaceSubrange(index ... index, with: [TimeSpan(start: span.start, end: time), TimeSpan(start: time, end: span.end)])
        }
        selection = .segment(index + 1)
    }

    var canDelete: Bool {
        switch selection {
        case .segment(let index): return edit.segments.count > 1 && edit.segments.indices.contains(index)
        case .zoom: return true
        case .gap, .none: return false
        }
    }

    func deleteSelection() {
        switch selection {
        case .segment(let index):
            guard edit.segments.count > 1, edit.segments.indices.contains(index) else { return }
            selection = .none
            mutate { $0.segments.remove(at: index) }
        case .zoom(let id):
            selection = .none
            mutate { $0.zooms.removeAll { $0.id == id } }
        case .gap, .none:
            break
        }
    }

    var canTrimStart: Bool { currentTime > (edit.segments.first?.start ?? 0) + 0.1 && finalDurationAfterTrimStart > 0.3 }
    var canTrimEnd: Bool { currentTime < (edit.segments.last?.end ?? duration) - 0.1 && currentTime > (edit.segments.first?.start ?? 0) + 0.3 }

    private var finalDurationAfterTrimStart: Double {
        edit.segments.reduce(0) { $0 + max(0, $1.end - max($1.start, currentTime)) }
    }

    /// Removes everything before the playhead.
    func trimStart() {
        guard canTrimStart else { return }
        let time = currentTime
        selection = .none
        mutate { edit in
            edit.segments = edit.segments.compactMap { $0.end <= time ? nil : TimeSpan(start: max($0.start, time), end: $0.end) }
        }
    }

    /// Removes everything after the playhead.
    func trimEnd() {
        guard canTrimEnd else { return }
        let time = currentTime
        selection = .none
        mutate { edit in
            edit.segments = edit.segments.compactMap { $0.start >= time ? nil : TimeSpan(start: $0.start, end: min($0.end, time)) }
        }
    }

    /// Puts a removed part back.
    func restoreGap(_ index: Int) {
        let gaps = gaps
        guard gaps.indices.contains(index) else { return }
        selection = .none
        mutate { edit in
            edit.segments = Self.merged(edit.segments + [gaps[index]])
        }
    }

    func restoreAll() {
        selection = .none
        mutate { $0.segments = [TimeSpan(start: 0, end: self.duration)] }
    }

    private static func merged(_ spans: [TimeSpan]) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, span.start <= last.end + 0.001 {
                last.end = max(last.end, span.end)
                result[result.count - 1] = last
            } else {
                result.append(span)
            }
        }
        return result
    }

    // MARK: Zooms

    func addZoom() {
        let start = min(currentTime, max(0, duration - 0.6))
        let zoom = ZoomSegment(start: start, end: min(duration, start + 3))
        mutate { edit in
            edit.zooms.append(zoom)
            edit.zooms.sort { $0.start < $1.start }
        }
        selection = .zoom(zoom.id)
        tab = .zoom
    }

    func autoZoom() {
        let zooms = AutoZoom.generate(clicks: recording.clicks, duration: duration)
        selection = .none
        mutate { $0.zooms = zooms }
    }

    func clearZooms() {
        selection = .none
        mutate { $0.zooms = [] }
    }

    func updateZoom(_ id: UUID, key: String, _ change: (inout ZoomSegment) -> Void) {
        mutate("\(key)-\(id)") { edit in
            guard let index = edit.zooms.firstIndex(where: { $0.id == id }) else { return }
            var zoom = edit.zooms[index]
            change(&zoom)
            zoom.start = max(0, zoom.start)
            zoom.end = min(self.duration, max(zoom.end, zoom.start + 0.4))
            edit.zooms[index] = zoom
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        recording.edit = edit
        try? store.save(recording, in: directory)
    }

    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recording.title else { return }
        recording.title = trimmed
        saveNow()
    }

    // MARK: - Transcript

    /// The transcript line under the playhead.
    var activeLineID: UUID? { transcript?.segment(at: currentTime)?.id }

    func loadLanguages() async {
        guard languages.isEmpty else { return }
        languages = await Transcriber.languages()
    }

    func createTranscript(language: String) {
        guard transcription == nil else { return }
        transcription = TranscriptionJob(progress: 0, status: "Getting ready…")
        transcriptError = nil
        let recording = recording
        let directory = directory
        transcribeTask = Task {
            do {
                let result = try await Transcriber.transcribe(recording: recording, directory: directory, language: language) { [weak self] progress, status in
                    Task { @MainActor in
                        if self?.transcription != nil { self?.transcription = TranscriptionJob(progress: progress, status: status) }
                    }
                }
                transcript = result
                try? store.saveTranscript(result, in: directory)
                restyle()
            } catch is CancellationError {
                // Cancelled by the user.
            } catch {
                transcriptError = error.localizedDescription
            }
            transcription = nil
        }
    }

    func cancelTranscription() {
        transcribeTask?.cancel()
    }

    /// Throws the transcript away so a new one can be made (e.g. in another language).
    func discardTranscript() {
        transcript = nil
        store.deleteTranscript(in: directory)
        if edit.captions { mutate { $0.captions = false } } else { restyle() }
    }

    /// The transcript as it applies to the edited video: cut parts left out,
    /// times matching the export.
    var editedLines: [TranscriptSegment] { transcript?.edited(with: timeMap) ?? [] }

    func isCut(_ line: TranscriptSegment) -> Bool {
        let middle = (line.start + line.end) / 2
        return !edit.segments.contains { $0.contains(middle) }
    }

    func close() {
        transcribeTask?.cancel()
        exportTask?.cancel()
        saveNow()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Export

    func export(to url: URL, settings: ExportSettings) {
        guard let media, exportProgress == nil else { return }
        pause()
        exportProgress = 0
        exportError = nil
        exportedURL = nil
        let edit = edit
        let recording = recording
        let captions = transcript?.segments ?? []
        exportTask = Task {
            do {
                let size = CompositionBuilder.canvasSize(aspect: edit.aspect, source: media.screenSize, longSide: settings.longSide)
                let built = try CompositionBuilder.build(media: media, recording: recording, edit: edit,
                                                         renderSize: size, fps: Int32(settings.fps), captions: captions)
                try await Exporter.export(built, to: url, codec: settings.codec) { [weak self] progress in
                    Task { @MainActor in
                        if self?.exportProgress != nil { self?.exportProgress = progress }
                    }
                }
                exportedURL = url
            } catch is CancellationError {
                // Cancelled by the user; nothing to report.
            } catch {
                exportError = error.localizedDescription
            }
            exportProgress = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// The composed frame at the playhead, exactly as preview and export draw it.
    func renderedFrame() async -> CGImage? {
        guard let built else { return nil }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: timeMap.composition(fromSource: currentTime), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}

// MARK: - Windows

/// Opens one editor window per recording and keeps track of them.
@MainActor
final class EditorWindows: NSObject, NSWindowDelegate {
    static let shared = EditorWindows()

    private var windows: [UUID: NSWindow] = [:]
    private var models: [UUID: EditorModel] = [:]

    func open(_ item: LibraryEntry) {
        let quiet = DebugSnapshot.isActive
        if !quiet { NSApp.activate(ignoringOtherApps: true) }
        if let window = windows[item.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = EditorModel(item: item, store: AppState.shared.store)
        let host = NSHostingController(rootView: EditorView(model: model).preferredColorScheme(.dark))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = item.recording.title
        window.backgroundColor = NSColor(Theme.window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1040, height: 680)
        window.setContentSize(NSSize(width: 1320, height: 840))
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("editor-\(item.id.uuidString)")
        window.delegate = self
        windows[item.id] = window
        models[item.id] = model
        if quiet { window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil) }
    }

    /// Renames through the open editor, if there is one, so it does not later
    /// save over the new title. Returns false when no editor is open.
    func rename(id: UUID, to title: String) -> Bool {
        guard let model = models[id] else { return false }
        model.rename(title)
        windows[id]?.title = title
        return true
    }

    func close(id: UUID) {
        windows[id]?.close()
    }

    func model(for id: UUID) -> EditorModel? { models[id] }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        models[id]?.close()
        models[id] = nil
        windows[id] = nil
        AppState.shared.reloadLibrary()
    }
}
