import XCTest
@testable import TasjeelCore

final class NarrationTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tasjeel-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static var examples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/studio")
    }

    /// What ElevenLabs answers for "Hi there.": sound, and when each character is said.
    private static func speech(_ text: String = "Hi there.") -> String {
        let characters = text.map { String($0) }
        let starts = characters.indices.map { Double($0) * 0.1 }
        let ends = characters.indices.map { Double($0) * 0.1 + 0.1 }
        let object: [String: Any] = ["audio_base64": Data(repeating: 7, count: 400).base64EncodedString(),
                                     "alignment": ["characters": characters, "character_start_times_seconds": starts,
                                                   "character_end_times_seconds": ends]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    // MARK: - The storyboard

    func testScenesMayHaveNarration() throws {
        let json = #"{"captions": false, "scenes": [{"type": "hook", "text": "Hi", "say": " Meet Orbit. "}, {"type": "cta", "text": "Go"}]}"#
        let plan = try Storyboard.plan(from: Data(json.utf8), baseDirectory: folder)
        let scenes = try XCTUnwrap(plan.storyboard["scenes"] as? [[String: Any]])
        XCTAssertEqual(scenes[0]["say"] as? String, "Meet Orbit.")
        XCTAssertTrue(scenes[1]["say"] is NSNull)
        XCTAssertTrue(scenes[0]["voice"] is NSNull, "the sound is added when the video is built with a voiceover")
        XCTAssertEqual((scenes[0]["words"] as? [Any])?.count, 0)
        XCTAssertEqual(plan.storyboard["captions"] as? Bool, false)
        XCTAssertEqual(plan.storyboard["voiceLeadIn"] as? Double, Narration.leadIn)
        XCTAssertEqual(Storyboard.outline(of: plan).scenes.map(\.say), ["Meet Orbit.", nil])

        let plain = try Storyboard.plan(from: Data(#"{"scenes": [{"type": "hook", "text": "Hi"}]}"#.utf8), baseDirectory: folder)
        XCTAssertEqual(plain.storyboard["captions"] as? Bool, true)

        let long = #"{"scenes": [{"type": "hook", "text": "Hi", "say": "\#(String(repeating: "word ", count: 90))"}]}"#
        XCTAssertThrowsError(try Storyboard.plan(from: Data(long.utf8), baseDirectory: folder)) { error in
            XCTAssertTrue(error.localizedDescription.contains("\"say\" is"), error.localizedDescription)
        }
    }

    // MARK: - ElevenLabs

    func testCharactersBecomeWords() {
        let text = Array("Hi  there, أهلاً.").map { String($0) }
        let starts = text.indices.map { Double($0) }
        let ends = text.indices.map { Double($0) + 0.5 }
        let words = ElevenLabsClient.words(characters: text, starts: starts, ends: ends)
        XCTAssertEqual(words.map(\.text), ["Hi", "there,", "أهلاً."])
        XCTAssertEqual(words[0], NarrationWord(text: "Hi", start: 0, end: 1.5))
        XCTAssertEqual(words[1].start, 4)
        XCTAssertEqual(words[1].end, 9.5)
        XCTAssertEqual(ElevenLabsClient.words(characters: ["a", "b"], starts: [0], ends: [1]).map(\.text), ["a"], "timings that are missing are not invented")
        XCTAssertEqual(ElevenLabsClient.words(characters: [], starts: [], ends: []), [])
    }

    func testSpeechIsAskedForInElevenLabsOwnTerms() async throws {
        let server = try StubServer { _ in .json(Self.speech()) }
        defer { server.stop() }
        let client = ElevenLabsClient(apiKey: "test-key-not-real", baseURL: server.url)
        let speech = try await client.speak("Hi there.", voice: "voice123", before: "The line before.", after: nil)
        XCTAssertEqual(speech.audio.count, 400)
        XCTAssertEqual(speech.words.map(\.text), ["Hi", "there."])
        XCTAssertEqual(speech.words[1].end, 0.9, accuracy: 0.001)

        let request = try XCTUnwrap(server.requests.last)
        XCTAssertTrue(request.path.hasPrefix("/v1/text-to-speech/voice123/with-timestamps"), request.path)
        XCTAssertTrue(request.path.contains("output_format=mp3_44100_128"), request.path)
        XCTAssertEqual(request.headers["xi-api-key"], "test-key-not-real")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "Hi there.")
        XCTAssertEqual(body["model_id"] as? String, "eleven_multilingual_v2")
        XCTAssertEqual(body["previous_text"] as? String, "The line before.")
        XCTAssertNil(body["next_text"])
        XCTAssertNil(body["language_code"], "this model does not take one")
    }

    func testVoicesAndUsageAreRead() async throws {
        let server = try StubServer { request in
            if request.path.hasPrefix("/v1/user/subscription") {
                return .json(#"{"character_count": 9200, "character_limit": 10000, "tier": "free", "status": "free"}"#)
            }
            if request.path.contains("next_page_token=p2") {
                return .json(#"{"voices": [{"voice_id": "b", "name": "aria", "labels": {}}], "has_more": false, "total_count": 3}"#)
            }
            return .json(#"""
            {"voices": [{"voice_id": "z", "name": "Zed", "category": "premade", "labels": {"accent": "british", "gender": "male", "use_case": "narrative_story"}},
                        {"voice_id": "", "name": "Broken"}, {"name": "No id"}],
             "has_more": true, "next_page_token": "p2", "total_count": 3}
            """#)
        }
        defer { server.stop() }
        let client = ElevenLabsClient(apiKey: "k", baseURL: server.url)
        let voices = try await client.voices()
        XCTAssertEqual(voices.map(\.name), ["aria", "Zed"], "every page, sorted by name whatever its case")
        XCTAssertEqual(voices[1], .init(id: "z", name: "Zed", detail: "british, male, narrative story"))
        XCTAssertTrue(server.requests.first?.path.hasPrefix("/v2/voices?") == true)
        XCTAssertTrue(server.requests.first?.path.contains("page_size=100") == true)

        let usage = try await client.usage()
        XCTAssertEqual(usage, .init(used: 9200, limit: 10000))
        XCTAssertEqual(usage.left, 800)
    }

    func testProblemsAreExplained() async throws {
        func message(_ status: Int, _ body: String) async throws -> (String, Int) {
            let server = try StubServer { _ in .json(body, status: status) }
            defer { server.stop() }
            do {
                _ = try await ElevenLabsClient(apiKey: "k", baseURL: server.url).speak("Hi", voice: "v")
                XCTFail("expected an error")
                return ("", 0)
            } catch {
                return (error.localizedDescription, server.requests.count)
            }
        }
        let badKey = try await message(401, #"{"detail": {"type": "authentication_error", "code": "invalid_api_key", "message": "bad"}}"#)
        XCTAssertTrue(badKey.0.contains("did not accept the API key"), badKey.0)
        XCTAssertEqual(badKey.1, 1, "a rejected key is not tried again")

        let broke = try await message(402, #"{"detail": {"type": "payment_required", "code": "insufficient_credits", "message": "no"}}"#)
        XCTAssertTrue(broke.0.contains("not have enough credits"), broke.0)

        let gone = try await message(404, #"{"detail": {"type": "not_found", "code": "voice_not_found", "message": "no voice"}}"#)
        XCTAssertTrue(gone.0.contains("Choose another voice"), gone.0)

        let malformed = try await message(422, #"{"detail": [{"loc": ["body", "text"], "msg": "field required", "type": "missing"}]}"#)
        XCTAssertTrue(malformed.0.contains("field required"), malformed.0)

        let silent = try await message(200, #"{"audio_base64": ""}"#)
        XCTAssertTrue(silent.0.contains("without any sound"), silent.0)
    }

    // MARK: - A video's voiceover

    func testLinesAreSpokenOnceAndKept() async throws {
        let server = try StubServer { request in
            let text = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["text"] as? String ?? ""
            return .json(Self.speech(text))
        }
        defer { server.stop() }
        let client = ElevenLabsClient(apiKey: "k", baseURL: server.url)
        let cache = folder.appendingPathComponent("narration")
        let json = #"{"scenes": [{"type": "hook", "text": "A", "say": "Meet Orbit."}, {"type": "feature", "headline": "B"}, {"type": "cta", "text": "C", "say": "Try it today."}]}"#
        let plan = try Storyboard.plan(from: Data(json.utf8), baseDirectory: folder)

        var needs = Narration.needs(in: plan, voice: "v1", cache: cache)
        XCTAssertEqual(needs.map(\.scene), [0, 2], "only the scenes with something to say")
        XCTAssertEqual(Narration.charactersToSpeak(needs), 24)
        XCTAssertEqual(Narration.spoken(needs, cache: cache), [:])

        let lines = try await Narration.speak(needs, voice: "v1", client: client, cache: cache)
        XCTAssertEqual(Set(lines.keys), [0, 2])
        XCTAssertEqual(lines[0]?.words.map(\.text), ["Meet", "Orbit."])
        XCTAssertEqual(try XCTUnwrap(lines[0]).seconds, 1.1, accuracy: 0.01, "as long as its last word, when the sound itself cannot say")
        XCTAssertEqual(server.requests.count, 2)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: server.requests[1].body) as? [String: Any])
        XCTAssertEqual(second["previous_text"] as? String, "Meet Orbit.", "the line before, so the voice carries on from it")

        // Again: nothing is sent, nothing is charged.
        needs = Narration.needs(in: plan, voice: "v1", cache: cache)
        XCTAssertTrue(needs.allSatisfy(\.isSpoken))
        XCTAssertEqual(Narration.charactersToSpeak(needs), 0)
        let again = try await Narration.speak(needs, voice: "v1", client: client, cache: cache)
        XCTAssertEqual(again, lines)
        XCTAssertEqual(server.requests.count, 2)

        // One line reworded: only that one is sent. Another voice: all of them.
        let edited = try Storyboard.plan(from: Data(json.replacingOccurrences(of: "Try it today.", with: "Try it now.").utf8), baseDirectory: folder)
        XCTAssertEqual(Narration.needs(in: edited, voice: "v1", cache: cache).map(\.isSpoken), [true, false])
        XCTAssertEqual(Narration.needs(in: plan, voice: "v2", cache: cache).map(\.isSpoken), [false, false])
    }

    func testAVideoIsBuiltAroundItsVoice() async throws {
        let audio = folder.appendingPathComponent("line.mp3")
        try Data(repeating: 1, count: 300).write(to: audio)
        let line = Narration.Line(file: audio, seconds: 5.03, words: [NarrationWord(text: "Meet", start: 0, end: 0.4)])
        let storyboard = folder.appendingPathComponent("storyboard.json")
        try #"{"scenes": [{"type": "hook", "text": "A", "say": "Meet Orbit."}, {"type": "cta", "text": "C", "seconds": 9}]}"#
            .write(to: storyboard, atomically: true, encoding: .utf8)
        let project = folder.appendingPathComponent("video")

        _ = try await StudioProject.build(storyboard: storyboard, in: project, narration: [0: line, 1: line])
        let built = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent("src/storyboard.json"))) as? [String: Any])
        let scenes = try XCTUnwrap(built["scenes"] as? [[String: Any]])
        XCTAssertEqual(scenes[0]["seconds"] as? Double, 5.8, "three seconds as written, lengthened to the line plus a breath either side")
        XCTAssertEqual(scenes[1]["seconds"] as? Double, 9, "a scene already long enough is left alone")
        XCTAssertEqual(scenes[0]["voice"] as? String, "media/voice-1.mp3")
        XCTAssertEqual(scenes[0]["voiceSeconds"] as? Double, 5.03)
        XCTAssertEqual((scenes[0]["words"] as? [[String: Any]])?.first?["text"] as? String, "Meet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("public/media/voice-2.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("src/components/Spoken.tsx").path))

        // Built again without a voice, it is silent and its old sound is gone.
        _ = try await StudioProject.build(storyboard: storyboard, in: project)
        let silent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent("src/storyboard.json"))) as? [String: Any])
        XCTAssertTrue((silent["scenes"] as? [[String: Any]])?[0]["voice"] is NSNull)
        XCTAssertEqual((silent["scenes"] as? [[String: Any]])?[0]["seconds"] as? Double, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("public/media/voice-1.mp3").path))
    }

    func testNarrationLongerThanItsClipIsSaidBeforeAnythingIsPaid() async throws {
        try FileManager.default.copyItem(at: Self.examples.appendingPathComponent("clip.mp4"), to: folder.appendingPathComponent("clip.mp4"))
        // The clip is 6 s long. Read aloud, this takes about 10.
        let say = "This is a long line of narration that keeps going well past the end of the short clip it is meant to be read over, and then some more."
        let storyboard: [String: Any] = ["scenes": [["type": "screen", "video": "clip.mp4", "seconds": 4, "say": say]]]
        let problems = await StoryboardWriter.check(storyboard, directory: folder)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("its narration takes") && problems[0].contains("Say less in this scene"), problems[0])

        let short: [String: Any] = ["scenes": [["type": "screen", "video": "clip.mp4", "seconds": 4, "say": "Pick a size, then press Export."]]]
        let none = await StoryboardWriter.check(short, directory: folder)
        XCTAssertEqual(none, [])

        // And when the real recording runs long anyway, building says so too.
        let audio = folder.appendingPathComponent("line.mp3")
        try Data(repeating: 1, count: 300).write(to: audio)
        let file = folder.appendingPathComponent("storyboard.json")
        try JSONSerialization.data(withJSONObject: short).write(to: file)
        do {
            _ = try await StudioProject.build(storyboard: file, in: folder.appendingPathComponent("video"),
                                              narration: [0: Narration.Line(file: audio, seconds: 7.5, words: [])])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("its narration takes 8.2 s"), error.localizedDescription)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("video").path), "nothing half-built is left")
        }
    }

    func testLengthIsEstimatedBeforeAnythingIsSpoken() {
        XCTAssertEqual(Narration.estimate(String(repeating: "a", count: 28)), 2, accuracy: 0.001)
        XCTAssertEqual(Narration.estimate("كل موعد فائت يكلّف عيادتك وقتًا ومالًا."), 3.6, accuracy: 0.01,
                       "Arabic leaves vowels unwritten, so fewer characters fill a second")
        XCTAssertEqual(Narration.estimate(""), 0)
    }

    func testTheWriterIsToldWhetherThereIsAVoice() {
        let message = [StudioMessage(role: .user, text: "Go")]
        let voiced = StoryboardWriter.Prompt.request(messages: message, materials: [], storyboard: nil, narrator: "Rachel", labels: [:], budget: 100_000)
        XCTAssertTrue(voiced.contains("This video has a voiceover, read by a voice called Rachel. Write \"say\" for every scene."))
        let silent = StoryboardWriter.Prompt.request(messages: message, materials: [], storyboard: nil, labels: [:], budget: 100_000)
        XCTAssertTrue(silent.contains("This video has no voiceover. Do not write \"say\"."))
        XCTAssertTrue(StoryboardWriter.Prompt.system.contains("Write for the ear."))
    }

    func testAProjectRemembersItsVoice() throws {
        let project = try ProjectFolder.create(named: "Orbit", in: folder)
        var memory = project.loadMemory()
        XCTAssertNil(memory.narrator)
        memory.narrator = .init(id: "v1", name: "Rachel")
        try project.save(memory)
        XCTAssertEqual(project.loadMemory().narrator, .init(id: "v1", name: "Rachel"))
        XCTAssertTrue(ProjectBrief.knowledge(project.loadMemory()).contains("Voice for voiceovers: Rachel"))
    }
}
