import CoreGraphics
import ImageIO
import XCTest
@testable import TasjeelCore

final class StudioTests: XCTestCase {
    private var folder: URL!
    private var workspace: StudioWorkspace!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tasjeel-studio-\(UUID().uuidString)")
        workspace = StudioWorkspace(directory: folder.appendingPathComponent("Launch"))
        try workspace.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - The project folder

    func testMaterialsAreCopiedInWithPlainNames() async throws {
        let picture = try makePicture(named: "Résumé Screen (2).PNG", width: 320, height: 200)
        let first = try await workspace.addMaterial(from: picture)
        XCTAssertEqual(first.file, "materials/resume-screen-2.png", "a name a model can copy without mistakes")
        XCTAssertEqual(first.kind, .picture)
        XCTAssertEqual([first.width, first.height], [320, 200])
        XCTAssertNil(first.seconds)

        let again = try await workspace.addMaterial(from: picture)
        XCTAssertEqual(again.file, "materials/resume-screen-2-2.png", "a second copy does not replace the first")

        let arabic = try makePicture(named: "لقطة.png", width: 64, height: 64)
        let fallback = try await workspace.addMaterial(from: arabic)
        XCTAssertEqual(fallback.file, "materials/picture.png")

        let clip = try await workspace.addMaterial(from: Self.exampleClip, named: "Weekly demo", note: "What is said")
        XCTAssertEqual(clip.file, "materials/weekly-demo.mp4")
        XCTAssertEqual(clip.kind, .video)
        XCTAssertEqual(clip.seconds, 6)
        XCTAssertEqual([clip.width, clip.height], [1280, 800])
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.directory.appendingPathComponent(clip.file).path))
    }

    func testOtherFilesAreTurnedAway() async throws {
        let notes = folder.appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)
        do {
            _ = try await workspace.addMaterial(from: notes)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("notes.txt"), error.localizedDescription)
        }

        let fake = folder.appendingPathComponent("broken.png")
        try "not a picture".write(to: fake, atomically: true, encoding: .utf8)
        do {
            _ = try await workspace.addMaterial(from: fake)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be opened"), error.localizedDescription)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.materialsURL.path), [], "nothing half-added is left behind")
    }

    func testChatAndStoryboardAreRemembered() async throws {
        let picture = try await workspace.addMaterial(from: makePicture(named: "shot.png", width: 100, height: 80))
        let gone = StudioMaterial(file: "materials/deleted.png", kind: .picture, width: 1, height: 1)
        let chat = StudioChat(messages: [StudioMessage(role: .user, text: "A launch video"),
                                         StudioMessage(role: .assistant, text: "Here it is.", storyboard: "{}", problems: ["x"])],
                              materials: [picture, gone])
        try workspace.save(chat)
        XCTAssertNil(workspace.loadStoryboard())
        try workspace.saveStoryboard("{ \"scenes\": [] }")

        let loaded = workspace.loadChat()
        XCTAssertEqual(loaded.messages.map(\.text), ["A launch video", "Here it is."])
        XCTAssertEqual(loaded.messages.last?.storyboard, "{}")
        XCTAssertEqual(loaded.materials, [picture], "a material deleted in the Finder is forgotten")
        XCTAssertEqual(workspace.loadStoryboard(), "{ \"scenes\": [] }")

        XCTAssertEqual(StudioWorkspace.all(in: folder), [workspace])
        let second = try StudioWorkspace.create(in: folder, named: "Launch")
        XCTAssertEqual(second.name, "Launch 2")
    }

    func testPicturesForTheModelAreSmallAndLabelled() async throws {
        let big = try await workspace.addMaterial(from: makePicture(named: "wide.png", width: 3000, height: 1500))
        let clip = try await workspace.addMaterial(from: Self.exampleClip)
        let looks = await workspace.looks(at: [big, clip])

        XCTAssertEqual(looks.images.count, 2, "one of the picture, one frame of a short video")
        XCTAssertEqual(looks.labels[big.file], ["picture 1"])
        XCTAssertEqual(looks.labels[clip.file], ["picture 2 (a frame at 0:00)"])
        let first = try XCTUnwrap(looks.images.first)
        XCTAssertEqual(first.mediaType, "image/jpeg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(first.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 1024)

        // A drawing has no pixels of its own; it is drawn for the model.
        let logo = try await workspace.addMaterial(from: Self.exampleClip.deletingLastPathComponent().appendingPathComponent("logo.svg"))
        XCTAssertEqual([logo.width, logo.height], [120, 120])
        let drawn = await workspace.looks(at: [logo])
        XCTAssertEqual(drawn.images.count, 1)
        XCTAssertGreaterThan(drawn.images.first?.data.count ?? 0, 1000)

        let capped = await workspace.looks(at: [big, clip], limit: 1)
        XCTAssertEqual(capped.images.count, 1)
        XCTAssertNil(capped.labels[clip.file])
    }

    // MARK: - Writing a storyboard

    func testRequestTellsTheModelWhatItHas() async throws {
        let (picture, clip) = try await materials()
        let model = ScriptedWriter(["Sure."])
        let messages = [StudioMessage(role: .user, text: "A launch video for Orbit"),
                        StudioMessage(role: .assistant, text: "Here is a first version.", storyboard: "{}"),
                        StudioMessage(role: .user, text: "Make the intro shorter")]
        _ = try await StoryboardWriter.answer(messages: messages, materials: [picture, clip], storyboard: "{ \"scenes\": [1] }",
                                              directory: workspace.directory, model: model)

        let call = try XCTUnwrap(model.calls.first)
        XCTAssertTrue(call.system.contains("\"hook\""))
        XCTAssertTrue(call.system.contains("Never invent a customer's words"))
        XCTAssertTrue(call.prompt.contains("- \"materials/shot.png\": a picture, 400 by 300."))
        XCTAssertTrue(call.prompt.contains("- \"materials/demo.mp4\": a video, 6 seconds long, 1280 by 800."))
        XCTAssertTrue(call.prompt.contains("[0:04] Now press Export"), "what is said in a recording, so the model can pick the part to show")
        XCTAssertTrue(call.prompt.contains("```json\n{ \"scenes\": [1] }\n```"))
        XCTAssertTrue(call.prompt.contains("Person: A launch video for Orbit\n\nYou: Here is a first version."))
        XCTAssertTrue(call.prompt.hasSuffix("# The person's new message\n\nMake the intro shorter"))
        XCTAssertFalse(call.prompt.contains("Shown to you"), "this model cannot see")
        XCTAssertEqual(call.images, 0)
    }

    func testModelsThatSeeAreShownThePictures() async throws {
        let (picture, clip) = try await materials()
        let looks = await workspace.looks(at: [picture, clip])
        let model = ScriptedWriter(["Sure."], sees: true)
        _ = try await StoryboardWriter.answer(messages: [StudioMessage(role: .user, text: "Go")], materials: [picture, clip],
                                              storyboard: nil, directory: workspace.directory, model: model, looks: looks)
        let call = try XCTUnwrap(model.calls.first)
        XCTAssertEqual(call.images, 2)
        XCTAssertTrue(call.prompt.contains("a picture, 400 by 300. Shown to you as picture 1."))
        XCTAssertTrue(call.prompt.contains("Shown to you as picture 2 (a frame at 0:00)."))
        XCTAssertTrue(call.prompt.contains("There is none yet."))
    }

    func testAGoodStoryboardIsAcceptedAndWrittenReadably() async throws {
        let (picture, clip) = try await materials()
        let model = ScriptedWriter(["Here is a first version.\n\n```json\n\(Self.good)\n```"])
        let partials = Collected()
        let answer = try await StoryboardWriter.answer(messages: [StudioMessage(role: .user, text: "A launch video")],
                                                       materials: [picture, clip], storyboard: nil, directory: workspace.directory,
                                                       model: model) { partials.add($0) }
        XCTAssertEqual(answer.reply, "Here is a first version.")
        XCTAssertEqual(answer.problems, [])
        let text = try XCTUnwrap(answer.storyboard)
        XCTAssertTrue(text.hasPrefix("{\n  \"title\": \"Orbit launch\","), text)
        XCTAssertTrue(text.contains("{ \"type\": \"hook\", \"text\": \"Export in 4K.\" }"), "a scene starts with its type")
        XCTAssertEqual(partials.values.last, "Here is a first version.", "the storyboard itself is never shown as chat text")
        XCTAssertEqual(model.calls.count, 1)

        // What was written builds.
        let plan = try Storyboard.plan(from: Data(text.utf8), baseDirectory: workspace.directory)
        XCTAssertEqual(plan.sceneCount, 4)
        let outline = Storyboard.outline(of: plan)
        XCTAssertEqual(outline.title, "Orbit launch")
        XCTAssertEqual(outline.accent, "#5B8CFF")
        XCTAssertEqual(outline.scenes.map(\.label), ["Opening line", "Recording", "Feature", "Call to action"])
        XCTAssertEqual(outline.scenes[1].media?.lastPathComponent, "demo.mp4")
        XCTAssertEqual(outline.scenes[1].start, 1)
        XCTAssertEqual(outline.scenes[2].media?.lastPathComponent, "shot.png")
        XCTAssertEqual(outline.scenes[2].detail, "Wide, square and tall")
        XCTAssertEqual(outline.seconds, 15.5)
    }

    func testAFaultyStoryboardGoesBackWithWhatIsWrong() async throws {
        let (picture, clip) = try await materials()
        // A field that does not exist, then (once that is fixed) a scene
        // longer than its clip, then a good one.
        let unknownField = Self.good.replacingOccurrences(of: "\"type\": \"cta\",", with: "\"type\": \"cta\", \"button\": \"Go\",")
        let tooLong = Self.good.replacingOccurrences(of: "\"seconds\": 4", with: "\"seconds\": 9")
        let model = ScriptedWriter(["First reply.\n```json\n\(unknownField)\n```",
                                    "```json\n\(tooLong)\n```",
                                    "Final reply.\n```json\n\(Self.good)\n```"])
        let answer = try await StoryboardWriter.answer(messages: [StudioMessage(role: .user, text: "A launch video")],
                                                       materials: [picture, clip], storyboard: nil, directory: workspace.directory, model: model)
        XCTAssertNotNil(answer.storyboard)
        XCTAssertEqual(answer.reply, "Final reply.")
        XCTAssertEqual(model.calls.count, 3)
        XCTAssertTrue(model.calls[1].prompt.contains("- Scene 4 (cta): \"button\" is not a field Tasjeel knows."))
        XCTAssertTrue(model.calls[1].prompt.contains("First reply."), "the model sees the answer it is correcting")
        XCTAssertTrue(model.calls[2].prompt.contains("is only 6 s long"))
        XCTAssertFalse(model.calls[2].prompt.contains("\"button\""), "only the latest attempt is sent back")
    }

    func testAStoryboardThatStaysFaultyIsNotUsed() async throws {
        let (picture, clip) = try await materials()
        let missingFile = Self.good.replacingOccurrences(of: "materials/shot.png", with: "materials/hero.png")
        let model = ScriptedWriter(["I used your hero image.\n```json\n\(missingFile)\n```"])
        let answer = try await StoryboardWriter.answer(messages: [StudioMessage(role: .user, text: "A launch video")],
                                                       materials: [picture, clip], storyboard: nil, directory: workspace.directory, model: model)
        XCTAssertNil(answer.storyboard, "a storyboard that cannot be built never replaces the current one")
        XCTAssertEqual(answer.reply, "I used your hero image.")
        XCTAssertEqual(answer.problems.count, 1)
        XCTAssertTrue(answer.problems[0].contains("\"materials/hero.png\" was not found"), answer.problems[0])
        XCTAssertEqual(model.calls.count, 3, "asked to fix it twice, then given up on")
    }

    func testAQuestionChangesNothing() async throws {
        let model = ScriptedWriter(["Who is the video for?"])
        let answer = try await StoryboardWriter.answer(messages: [StudioMessage(role: .user, text: "Make a video")], materials: [],
                                                       storyboard: nil, directory: workspace.directory, model: model)
        XCTAssertEqual(answer, StoryboardWriter.Answer(reply: "Who is the video for?"))

        do {
            _ = try await StoryboardWriter.answer(messages: [StudioMessage(role: .user, text: "Hi")], materials: [], storyboard: nil,
                                                  directory: workspace.directory, model: ScriptedWriter(["  \n"]))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? StoryboardWriter.WriterError, .silent)
        }
    }

    func testAnswersAreReadHoweverTheModelLaysThemOut() {
        let board = #"{"scenes": [{"type": "hook", "text": "Hi"}]}"#

        let fenced = StoryboardWriter.Reply("Done.\n\n```json\n\(board)\n```\nAnything else?")
        XCTAssertEqual(fenced.reply, "Done.\n\n\nAnything else?")
        XCTAssertNotNil(fenced.storyboard)

        let bare = StoryboardWriter.Reply("Done.\n\(board)")
        XCTAssertEqual(bare.reply, "Done.")
        XCTAssertNotNil(bare.storyboard)

        let wrapped = StoryboardWriter.Reply("```\n{\"storyboard\": \(board)}\n```")
        XCTAssertEqual(wrapped.reply, "")
        XCTAssertEqual((wrapped.storyboard?["scenes"] as? [Any])?.count, 1)

        let thinking = StoryboardWriter.Reply("<think>Let me plan {this}.</think>Done.\n```json\n\(board)\n```")
        XCTAssertEqual(thinking.reply, "Done.")

        let code = StoryboardWriter.Reply("Use `npm run dev`:\n```\nnpm run dev\n```")
        XCTAssertNil(code.storyboard, "a block that is not a storyboard is left in the reply")
        XCTAssertTrue(code.reply.contains("npm run dev"))

        XCTAssertEqual(StoryboardWriter.Reply.visible("Here it is.\n\n```json\n{\"sce"), "Here it is.")
        XCTAssertEqual(StoryboardWriter.Reply.visible("<think>hmm"), "")
        XCTAssertEqual(StoryboardWriter.Reply.visible("<think>hmm</think>Here"), "Here")
    }

    func testLongChatsAreTrimmedForSmallModels() {
        let messages = (0 ..< 30).flatMap { [StudioMessage(role: .user, text: "Request \($0) " + String(repeating: "x", count: 400)),
                                             StudioMessage(role: .assistant, text: "Answer \($0)")] }
            + [StudioMessage(role: .user, text: "The newest request")]
        let small = StoryboardWriter.Prompt.request(messages: messages, materials: [], storyboard: nil, labels: [:], budget: 9000)
        XCTAssertFalse(small.contains("Request 0 "), "the oldest lines go first")
        XCTAssertTrue(small.contains("Answer 29"))
        XCTAssertTrue(small.hasSuffix("The newest request"))

        let large = StoryboardWriter.Prompt.request(messages: messages, materials: [], storyboard: nil, labels: [:], budget: 1_000_000)
        XCTAssertTrue(large.contains("Request 10 "))

        let note = String(repeating: "word ", count: 2000)
        let material = StudioMaterial(file: "materials/a.mp4", kind: .video, width: 10, height: 10, seconds: 12.5, note: note)
        let trimmed = StoryboardWriter.Prompt.describe(material, shown: [], noteBudget: 500)
        XCTAssertTrue(trimmed.contains("12.5 seconds long"))
        XCTAssertTrue(trimmed.hasSuffix("[…]"))
        XCTAssertLessThan(trimmed.count, 700)
    }

    func testRecordingNotesSayWhatIsSaidWhen() {
        let transcript = Transcript(language: "en", segments: [TranscriptSegment(start: 0, end: 3, text: "Welcome"),
                                                               TranscriptSegment(start: 65, end: 70, text: "Now press Export")])
        let note = StoryboardWriter.note(forRecording: "Weekly demo", transcript: transcript, notes: nil)
        XCTAssertTrue(note.hasPrefix("A Tasjeel screen recording called \"Weekly demo\"."))
        XCTAssertTrue(note.contains("[0:00] Welcome\n[1:05] Now press Export"))
    }

    func testStoryboardTextReadsBackTheSame() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.good.utf8)) as? [String: Any])
        let text = Storyboard.text(for: original)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(back as NSDictionary, original as NSDictionary)
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertLessThan(text.split(separator: "\n").map(\.count).max() ?? 0, 110, "no line a person has to scroll sideways to read")
    }

    // MARK: - Engines

    func testTheStudioWritesWithClaudeOrOllama() {
        let nothing = AIAvailability(appleProblem: nil, appleLanguages: ["en"])
        guard case .unavailable(let reason) = AIEngines.chooseWriter(.automatic, ollamaModel: "", found: nothing) else {
            return XCTFail("the model built into macOS is too small to write a storyboard")
        }
        XCTAssertTrue(reason.contains("Claude"))

        let local = AIAvailability(ollamaRunning: true, ollamaModels: ["gemma4:12b"], hasClaudeKey: true)
        XCTAssertEqual(AIEngines.chooseWriter(.automatic, ollamaModel: "", found: local), .ollama(model: "gemma4:12b"),
                       "Automatic never picks the cloud, even with a key saved")
        XCTAssertEqual(AIEngines.chooseWriter(.apple, ollamaModel: "", found: local), .ollama(model: "gemma4:12b"))
        XCTAssertEqual(AIEngines.chooseWriter(.claude, ollamaModel: "", found: local), .claude)

        guard case .unavailable = AIEngines.chooseWriter(.claude, ollamaModel: "", found: AIAvailability(ollamaRunning: true, ollamaModels: ["a"])) else {
            return XCTFail("Claude was chosen, so a missing key is said, not worked around")
        }
        guard case .unavailable(let stopped) = AIEngines.chooseWriter(.ollama, ollamaModel: "", found: AIAvailability()) else { return XCTFail() }
        XCTAssertTrue(stopped.contains("Ollama is not running"))
    }

    func testClaudeIsSentThePicturesBeforeTheWords() async throws {
        let server = try StubServer { _ in
            .lines([
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Here "}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"it is."}}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            ], contentType: "text/event-stream")
        }
        defer { server.stop() }

        let model = ClaudeModel(apiKey: "test-key-not-real", baseURL: server.url)
        XCTAssertTrue(model.seesImages)
        let partials = Collected()
        let images = [ModelImage(mediaType: "image/jpeg", data: Data([1, 2, 3])), ModelImage(mediaType: "image/png", data: Data([4, 5]))]
        let text = try await model.write(system: "SYS", prompt: "PROMPT", images: images) { partials.add($0) }
        XCTAssertEqual(text, "Here it is.")
        XCTAssertEqual(partials.values, ["Here ", "Here it is."])

        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(request.headers["x-api-key"], "test-key-not-real")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil((body["output_config"] as? [String: Any])?["format"], "a chat answer is free text, not a form")

        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, "SYS")
        XCTAssertEqual((system.first?["cache_control"] as? [String: String])?["type"], "ephemeral")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "image", "text"])
        let source = try XCTUnwrap(content[0]["source"] as? [String: String])
        XCTAssertEqual(source, ["type": "base64", "media_type": "image/jpeg", "data": Data([1, 2, 3]).base64EncodedString()])
        XCTAssertNil(content[0]["cache_control"])
        XCTAssertEqual((content[1]["cache_control"] as? [String: String])?["type"], "ephemeral", "the pictures are the same every turn")
        XCTAssertEqual(content[2]["text"] as? String, "PROMPT")
        XCTAssertNil(content[2]["cache_control"])
    }

    func testADeclinedRequestIsSaidPlainly() async throws {
        let server = try StubServer { _ in
            .lines([#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#], contentType: "text/event-stream")
        }
        defer { server.stop() }
        do {
            _ = try await StoryboardWriter.answer(messages: [StudioMessage(role: .user, text: "x")], materials: [], storyboard: nil,
                                                  directory: workspace.directory, model: ClaudeModel(apiKey: "k", baseURL: server.url))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? StoryboardWriter.WriterError, .declined)
            XCTAssertFalse(error.localizedDescription.contains("notes"))
        }
    }

    // MARK: - Rendering

    func testNodeIsFoundWhereItIsUsuallyInstalled() throws {
        let home = folder.appendingPathComponent("home")
        for version in ["v18.20.1", "v22.3.0", "v9.0.0"] {
            let bin = home.appendingPathComponent(".nvm/versions/node/\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for tool in ["node", "npm"] {
                let url = bin.appendingPathComponent(tool)
                try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        let folders = StudioRenderer.searchFolders(home: home, environment: ["PATH": "/first:/second"])
        XCTAssertEqual(Array(folders.prefix(2)), ["/first", "/second"], "what a terminal would use comes first")
        XCTAssertTrue(folders.contains("/opt/homebrew/bin"))

        // Only the folders made here, so the test does not depend on this Mac.
        let ours = folders.filter { $0.hasPrefix(home.path) }
        let node = try XCTUnwrap(StudioRenderer.findNode(in: ours))
        XCTAssertTrue(node.directory.hasSuffix("v22.3.0/bin"), "the newest version, compared as numbers")
        XCTAssertTrue(node.path.hasPrefix(node.directory + ":/usr/bin:/bin"))
        XCTAssertNil(StudioRenderer.findNode(in: ["/nowhere"]))
    }

    func testRenderProgressIsReadFromRemotionsOutput() throws {
        XCTAssertEqual(try XCTUnwrap(StudioRenderer.progress(in: "Rendered 60/120, time remaining: 3s")).fraction ?? 0, 0.45, accuracy: 0.001)
        XCTAssertEqual(StudioRenderer.progress(in: "Rendered 60/120")?.label, "Drawing the frames…")
        XCTAssertEqual(try XCTUnwrap(StudioRenderer.progress(in: "Encoded 120/120")).fraction ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(StudioRenderer.progress(in: "Bundling 40%")?.label, "Preparing…")
        XCTAssertNotNil(StudioRenderer.progress(in: "Downloading Chrome Headless Shell - 12 Mb/90 Mb"))
        XCTAssertNil(StudioRenderer.progress(in: "Composition          Wide"))
        XCTAssertFalse(StudioRenderer.remotionVersion.isEmpty)
        XCTAssertTrue(StudioRenderer.runtimeURL(in: folder).lastPathComponent.hasPrefix(".remotion-4."), "hidden, and named for its version")
    }

    func testToolsAreRunAndStopped() async throws {
        let lines = Collected()
        let status = try await Subprocess.run(["/bin/sh", "-c", "pwd; echo one; printf 'two\\rthree\\n' >&2; exit 3"], in: folder,
                                              environment: ["PATH": "/usr/bin:/bin"]) { lines.add($0) }
        XCTAssertEqual(status, 3)
        XCTAssertEqual(Array(lines.values.dropFirst()), ["one", "two", "three"], "a redrawn progress line counts as a line")
        XCTAssertTrue(lines.values[0].hasSuffix(folder.lastPathComponent))

        // Cancelling stops the tool and what it started, promptly.
        let started = Date()
        let task = Task {
            try await Subprocess.run(["/bin/sh", "-c", "sleep 30 & sleep 30"], in: folder, environment: ["PATH": "/usr/bin:/bin"]) { _ in }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        do {
            _ = try await Subprocess.run(["/nowhere/tool"], in: folder, environment: [:]) { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not start tool"), error.localizedDescription)
        }
    }

    // MARK: - Fixtures

    private static let good = """
    {
      "title": "Orbit launch",
      "brand": { "name": "Orbit", "accent": "#5b8cff" },
      "scenes": [
        { "type": "hook", "text": "Export in 4K." },
        { "type": "screen", "video": "materials/demo.mp4", "start": 1, "seconds": 4, "caption": "Pick a size." },
        { "type": "feature", "headline": "Made for sharing", "points": ["Wide, square and tall"], "image": "materials/shot.png" },
        { "type": "cta", "text": "Try Orbit today", "link": "orbit.example.com" }
      ]
    }
    """

    private static var exampleClip: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/studio/clip.mp4")
    }

    private func materials() async throws -> (StudioMaterial, StudioMaterial) {
        let picture = try await workspace.addMaterial(from: makePicture(named: "shot.png", width: 400, height: 300))
        let clip = try await workspace.addMaterial(from: Self.exampleClip, named: "demo", note: "What is said:\n[0:04] Now press Export")
        return (picture, clip)
    }

    private func makePicture(named name: String, width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}

// MARK: - Test doubles

/// A model that gives prepared answers (the last one again when it runs out)
/// and records what it was asked.
private final class ScriptedWriter: TextModel, @unchecked Sendable {
    struct Call {
        var system: String
        var prompt: String
        var images: Int
    }

    private let lock = NSLock()
    private var answers: [String]
    private var recorded: [Call] = []
    let seesImages: Bool

    init(_ answers: [String], sees: Bool = false) {
        self.answers = answers
        seesImages = sees
    }

    var displayName: String { "Scripted" }
    var transcriptBudget: Int { 100_000 }
    var isCloud: Bool { false }
    var calls: [Call] { lock.withLock { recorded } }

    func generate(system: String, prompt: String, schema: String, progress: @escaping @Sendable (Int) -> Void) async throws -> String {
        XCTFail("the Studio asks for free text")
        return ""
    }

    func write(system: String, prompt: String, images: [ModelImage], partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let answer = lock.withLock { () -> String in
            recorded.append(Call(system: system, prompt: prompt, images: images.count))
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        // Arrives in two pieces, like a streamed answer.
        partial(String(answer.prefix(answer.count / 2)))
        partial(answer)
        return answer
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func add(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}
