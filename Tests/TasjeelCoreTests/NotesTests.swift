import Foundation
import Network
import XCTest
@testable import TasjeelCore

/// The AI notes pipeline, exercised with a scripted model and with local
/// stand-in servers for Ollama and the Anthropic API. No real model runs and
/// nothing leaves the machine.
final class NotesTests: XCTestCase {
    // MARK: - Reading a model's answer

    func testReadsTidyJSON() throws {
        let draft = try XCTUnwrap(NotesParser.draft(from: Self.answer))
        XCTAssertEqual(draft.title, "Pricing page redesign")
        XCTAssertEqual(draft.keyPoints.count, 2)
        XCTAssertEqual(draft.decisions, ["Ship the annual toggle first"])
        XCTAssertEqual(draft.actionItems.map(\.text), ["Send the new copy", "Check the analytics"])
        XCTAssertEqual(draft.actionItems.map(\.owner), ["You", nil], "an empty owner means nobody was named")
        XCTAssertEqual(draft.chapters.map(\.start), [0, 95, 3723])
    }

    func testReadsMessyAnswersFromSmallModels() throws {
        // Reasoning first, prose around a fenced block, renamed fields, a
        // list written as one string, seconds as numbers.
        let text = """
        <think>The user wants {notes}. Let me write them.</think>
        Sure! Here are the notes:
        ```json
        {"Title": "Standup", "overview": "Short sync.", "keyPoints": "- Build is green\\n- Demo on Friday",
         "actions": ["Book the room", {"action": "Fix login", "assignee": "Sara"}],
         "topics": [{"timestamp": 12, "name": "Status"}, {"start": "[1:30]", "topic": "Demo"}, {"time": "soon", "title": "Bad"}]}
        ```
        Let me know if you need anything else.
        """
        let draft = try XCTUnwrap(NotesParser.draft(from: text))
        XCTAssertEqual(draft.title, "Standup")
        XCTAssertEqual(draft.summary, "Short sync.")
        XCTAssertEqual(draft.keyPoints, ["Build is green", "Demo on Friday"])
        XCTAssertEqual(draft.actionItems.map(\.text), ["Book the room", "Fix login"])
        XCTAssertEqual(draft.actionItems.last?.owner, "Sara")
        XCTAssertEqual(draft.chapters.map(\.start), [12, 90], "a chapter with no readable time is dropped")
        XCTAssertNil(NotesParser.draft(from: "I'm sorry, I can't help with that."))
    }

    func testChaptersAreTidied() {
        let chapters = [
            NoteChapter(start: 400, title: "Late"), NoteChapter(start: 30, title: "Intro"), NoteChapter(start: 38, title: "Too close"),
            NoteChapter(start: 200, title: "Middle"), NoteChapter(start: 900, title: "After the end"),
        ]
        let tidy = NotesParser.tidied(chapters, duration: 600)
        XCTAssertEqual(tidy.map(\.title), ["Intro", "Middle", "Late"])
        XCTAssertEqual(tidy.first?.start, 0, "the first chapter covers the start of the video")
    }

    // MARK: - Writing notes

