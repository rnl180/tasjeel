import CoreGraphics
import XCTest
@testable import TasjeelCore

final class ProjectMemoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tasjeel-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static var examples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/studio")
    }

    private func sample() -> ProjectMemory {
        ProjectMemory(name: "Orbit", kind: .app, summary: "A video editor for the Mac.", audience: "People who make tutorials.",
                      voice: "Plain and confident.", features: ["Exports in 4K", "Captions in 50 languages"],
                      facts: ["12,000 teams use it"], links: ["orbit.example.com"], accent: "#5B8CFF", logo: "assets/logo.svg",
                      app: .init(platforms: ["Mac", "Web"], window: "Orbit", address: "https://app.orbit.example.com",
                                 guide: "The export screen is under File › Export."),
                      notes: "Launching in March.")
    }

    // MARK: - Memory

    func testMemoryIsKeptAndWrittenAsABrief() throws {
        let project = try ProjectFolder.create(named: "Orbit", in: root)
        XCTAssertEqual(project.folderName, "Orbit")
        XCTAssertTrue(project.loadMemory().isEmpty)
        XCTAssertTrue(try String(contentsOf: project.briefURL, encoding: .utf8).contains("Nothing has been written down about this project yet."))

        try project.save(sample())
        XCTAssertEqual(project.loadMemory(), sample())
        XCTAssertFalse(project.loadMemory().isEmpty)

        let brief = try String(contentsOf: project.briefURL, encoding: .utf8)
        XCTAssertTrue(brief.hasPrefix("# Orbit\n"))
        for expected in ["A video editor for the Mac.", "Kind of project: an app (Mac, Web).", "## Who it is for", "- Exports in 4K",
                         "## Facts that are true and may be shown\n\n- 12,000 teams use it", "- Logo: `assets/logo.svg`", "- Accent colour: #5B8CFF",
                         "On this Mac its window is called: Orbit", "The export screen is under File › Export.", "Launching in March.",
                         "## For AI agents", "--screenshot \"Orbit\"", "Never invent a customer's words"] {
            XCTAssertTrue(brief.contains(expected), "missing: \(expected)")
        }
        XCTAssertFalse(brief.contains("Background colour"), "what was not filled in is left out")
        XCTAssertFalse(brief.contains(NSHomeDirectory()), "the brief is meant to be handed on, so it does not carry the home folder's name")

        XCTAssertEqual(ProjectFolder.all(in: root), [project])
        XCTAssertEqual(try ProjectFolder.create(named: "Orbit", in: root).folderName, "Orbit 2")
        XCTAssertEqual(try ProjectFolder.create(named: "A/B: Test", in: root).folderName, "A-B- Test")
    }

    func testOlderAndPartialMemoryFilesStillOpen() throws {
        let project = ProjectFolder(directory: root.appendingPathComponent("Old"))
        try FileManager.default.createDirectory(at: project.directory, withIntermediateDirectories: true)
        try #"{"name": "Old", "kind": "robot", "features": ["One"], "somethingNew": true}"#.write(to: project.memoryURL, atomically: true, encoding: .utf8)
        let memory = project.loadMemory()
        XCTAssertEqual(memory.name, "Old")
        XCTAssertEqual(memory.kind, .other, "a kind this version does not know")
        XCTAssertEqual(memory.features, ["One"])
        XCTAssertEqual(memory.app, .init())
    }

    func testRememberingSkipsWhatIsAlreadyKnown() throws {
        let project = try ProjectFolder.create(named: "Orbit", in: root)
        try project.save(sample())
        let added = try project.remember(["The audience is clinic owners.", "  12,000 teams use it.  ", "exports in 4k", "ok", ""])
        XCTAssertEqual(added, ["The audience is clinic owners."], "facts and features already written down are not repeated")
        XCTAssertEqual(try project.remember(["the audience is clinic owners"]), [])
        XCTAssertEqual(project.loadMemory().learned.map(\.text), ["The audience is clinic owners."])
        XCTAssertTrue(try String(contentsOf: project.briefURL, encoding: .utf8).contains("## Learned along the way\n\n- The audience is clinic owners. ("))
    }

    func testWhatTheStudioModelReadsHasNoFilesOrCommands() {
        let known = ProjectBrief.knowledge(sample())
        XCTAssertTrue(known.contains("## How it talks\n\nPlain and confident."))
        XCTAssertFalse(known.contains("--project"))
        XCTAssertFalse(known.contains("## Files"))
        XCTAssertEqual(ProjectBrief.knowledge(ProjectMemory(name: "Empty", kind: .other)), "")
    }

    // MARK: - Assets and videos

    func testAssetsAreSharedByAProjectsVideos() async throws {
        let project = try ProjectFolder.create(named: "Orbit", in: root)
        let logo = try await project.addAsset(from: Self.examples.appendingPathComponent("logo.svg"))
        XCTAssertEqual(logo.file, "assets/logo.svg")

        let first = try project.newVideo(named: "Launch")
        let second = try project.newVideo(named: "Launch")
        XCTAssertEqual(second.name, "Launch 2")
        XCTAssertEqual(first.project, project)
        XCTAssertEqual(first.baseDirectory.resolvingSymlinksInPath(), project.directory.resolvingSymlinksInPath())
        XCTAssertEqual(first.loadChat().materials, [logo], "a new video already has the project's files")

        // Added while working on one video, there for the other.
        var chat = first.loadChat()
        let clip = try await first.addMaterial(from: Self.examples.appendingPathComponent("clip.mp4"), note: "What is said:\n[0:02] Hello")
        XCTAssertEqual(clip.file, "assets/clip.mp4")
        chat.materials.append(clip)
        chat.messages.append(StudioMessage(role: .user, text: "Hi"))
        try first.save(chat)
        XCTAssertEqual(second.loadChat().materials.map(\.file), ["assets/logo.svg", "assets/clip.mp4"])
        XCTAssertEqual(second.loadChat().messages, [], "the conversation belongs to one video")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.materialsURL.path))

        // A storyboard names files from the project's folder.
        let storyboard = #"{"title": "Launch film", "brand": {"logo": "assets/logo.svg"}, "scenes": [{"type": "screen", "video": "assets/clip.mp4", "seconds": 3}]}"#
        try first.saveStoryboard(storyboard)
        let plan = try Storyboard.plan(from: Data(storyboard.utf8), baseDirectory: first.baseDirectory)
        XCTAssertEqual(plan.clips.first?.source.lastPathComponent, "clip.mp4")
        let built = try await StudioProject.build(storyboard: first.storyboardURL, in: first.videoURL, baseDirectory: first.baseDirectory)
        XCTAssertEqual(built.scenes, 1)

        try project.writeBrief()
        let brief = try String(contentsOf: project.briefURL, encoding: .utf8)
        XCTAssertTrue(brief.contains("- `assets/logo.svg`: picture, 120 by 120"))
        XCTAssertTrue(brief.contains("- `assets/clip.mp4`: video, 0:06 long, 1280 by 800. What is said:"), "a note's first line only")
        XCTAssertFalse(brief.contains("[0:02] Hello"))
        XCTAssertTrue(brief.contains("- `videos/Launch/`: \"Launch film\" (not rendered yet)"))

        try project.removeAsset(logo)
        XCTAssertEqual(second.loadChat().materials.map(\.file), ["assets/clip.mp4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.directory.appendingPathComponent("assets/logo.svg").path))
    }

    func testAScreenshotBecomesAnAsset() throws {
        let project = try ProjectFolder.create(named: "Orbit", in: root)
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let first = try project.addPicture(image, named: "Orbit — Settings", note: "A screenshot of Orbit.")
        let again = try project.addPicture(image, named: "Orbit — Settings", note: nil)
        XCTAssertEqual(first.file, "assets/orbit-settings.png")
        XCTAssertEqual(again.file, "assets/orbit-settings-2.png")
        XCTAssertEqual([first.width, first.height], [300, 200])
        XCTAssertEqual(project.loadAssets().count, 2)
        XCTAssertEqual(StudioWorkspace.pictureSize(project.directory.appendingPathComponent(first.file)), CGSize(width: 300, height: 200))
    }

    func testVideosMadeBeforeProjectsAreKept() async throws {
        // A video as the first Studio version kept it: loose, with its own materials.
        let loose = try StudioWorkspace.create(in: root, named: "Launch")
        let logo = try await loose.addMaterial(from: Self.examples.appendingPathComponent("logo.svg"))
        XCTAssertEqual(logo.file, "materials/logo.svg")
        let storyboard = #"{"brand": {"name": "Orbit", "logo": "materials/logo.svg"}, "scenes": [{"type": "hook", "text": "Hi"}]}"#
        try loose.saveStoryboard(storyboard)
        try loose.save(StudioChat(messages: [StudioMessage(role: .assistant, text: "Here.", storyboard: storyboard)], materials: [logo]))
        // An empty one, never used, is simply cleared away.
        _ = try StudioWorkspace.create(in: root, named: "Video")

        ProjectFolder.adoptLooseVideos(in: root)
        ProjectFolder.adoptLooseVideos(in: root)   // doing it again changes nothing

        let projects = ProjectFolder.all(in: root)
        XCTAssertEqual(projects.map(\.folderName), ["Launch"])
        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project.loadMemory().name, "Orbit", "named after the brand in its storyboard")
        XCTAssertEqual(project.loadAssets().map(\.file), ["assets/logo.svg"])
        let video = try XCTUnwrap(project.videos().first)
        XCTAssertEqual(video.name, "Launch")
        XCTAssertEqual(video.loadChat().messages.count, 1)
        XCTAssertTrue(video.loadChat().messages[0].storyboard?.contains("assets/logo.svg") == true)
        let moved = try XCTUnwrap(video.loadStoryboard())
        XCTAssertNoThrow(try Storyboard.plan(from: Data(moved.utf8), baseDirectory: video.baseDirectory), "its storyboard still builds")
    }

    // MARK: - In the chat

    func testTheWriterIsToldWhatIsRememberedAndCanAddToIt() async throws {
        let answer = """
        Done. I wrote it for clinic owners.

        ```json
        {"scenes": [{"type": "hook", "text": "Fewer no-shows."}]}
        ```

        ```remember
        - The audience is clinic owners in the Gulf.
        They never want the word "AI" on screen.
        ```
        """
        let model = OneAnswer(answer)
        let result = try await StoryboardWriter.answer(messages: [StudioMessage(role: .user, text: "For clinic owners, and never say AI")],
                                                       materials: [], storyboard: nil, directory: root,
                                                       memory: ProjectBrief.knowledge(sample()), model: model)
        XCTAssertEqual(result.reply, "Done. I wrote it for clinic owners.")
        XCTAssertNotNil(result.storyboard)
        XCTAssertEqual(result.remembered, ["The audience is clinic owners in the Gulf.", "They never want the word \"AI\" on screen."])

        XCTAssertTrue(model.prompt.hasPrefix("# About the project\n\nA video editor for the Mac."))
        XCTAssertTrue(model.prompt.contains("- 12,000 teams use it"))
        XCTAssertTrue(model.system.contains("```remember"))

        // Only something to remember, no storyboard and no words: still an answer.
        let quiet = try await StoryboardWriter.answer(messages: [StudioMessage(role: .user, text: "We have 40 staff")], materials: [],
                                                      storyboard: nil, directory: root, model: OneAnswer("```remember\nThe company has 40 staff.\n```"))
        XCTAssertEqual(quiet.remembered, ["The company has 40 staff."])
        XCTAssertNil(quiet.storyboard)

        XCTAssertEqual(StoryboardWriter.Reply.visible("Done.\n\n```remember\nThe aud"), "Done.", "the block is never shown as chat text")

        let small = StoryboardWriter.Prompt.request(messages: [StudioMessage(role: .user, text: "Go")], materials: [], storyboard: nil,
                                                    memory: String(repeating: "word ", count: 3000), labels: [:], budget: 6000)
        XCTAssertLessThan(small.count, 3000, "a long memory does not crowd out the request for a small model")
    }

    func testWindowsAreFoundByWhatAPersonCallsThem() {
        // Matching is by name only, so it can be checked without any real windows.
        XCTAssertNil(CaptureSources.window(matching: "  ", in: []))
        XCTAssertNil(CaptureSources.window(matching: "Safari", in: []))
    }
}

private final class OneAnswer: TextModel, @unchecked Sendable {
    private let answer: String
    private let lock = NSLock()
    private var seen = (system: "", prompt: "")

    init(_ answer: String) { self.answer = answer }

    var displayName: String { "Scripted" }
    var transcriptBudget: Int { 100_000 }
    var isCloud: Bool { false }
    var system: String { lock.withLock { seen.system } }
    var prompt: String { lock.withLock { seen.prompt } }

    func generate(system: String, prompt: String, schema: String, progress: @escaping @Sendable (Int) -> Void) async throws -> String { "" }

    func write(system: String, prompt: String, images: [ModelImage], partial: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.withLock { seen = (system, prompt) }
        partial(answer)
        return answer
    }
}
