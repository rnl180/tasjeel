@preconcurrency import AVFoundation
import Foundation
import Speech

/// A language the Mac can transcribe on its own.
public struct TranscriptionLanguage: Identifiable, Hashable, Sendable {
    /// BCP 47 tag, e.g. "en-US".
    public let id: String
    public let name: String
    /// False when macOS has to download the speech model first.
    public let installed: Bool
}

public enum TranscriptionError: LocalizedError {
    case needsNewerSystem
    case unsupportedLanguage(String)
    case noAudio
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .needsNewerSystem:
            return "Transcripts need macOS 26 or later, which includes Apple's on-device speech models."
        case .unsupportedLanguage(let name):
            return "This Mac has no on-device speech model for \(name)."
        case .noAudio:
            return "This recording has no sound to transcribe."
        case .failed(let reason):
            return "The transcript could not be created: \(reason)"
        }
    }
}

/// Turns a recording's sound into text using the speech models built into
/// macOS. The audio never leaves the Mac; the only network use is macOS
/// downloading a language's model the first time that language is used.
///
/// Each audio track is transcribed on its own. Because the microphone and the
/// computer's sound were recorded separately, that also tells us who spoke:
/// microphone lines are you, system-sound lines are everyone else.
public enum Transcriber {
    public static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Every language either built-in engine can handle, sorted by name.
    public static func languages() async -> [TranscriptionLanguage] {
        guard #available(macOS 26.0, *) else { return [] }
        func tag(_ locale: Locale) -> String { locale.identifier(.bcp47) }
        let supported = Set(await SpeechTranscriber.supportedLocales.map(tag))
            .union(await DictationTranscriber.supportedLocales.map(tag))
        let installed = Set(await SpeechTranscriber.installedLocales.map(tag))
            .union(await DictationTranscriber.installedLocales.map(tag))
        return supported.map { id in
            TranscriptionLanguage(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id, installed: installed.contains(id))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The language to suggest: the first of the user's preferred languages
    /// that can be transcribed, else English.
    public static func suggestedLanguage(from languages: [TranscriptionLanguage]) -> String? {
        for preferred in Locale.preferredLanguages {
            let wanted = Locale(identifier: preferred)
            if let exact = languages.first(where: { $0.id == wanted.identifier(.bcp47) }) { return exact.id }
            if let code = wanted.language.languageCode?.identifier,
               let match = languages.first(where: { Locale(identifier: $0.id).language.languageCode?.identifier == code && $0.installed })
               ?? languages.first(where: { Locale(identifier: $0.id).language.languageCode?.identifier == code }) {
                return match.id
            }
        }
        return languages.first { $0.id == "en-US" }?.id ?? languages.first?.id
    }

    /// Transcribes every audio track of the recording. `progress` receives a
    /// fraction (0 ... 1) and a short description of the current step.
    public static func transcribe(recording: Recording, directory: URL, language: String,
                                  progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        guard #available(macOS 26.0, *) else { throw TranscriptionError.needsNewerSystem }

        let asset = AVURLAsset(url: directory.appendingPathComponent(recording.screen.file))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw TranscriptionError.noAudio }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tasjeel-transcribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let locale = Locale(identifier: language)
        let kinds: [AudioTrackKind?] = tracks.indices.map { $0 < recording.audioTracks.count ? recording.audioTracks[$0] : nil }
        // Speaker labels only mean something when there are two different sources.
        let labelled = Set(kinds.compactMap { $0 }).count > 1

        var perTrack: [(kind: AudioTrackKind?, segments: [TranscriptSegment])] = []
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let kind = kinds[index]
            let base = Double(index) / Double(tracks.count)
            let share = 1 / Double(tracks.count)
            let label: String
            switch (labelled, kind) {
            case (true, .mic): label = "Listening to your microphone…"
            case (true, .system): label = "Listening to the computer's sound…"
            default: label = "Listening…"
            }
            progress(base, label)

            // Pull this one track out into its own audio file.
            let range = try await track.load(.timeRange)
            guard range.duration.seconds > 0.2 else { continue }
            let composition = AVMutableComposition()
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(range, of: track, at: .zero)
            let audioURL = scratch.appendingPathComponent("track\(index).m4a")
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                throw TranscriptionError.failed("could not read the audio")
            }
            try await export.export(to: audioURL, as: .m4a)

            let file = try AVAudioFile(forReading: audioURL)
            let length = range.duration.seconds
            var words = try await Self.words(in: file, locale: locale, status: { progress(base, $0) }) { fraction in
                progress(base + share * min(max(fraction / length, 0), 1), label)
            }
            // The extracted file starts at zero; put the words back on the
            // recording's clock.
            let offset = range.start.seconds
            for i in words.indices {
                words[i].start += offset
                words[i].end += offset
            }
            perTrack.append((kind, TranscriptSegmenter.segments(from: words, speaker: labelled ? kind : nil)))
        }