    func testShortTranscriptIsOneRequestInItsOwnLanguage() async throws {
        let model = ScriptedModel(answers: [Self.answer])
        let transcript = Transcript(language: "ar-SA", segments: [
            TranscriptSegment(start: 2, end: 6, text: "مرحبا بالجميع", speaker: .mic),
            TranscriptSegment(start: 7, end: 12, text: "شكرا", speaker: .system),
        ])
        let notes = try await NotesGenerator.notes(for: transcript, duration: 4000, model: model) { _, _ in }
        XCTAssertEqual(notes.title, "Pricing page redesign")
        XCTAssertEqual(notes.engine, "Scripted")
        XCTAssertEqual(notes.language, "ar-SA")
        XCTAssertEqual(notes.chapters.map(\.start), [0, 95, 3723])

        let calls = model.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].system.contains("Arabic"), "the model is told which language to write in")
        XCTAssertTrue(calls[0].system.contains("\"You\" is the person who made the recording"))
        XCTAssertTrue(calls[0].prompt.contains("[0:02] You: مرحبا بالجميع"))
        XCTAssertTrue(calls[0].prompt.contains("[0:07] Others: شكرا"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(calls[0].schema.utf8)), "the schema is valid JSON")
    }

    func testLongTranscriptIsReadInPartsThenCombined() async throws {
        // 120 lines of ~70 characters against a 3000-character budget.
        let segments = (0 ..< 120).map { index in
            TranscriptSegment(start: Double(index) * 10, end: Double(index) * 10 + 8,
                              text: "Line number \(index) talks about the roadmap and the release plan in detail")
        }
        let lines = NotesGenerator.transcriptLines(Transcript(language: "en-US", segments: segments))
        let parts = NotesGenerator.chunks(of: lines, budget: 3000)
        XCTAssertGreaterThan(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 3000 })
        XCTAssertEqual(parts.joined(separator: "\n"), lines.joined(separator: "\n"), "nothing is lost or reordered")

        let part = #"{"title":"Part","summary":"A part.","key_points":["A point"],"decisions":[],"action_items":[],"chapters":[{"time":"%@","title":"Topic"}]}"#
        var answers = parts.indices.map { String(format: part, NotesFormat.stamp(Double($0) * 300)) }
        // The combining step returns no chapters; the parts' chapters are used.
        answers.append(#"{"title":"Roadmap review","summary":"The whole thing.","key_points":["One","Two"],"decisions":["Go"],"action_items":[{"task":"Ship","owner":"Others"}],"chapters":[]}"#)
        let model = ScriptedModel(answers: answers, budget: 3000)

        let notes = try await NotesGenerator.notes(for: Transcript(language: "en-US", segments: segments), duration: 1200, model: model) { _, _ in }
        XCTAssertEqual(model.calls.count, parts.count + 1)
        XCTAssertTrue(model.calls[0].prompt.contains("part 1 of \(parts.count)"))
        XCTAssertTrue(model.calls.last?.prompt.contains("<part number=\"\(parts.count)\">") ?? false)
        XCTAssertEqual(notes.title, "Roadmap review")
        XCTAssertEqual(notes.actionItems.first?.owner, "Others")
        XCTAssertEqual(notes.chapters.count, parts.count)
        XCTAssertFalse(model.calls[0].system.contains("\"You\" is"), "no speaker labels, so none are explained")
    }

    func testAnUnreadableAnswerIsRetriedOnce() async throws {
        let transcript = Transcript(language: "en-US", segments: [TranscriptSegment(start: 0, end: 3, text: "Hello there")])
        let recovers = ScriptedModel(answers: ["no json here", Self.answer])
        let notes = try await NotesGenerator.notes(for: transcript, duration: 60, model: recovers) { _, _ in }
        XCTAssertEqual(notes.title, "Pricing page redesign")
        XCTAssertEqual(recovers.calls.count, 2)

        let broken = ScriptedModel(answers: ["nope", "still nope", Self.answer])
        do {
            _ = try await NotesGenerator.notes(for: transcript, duration: 60, model: broken) { _, _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NotesError, .unreadable)
        }
        XCTAssertEqual(broken.calls.count, 2, "two tries, not more")
    }

    func testNoSpeechIsAnError() async {
        let model = ScriptedModel(answers: [Self.answer])
        do {
            _ = try await NotesGenerator.notes(for: Transcript(language: "en-US", segments: []), duration: 10, model: model) { _, _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NotesError, .noSpeech)
        }
        XCTAssertTrue(model.calls.isEmpty, "no request is made for an empty transcript")
    }

    // MARK: - Chapters and export

    func testChaptersFollowTheCuts() {
        let notes = MeetingNotes(title: "T", summary: "S", chapters: [
            NoteChapter(start: 0, title: "Intro"), NoteChapter(start: 60, title: "Cut away"),
            NoteChapter(start: 100, title: "Starts in a cut"), NoteChapter(start: 200, title: "End"),
        ], engine: "x", language: "en-US")
        // Keep 0-50 and 120-300: 50-120 is cut.
        let map = TimeMap(segments: [TimeSpan(start: 0, end: 50), TimeSpan(start: 120, end: 300)])
        let edited = notes.editedChapters(with: map)
        XCTAssertEqual(edited.map(\.title), ["Intro", "Starts in a cut", "End"], "a chapter that was cut out completely is dropped")
        XCTAssertEqual(edited.map(\.start), [0, 50, 130], "times match the edited video")
        XCTAssertEqual(notes.chapter(at: 150)?.title, "Starts in a cut")
        XCTAssertEqual(NotesFormat.chapterList(edited), "0:00 Intro\n0:50 Starts in a cut\n2:10 End")
    }

    func testMarkdown() {
        let notes = MeetingNotes(title: "Weekly sync", summary: "We met.", keyPoints: ["A"], decisions: [],
                                 actionItems: [ActionItem(text: "Send notes", owner: "You"), ActionItem(text: "Review")],
                                 chapters: [NoteChapter(start: 3700, title: "Wrap up")], engine: "x", language: "en-US")
        XCTAssertEqual(NotesFormat.markdown(notes), """
        # Weekly sync

        We met.

        ## Key points

        - A

        ## Action items

        - [ ] Send notes (You)
        - [ ] Review

        ## Chapters

        - 1:01:40 Wrap up

        """)
    }

    // MARK: - Choosing an engine

    func testAutomaticStaysOnThisMac() {
        var found = AIAvailability(appleProblem: nil, appleLanguages: ["en", "fr"], ollamaRunning: true,
                                   ollamaModels: ["nomic-embed-text:latest", "gemma4:12b"], hasClaudeKey: true)
        XCTAssertEqual(AIEngines.choose(.automatic, ollamaModel: "", language: "en-US", found: found), .apple)
        XCTAssertEqual(AIEngines.choose(.automatic, ollamaModel: "", language: "ar-SA", found: found), .ollama(model: "gemma4:12b"),
                       "Apple's model has no Arabic, so the local model is used")
        XCTAssertEqual(AIEngines.choose(.ollama, ollamaModel: "nomic-embed-text:latest", language: "en-US", found: found),
                       .ollama(model: "nomic-embed-text:latest"), "an explicit pick is respected")

        found.ollamaModels = []
        found.appleProblem = "Apple Intelligence is switched off."
        // A saved key must never make Automatic use the cloud.
        guard case .unavailable = AIEngines.choose(.automatic, ollamaModel: "", language: "en-US", found: found) else {
            return XCTFail("automatic must not fall through to the cloud")
        }
        XCTAssertEqual(AIEngines.choose(.claude, ollamaModel: "", language: "ar-SA", found: found), .claude)
        found.hasClaudeKey = false
        guard case .unavailable = AIEngines.choose(.claude, ollamaModel: "", language: "en-US", found: found) else {
            return XCTFail("Claude needs a key")
        }
    }

    // MARK: - Ollama

    func testOllamaRequestAndStreamedAnswer() async throws {
        let server = try StubServer { request in
            if request.path == "/api/tags" {
                return .json(#"{"models":[{"name":"gemma4:12b"},{"name":"aya:8b"}]}"#)
            }
            return .lines([
                #"{"message":{"role":"assistant","content":"{\"title\":"},"done":false}"#,
                #"{"message":{"role":"assistant","content":"\"Hi\"}"},"done":false}"#,
                #"{"message":{"role":"assistant","content":""},"done":true}"#,
            ], contentType: "application/x-ndjson")
        }
        defer { server.stop() }
        let client = OllamaClient(baseURL: server.url)
        let models = try await client.models()
        XCTAssertEqual(models, ["aya:8b", "gemma4:12b"])

        let seen = Counter()
        let text = try await OllamaModel(name: "gemma4:12b", client: client)
            .generate(system: "SYS", prompt: "PROMPT", schema: NotesPrompt.schema) { seen.set($0) }
        XCTAssertEqual(text, #"{"title":"Hi"}"#)
        XCTAssertEqual(seen.value, text.count)

        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(request.path, "/api/chat")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gemma4:12b")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["options"] as? [String: Any])?["num_ctx"] as? Int, 16384, "Ollama's default context is too small for a transcript")
        XCTAssertEqual((body["format"] as? [String: Any])?["type"] as? String, "object")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
    }

    func testOllamaNotRunningSaysSo() async {
        // Nothing listens on this port.
        let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:9")!)
        do {
            _ = try await OllamaModel(name: "x", client: client).generate(system: "", prompt: "", schema: "{}") { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Ollama is not running"), error.localizedDescription)
        }
    }

    // MARK: - Claude

    func testClaudeRequestAndStreamedAnswer() async throws {
        let server = try StubServer { _ in
            .lines([
                "event: message_start",
                #"data: {"type":"message_start","message":{"id":"msg_1","type":"message"}}"#,
                "",
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
                #"data: {"type":"content_block_stop","index":0}"#,
                #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
                "event: content_block_delta",
                #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"title\":"}}"#,
                #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\"Hi\"}"}}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#,
                #"data: {"type":"message_stop"}"#,
            ], contentType: "text/event-stream")
        }
        defer { server.stop() }

        let text = try await ClaudeModel(apiKey: "test-key-not-real", baseURL: server.url)
            .generate(system: "SYS", prompt: "PROMPT", schema: NotesPrompt.schema) { _ in }
        XCTAssertEqual(text, #"{"title":"Hi"}"#, "thinking is not part of the answer")

        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(request.path, "/v1/messages")
        XCTAssertEqual(request.headers["x-api-key"], "test-key-not-real")
        XCTAssertEqual(request.headers["anthropic-version"], "2026-10-21")
        XCTAssertEqual(request.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual(body["system"] as? String, "SYS")
        XCTAssertNil(body["temperature"], "sampling settings are rejected by this API version")
        XCTAssertNil(body["thinking"])
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "medium")
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "json_schema")
        let schema = try XCTUnwrap((output["format"] as? [String: Any])?["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testClaudeProblemsAreExplained() async throws {
        let unauthorized = try StubServer { _ in
            .json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401)
        }
        defer { unauthorized.stop() }
        do {
            _ = try await ClaudeModel(apiKey: "bad", baseURL: unauthorized.url).generate(system: "", prompt: "", schema: "{}") { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not accept the API key"), error.localizedDescription)
        }
        XCTAssertEqual(unauthorized.requests.count, 1, "a rejected key is not retried")

        let refusal = try StubServer { _ in
            .lines([#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#], contentType: "text/event-stream")
        }
        defer { refusal.stop() }
        do {
            _ = try await ClaudeModel(apiKey: "k", baseURL: refusal.url).generate(system: "", prompt: "", schema: "{}") { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NotesError, .declined)
        }
    }

    // MARK: - Fixtures

    private static let answer = """
    {"title": "Pricing page redesign", "summary": "The team reviewed the new pricing page and agreed what ships first.",
     "key_points": ["The annual toggle tests well", "Copy needs another pass"],
     "decisions": ["Ship the annual toggle first"],
     "action_items": [{"task": "Send the new copy", "owner": "You"}, {"task": "Check the analytics", "owner": ""}],
     "chapters": [{"time": "0:00", "title": "Where we are"}, {"time": "1:35", "title": "Annual toggle"}, {"time": "1:02:03", "title": "Next steps"}]}
    """
}

// MARK: - Test doubles

/// A model that returns prepared answers and records what it was asked.
private final class ScriptedModel: TextModel, @unchecked Sendable {
    struct Call {
        var system: String
        var prompt: String
        var schema: String
    }

    private let lock = NSLock()
    private var answers: [String]
    private var recorded: [Call] = []
    let transcriptBudget: Int

    init(answers: [String], budget: Int = 100_000) {
        self.answers = answers
        transcriptBudget = budget
    }

    var displayName: String { "Scripted" }
    var isCloud: Bool { false }
    var calls: [Call] { lock.withLock { recorded } }

    func generate(system: String, prompt: String, schema: String, progress: @escaping @Sendable (Int) -> Void) async throws -> String {
        lock.withLock {
            recorded.append(Call(system: system, prompt: prompt, schema: schema))
            return answers.isEmpty ? "" : answers.removeFirst()
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func set(_ new: Int) { lock.withLock { stored = new } }
}

/// A one-request-per-connection HTTP server on a random local port.
private final class StubServer: @unchecked Sendable {
    struct Request {
        var path: String
        var headers: [String: String]
        var body: Data
    }

    struct Response {
        var status: Int
        var contentType: String
        var body: String

        static func json(_ body: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json", body: body)
        }

        static func lines(_ lines: [String], contentType: String) -> Response {
            Response(status: 200, contentType: contentType, body: lines.joined(separator: "\n") + "\n")
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub.server")
    private let lock = NSLock()
    private var received: [Request] = []
    let url: URL

    var requests: [Request] { lock.withLock { received } }

    init(respond: @escaping @Sendable (Request) -> Response) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        // `url` has to be set before `self` can be captured, so requests are
        // recorded through a box that is filled in afterwards.
        let box = Box()
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.read(connection, buffer: Data()) { request in
                box.record?(request)
                let response = respond(request)
                let payload = Data(response.body.utf8)
                let head = "HTTP/1.1 \(response.status) X\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            throw NSError(domain: "StubServer", code: 1)
        }
        url = URL(string: "http://127.0.0.1:\(port.rawValue)")!
        box.record = { [weak self] request in
            guard let self else { return }
            self.lock.withLock { self.received.append(request) }
        }
    }

    func stop() { listener.cancel() }

    private final class Box: @unchecked Sendable {
        var record: ((Request) -> Void)?
    }

    /// Reads until the headers and the announced body length have arrived.
    private static func read(_ connection: NWConnection, buffer: Data, done: @escaping @Sendable (Request) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, finished, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let split = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let first = lines.removeFirst().split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let body = buffer[split.upperBound...]
                if body.count >= length {
                    done(Request(path: first.count > 1 ? String(first[1]) : "", headers: headers, body: Data(body.prefix(length))))
                    return
                }
            }
            if finished || error != nil { return }
            read(connection, buffer: buffer, done: done)
        }
    }
}
