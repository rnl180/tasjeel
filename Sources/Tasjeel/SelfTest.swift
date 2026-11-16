import AppKit
import AVFoundation
import Foundation
import TasjeelCore

/// Command-line entry points for development. Neither shows any UI.
enum SelfTest {
    /// `Tasjeel --import <video> [--camera <video>] [--title <text>] [--out <folder>]`
    ///
    /// Adds a video file to the library (or to `--out`) and prints its folder.
    static func importVideo() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--import") else {
            print("FAIL usage: --import <video>")
            exit(1)
        }
        Task {
            do {
                let store = ProjectStore(root: value("--out").map { URL(fileURLWithPath: $0) })
                let entry = try await store.importVideo(at: URL(fileURLWithPath: path),
                                                        camera: value("--camera").map { URL(fileURLWithPath: $0) },
                                                        title: value("--title"))
                print("OK folder=\(entry.directory.path)")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `Tasjeel --transcribe <recording folder> [--language en-US] [--save]`
    ///
    /// Transcribes a recording and prints the lines. `--save` also writes
    /// `transcript.json` into the folder, as the editor would.
    static func transcribe() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--transcribe") else {
            print("FAIL usage: --transcribe <recording folder>")
            exit(1)
        }
        Task {
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                let store = ProjectStore(root: directory.deletingLastPathComponent())
                guard let entry = store.loadAll().first(where: { $0.directory.standardizedFileURL == directory.standardizedFileURL }) else {
                    print("FAIL no recording in that folder")
                    exit(1)
                }
                let languages = await Transcriber.languages()
                let language = value("--language") ?? Transcriber.suggestedLanguage(from: languages) ?? "en-US"
                let started = Date()
                let transcript = try await Transcriber.transcribe(recording: entry.recording, directory: directory, language: language) { _, _ in }
                for line in transcript.segments {
                    let who = TranscriptFormat.speakerName(line.speaker).map { "\($0): " } ?? ""
                    print(String(format: "%6.2f-%6.2f  ", line.start, line.end) + who + line.text)
                }
                if args.contains("--save") { try store.saveTranscript(transcript, in: directory) }
                print("OK language=\(language) lines=\(transcript.segments.count) audio=\(String(format: "%.1f", entry.recording.duration))s took=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription) (\(error))")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `Tasjeel --render <recording folder> --out <file> [--size 1920] [--fps 30] [--codec h264|hevc] [--frame <seconds>]`
    ///
    /// Renders a recording with its saved edit, exactly as the editor would.
    /// With `--frame` it writes that one finished frame as a PNG; otherwise it
    /// exports the whole video. `--size 0` keeps the recording's resolution.
    static func render() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--render"), let out = value("--out") else {
            print("FAIL usage: --render <recording folder> --out <file>")
            exit(1)
        }
        Task {
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                let store = ProjectStore(root: directory.deletingLastPathComponent())
                guard let entry = store.loadAll().first(where: { $0.directory.standardizedFileURL == directory.standardizedFileURL }) else {
                    print("FAIL no recording in that folder")
                    exit(1)
                }
                let recording = entry.recording
                let longSide = value("--size").flatMap { Int($0) } ?? 0
                let fps = value("--fps").flatMap { Int32($0) } ?? 30
                let codec = value("--codec").flatMap { ExportCodec(rawValue: $0) } ?? .h264
                let media = try await CompositionBuilder.load(recording: recording, directory: directory)
                let size = CompositionBuilder.canvasSize(aspect: recording.edit.aspect, source: media.screenSize,
                                                         longSide: longSide == 0 ? nil : longSide)
                let captions = store.loadTranscript(in: directory)?.segments ?? []
                let built = try CompositionBuilder.build(media: media, recording: recording, edit: recording.edit,
                                                         renderSize: size, fps: fps, captions: captions)
                let url = URL(fileURLWithPath: out)
                let started = Date()
                if let frame = value("--frame").flatMap({ Double($0) }) {
                    let generator = AVAssetImageGenerator(asset: built.composition)
                    generator.videoComposition = built.videoComposition
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    let time = CMTime(seconds: built.timeMap.composition(fromSource: frame), preferredTimescale: 600)
                    let image = try await generator.image(at: time).image
                    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        print("FAIL could not encode the frame")
                        exit(1)
                    }
                    try png.write(to: url)
                } else {
                    try await Exporter.export(built, to: url, codec: codec) { _ in }
                }
                print("OK size=\(Int(size.width))x\(Int(size.height)) took=\(String(format: "%.1f", Date().timeIntervalSince(started)))s file=\(url.path)")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription) (\(error))")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `Tasjeel --notes <recording folder> [--engine automatic|apple|ollama|claude] [--model <ollama model>] [--save]`
    ///
    /// Writes AI notes from a recording's transcript and prints them as
    /// Markdown. For `--engine claude` the key is read from the
    /// `ANTHROPIC_API_KEY` environment variable, never from a file.
    static func notes() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--notes") else {
            print("FAIL usage: --notes <recording folder>")
            exit(1)
        }
        Task {
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                let store = ProjectStore(root: directory.deletingLastPathComponent())
                guard let entry = store.loadAll().first(where: { $0.directory.standardizedFileURL == directory.standardizedFileURL }) else {
                    print("FAIL no recording in that folder")
                    exit(1)
                }
                guard let transcript = store.loadTranscript(in: directory) else {
                    print("FAIL this recording has no transcript yet (run --transcribe ... --save first)")
                    exit(1)
                }
                let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
                let found = await AIEngines.discover(hasClaudeKey: !(key ?? "").isEmpty)
                let kind = value("--engine").flatMap { AIEngineKind(rawValue: $0) } ?? .automatic
                let choice = AIEngines.choose(kind, ollamaModel: value("--model") ?? "", language: transcript.language, found: found)
                let model = try AIEngines.model(for: choice) { key }
                let started = Date()
                let notes = try await NotesGenerator.notes(for: transcript, duration: entry.recording.duration, model: model) { _, _ in }
                print(NotesFormat.markdown(notes))
                if args.contains("--save") { try store.saveNotes(notes, in: directory) }
                print("OK engine=\(notes.engine) chapters=\(notes.chapters.count) actions=\(notes.actionItems.count) took=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `Tasjeel --remotion <recording folder> --out <project folder> [--size 1920] [--fps 30]`
    ///
    /// Exports a recording as a Remotion project, as the editor's
    /// "Remotion project…" button does.
    static func remotion() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--remotion"), let out = value("--out") else {
            print("FAIL usage: --remotion <recording folder> --out <project folder>")
            exit(1)
        }
        Task {
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                let store = ProjectStore(root: directory.deletingLastPathComponent())
                guard let entry = store.loadAll().first(where: { $0.directory.standardizedFileURL == directory.standardizedFileURL }) else {
                    print("FAIL no recording in that folder")
                    exit(1)
                }
                let recording = entry.recording
                let project = URL(fileURLWithPath: out, isDirectory: true)
                let longSide = value("--size").flatMap { Int($0) } ?? 0
                let fps = value("--fps").flatMap { Int($0) } ?? 30
                try RemotionProject.prepare(project)
                let media = try await CompositionBuilder.load(recording: recording, directory: directory)
                let size = CompositionBuilder.canvasSize(aspect: recording.edit.aspect, source: media.screenSize,
                                                         longSide: longSide == 0 ? nil : longSide)
                let built = try CompositionBuilder.build(media: media, recording: recording, edit: recording.edit,
                                                         renderSize: size, fps: Int32(fps), captions: [])
                try await Exporter.export(built, to: RemotionProject.videoURL(in: project), codec: .h264) { _ in }
                let transcript = store.loadTranscript(in: directory)
                let notes = store.loadNotes(in: directory)
                let data = try RemotionProject.data(title: recording.title, size: size, fps: fps,
                                                    duration: built.composition.duration.seconds, timeMap: built.timeMap,
                                                    transcript: transcript, notes: notes)
                let fresh = try RemotionProject.write(to: project, title: recording.title, data: data)
                print("OK \(fresh ? "created" : "updated") size=\(Int(size.width))x\(Int(size.height)) captions=\(transcript?.segments.count ?? 0) chapters=\(notes?.chapters.count ?? 0) folder=\(project.path)")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `Tasjeel --storyboard <storyboard.json> --out <project folder>`
    ///
    /// Builds a Remotion project from a storyboard file, as the app's
    /// "New Video from Storyboard…" command does. See Examples/studio.
    static func storyboard() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--storyboard"), let out = value("--out") else {
            print("FAIL usage: --storyboard <storyboard.json> --out <project folder>")
            exit(1)
        }
        Task {
            do {
                let summary = try await StudioProject.build(storyboard: URL(fileURLWithPath: path),
                                                            in: URL(fileURLWithPath: out, isDirectory: true))
                print("OK \(summary.created ? "created" : "updated") scenes=\(summary.scenes) seconds=\(String(format: "%.1f", summary.seconds)) sizes=\(summary.formats.joined(separator: ","))")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `Tasjeel --studio <project folder> [--add <file>]... [--say <message>] [--engine claude|ollama] [--model <name>] [--render <size>]`
    ///
    /// One turn of the Studio from a terminal: adds material, sends a message
    /// to the model, saves the storyboard it writes, and optionally renders a
    /// size. The folder is created if needed. For Claude the key is read from
    /// the ANTHROPIC_API_KEY environment variable; it is never an argument.
    static func studio() {
        let args = CommandLine.arguments
        func values(_ flag: String) -> [String] {
            args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
        }
        guard let folder = values("--studio").first else {
            print("FAIL usage: --studio <project folder> [--add <file>]... [--say <message>] [--engine claude|ollama] [--model <name>] [--render <size>]")
            exit(1)
        }
        Task {
            do {
                let workspace = StudioWorkspace(directory: URL(fileURLWithPath: folder, isDirectory: true))
                try workspace.prepare()
                var chat = workspace.loadChat()
                for path in values("--add") {
                    let material = try await workspace.addMaterial(from: URL(fileURLWithPath: path))
                    chat.materials.append(material)
                    print("added \(material.file) \(material.width)x\(material.height)\(material.seconds.map { " \($0)s" } ?? "")")
                }
                try workspace.save(chat)

                if let message = values("--say").first {
                    let model: any TextModel
                    switch values("--engine").first ?? "claude" {
                    case "ollama":
                        let client = OllamaClient()
                        let installed = try await client.models()
                        guard let name = values("--model").first ?? installed.first else {
                            print("FAIL Ollama has no models")
                            exit(1)
                        }
                        model = OllamaModel(name: name, client: client)
                    default:
                        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
                            print("FAIL set ANTHROPIC_API_KEY to use Claude")
                            exit(1)
                        }
                        model = ClaudeModel(apiKey: key)
                    }
                    chat.messages.append(StudioMessage(role: .user, text: message))
                    let looks = model.seesImages ? await workspace.looks(at: chat.materials) : StudioWorkspace.Looks()
                    let answer = try await StoryboardWriter.answer(messages: chat.messages, materials: chat.materials,
                                                                   storyboard: workspace.loadStoryboard(), directory: workspace.directory,
                                                                   model: model, looks: looks)
                    chat.messages.append(StudioMessage(role: .assistant, text: answer.reply, storyboard: answer.storyboard,
                                                       problems: answer.problems.isEmpty ? nil : answer.problems))
                    if let text = answer.storyboard { try workspace.saveStoryboard(text) }
                    try workspace.save(chat)
                    print("engine: \(model.displayName) pictures=\(looks.images.count)")
                    print("reply: \(answer.reply)")
                    print("storyboard: \(answer.storyboard == nil ? "unchanged" : "saved")")
                    for problem in answer.problems { print("problem: \(problem)") }
                }

                if let format = values("--render").first {
                    let summary = try await StudioProject.build(storyboard: workspace.storyboardURL, in: workspace.videoURL)
                    print("built scenes=\(summary.scenes) seconds=\(String(format: "%.1f", summary.seconds))")
                    let url = try await StudioRenderer.render(project: workspace.videoURL, format: format,
                                                              root: workspace.directory.deletingLastPathComponent()) { fraction, label in
                        print("  \(fraction.map { String(format: "%3.0f%%", $0 * 100) } ?? "  …") \(label)")
                    }
                    print("rendered \(url.lastPathComponent)")
                }
                print("OK")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `Tasjeel --selftest-record [seconds] [--mic] [--out <folder>]`
    ///
    /// Records the main display for a few seconds, pauses once in the middle,
    /// and prints what ended up on disk. Used to check the capture pipeline
    /// from a terminal that has Screen Recording permission.
    static func record() {
        let args = CommandLine.arguments
        let seconds = args.dropFirst().compactMap { Double($0) }.first ?? 3
        let useMic = args.contains("--mic")
        var root: URL?
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count { root = URL(fileURLWithPath: args[i + 1]) }

        Task { @MainActor in
            do {
                let sources = try await CaptureSources.shareable()
                guard let display = sources.displays.first else {
                    print("FAIL no display")
                    exit(1)
                }
                let store = ProjectStore(root: root)
                let options = RecordingOptions(target: .display(display.display), sourceName: display.name,
                                               excluding: sources.ownApplication, systemAudio: true, microphone: useMic)
                let session = try RecordingSession(options: options, camera: nil, store: store)
                try await session.arm()
                try await Task.sleep(nanoseconds: 400_000_000)
                try session.begin()

                // Record, pause for a second, record again: the pause must not
                // appear in the file.
                try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1_000_000_000))
                session.pause()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                session.resume()
                try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1_000_000_000))

                let elapsed = session.elapsed
                let item = try await session.finish(title: "Self test")
                let r = item.recording
                print("OK folder=\(item.directory.path)")
                print("OK duration=\(String(format: "%.2f", r.duration)) elapsed=\(String(format: "%.2f", elapsed)) size=\(r.screen.width)x\(r.screen.height) audio=\(r.audioTracks.map(\.rawValue))")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription) (\(error))")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