        var segments: [TranscriptSegment] = []
        if labelled {
            let system = perTrack.filter { $0.kind == .system }.flatMap(\.segments)
            let mic = perTrack.filter { $0.kind == .mic }.flatMap(\.segments)
            segments = system + TranscriptSegmenter.removingEcho(mic: mic, system: system)
        } else {
            segments = perTrack.flatMap(\.segments)
        }
        segments.sort { $0.start < $1.start }
        progress(1, "Done")
        return Transcript(language: language, segments: segments)
    }

    // MARK: - Speech

    /// Runs one audio file through whichever engine knows the language.
    /// `heard` reports how many seconds of the file have been transcribed.
    @available(macOS 26.0, *)
    private static func words(in file: AVAudioFile, locale: Locale, status: @escaping @Sendable (String) -> Void,
                              heard: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        // The newer, more accurate long-form model first.
        if let supported = match(locale, in: await SpeechTranscriber.supportedLocales) {
            let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                           attributeOptions: [.audioTimeRange])
            try await install([module], locale: supported, status: status)
            let collector = Task {
                var words: [TimedWord] = []
                for try await result in module.results {
                    words += Self.words(from: result.text, range: result.range)
                    heard(result.range.end.seconds)
                }
                return words
            }
            return try await run([module], file: file, collector: collector)
        }
        // The dictation model covers more languages, Arabic among them.
        if let supported = match(locale, in: await DictationTranscriber.supportedLocales) {
            let module = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                              reportingOptions: [], attributeOptions: [.audioTimeRange])
            try await install([module], locale: supported, status: status)
            let collector = Task {
                var words: [TimedWord] = []
                for try await result in module.results {
                    words += Self.words(from: result.text, range: result.range)
                    heard(result.range.end.seconds)
                }
                return words
            }
            return try await run([module], file: file, collector: collector)
        }
        throw TranscriptionError.unsupportedLanguage(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
    }

    /// Finds `locale` in an engine's own list. (The system's
    /// `supportedLocale(equivalentTo:)` cannot be used for this: it returns
    /// Arabic for the engine that has no Arabic model.)
    private static func match(_ locale: Locale, in supported: [Locale]) -> Locale? {
        let tag = locale.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == tag }) { return exact }
        guard let code = locale.language.languageCode?.identifier else { return nil }
        return supported.first { $0.language.languageCode?.identifier == code }
    }

    @available(macOS 26.0, *)
    private static func install(_ modules: [any SpeechModule], locale: Locale, status: @Sendable (String) -> Void) async throws {
        // Nothing to do when the model is already on this Mac.
        let state = await AssetInventory.status(forModules: modules)
        if state == .installed { return }
        // macOS lets each app hold speech models for a limited number of
        // languages at once. Claim this one, giving up the oldest if full.
        let tag = locale.identifier(.bcp47)
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == tag }) {
            if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
                await AssetInventory.release(reservedLocale: oldest)
            }
            try await AssetInventory.reserve(locale: locale)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            status("Downloading the speech model for this language (one time)…")
            try await request.downloadAndInstall()
        }
    }

    @available(macOS 26.0, *)
    private static func run(_ modules: [any SpeechModule], file: AVAudioFile, collector: Task<[TimedWord], Error>) async throws -> [TimedWord] {
        let analyzer = SpeechAnalyzer(modules: modules)
        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            return try await collector.value
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            if error is CancellationError { throw error }
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    /// Splits a result into its timed runs (roughly, words).
    @available(macOS 26.0, *)
    private static func words(from text: AttributedString, range: CMTimeRange) -> [TimedWord] {
        var words: [TimedWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }
            if let time = run.audioTimeRange, time.start.isNumeric, time.duration.isNumeric {
                words.append(TimedWord(text: piece, start: time.start.seconds, end: time.end.seconds))
            } else if !words.isEmpty {
                // Spacing and punctuation carry no time of their own.
                words[words.count - 1].text += piece
            } else if !piece.allSatisfy(\.isWhitespace) {
                words.append(TimedWord(text: piece, start: range.start.seconds, end: range.end.seconds))
            }
        }
        if !words.isEmpty { words[0].startsResult = true }
        return TranscriptSegmenter.tightened(words)
    }
}
