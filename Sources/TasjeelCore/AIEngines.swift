import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which AI model writes the notes.
public enum AIEngineKind: String, Codable, CaseIterable, Sendable {
    /// Whatever works on this Mac without sending anything out.
    case automatic
    /// The model built into macOS (Apple Intelligence).
    case apple
    /// A model downloaded into the Ollama app.
    case ollama
    /// Claude, through the user's own Anthropic API key. The only choice that
    /// sends the transcript off the Mac, and never picked automatically.
    case claude
}

/// What the app found when it looked for models on this Mac.
public struct AIAvailability: Equatable, Sendable {
    /// Nil when Apple's model can be used; otherwise why not.
    public var appleProblem: String?
    /// Languages Apple's model can write in (language codes such as "en").
    public var appleLanguages: Set<String>
    public var ollamaRunning: Bool
    public var ollamaModels: [String]
    public var hasClaudeKey: Bool

    public init(appleProblem: String? = "Not checked yet.", appleLanguages: Set<String> = [], ollamaRunning: Bool = false,
                ollamaModels: [String] = [], hasClaudeKey: Bool = false) {
        self.appleProblem = appleProblem
        self.appleLanguages = appleLanguages
        self.ollamaRunning = ollamaRunning
        self.ollamaModels = ollamaModels
        self.hasClaudeKey = hasClaudeKey
    }

    public func appleCanWrite(_ language: String) -> Bool {
        guard appleProblem == nil, let code = Locale(identifier: language).language.languageCode?.identifier else { return false }
        return appleLanguages.contains(code)
    }
}

/// The engine a request will actually use, or what is missing.
public enum AIChoice: Equatable, Sendable {
    case apple
    case ollama(model: String)
    case claude
    case unavailable(String)
}

public enum AIEngines {
    /// A local model that handles many languages (Arabic included) and fits
    /// in 16 GB of memory. Suggested when Ollama has no models yet.
    public static let suggestedOllamaModel = "gemma4:12b"
    public static let suggestedOllamaSize = "8 GB"

    /// Decides which engine to use. Pure, so it can be tested.
    public static func choose(_ kind: AIEngineKind, ollamaModel: String, language: String, found: AIAvailability) -> AIChoice {
        let languageName = Locale.current.localizedString(forIdentifier: language) ?? language

        func apple() -> AIChoice {
            if let problem = found.appleProblem { return .unavailable(problem) }
            if !found.appleCanWrite(language) {
                return .unavailable("The model built into macOS cannot write in \(languageName) yet.")
            }
            return .apple
        }
        func ollama() -> AIChoice {
            guard found.ollamaRunning else {
                return .unavailable("Ollama is not running. Open the Ollama app, or install it from ollama.com.")
            }
            if found.ollamaModels.contains(ollamaModel) { return .ollama(model: ollamaModel) }
            if let first = preferred(found.ollamaModels) { return .ollama(model: first) }
            return .unavailable("Ollama has no models yet. Download one in AI settings.")
        }

        switch kind {
        case .apple:
            return apple()
        case .ollama:
            return ollama()
        case .claude:
            return found.hasClaudeKey ? .claude : .unavailable("Add your Anthropic API key in AI settings to use Claude.")
        case .automatic:
            if case .apple = apple() { return .apple }
            let local = ollama()
            if case .ollama = local { return local }
            return .unavailable("No AI model is set up on this Mac yet. Open AI settings to choose one.")
        }
    }

    /// Decides which engine writes storyboards in the Studio. Writing a whole
    /// video is more than the small model built into macOS can do, so it is
    /// Claude when the user chose Claude, and otherwise a model in Ollama.
    public static func chooseWriter(_ kind: AIEngineKind, ollamaModel: String, found: AIAvailability) -> AIChoice {
        if kind == .claude { return choose(.claude, ollamaModel: ollamaModel, language: "en", found: found) }
        if case .ollama(let model) = choose(.ollama, ollamaModel: ollamaModel, language: "en", found: found) {
            return .ollama(model: model)
        }
        if kind == .ollama { return choose(.ollama, ollamaModel: ollamaModel, language: "en", found: found) }
        return .unavailable(found.hasClaudeKey
            ? "The Studio writes with Claude or with a model in Ollama. Choose one of them in AI settings."
            : "The Studio writes with Claude (your own API key) or with a model in Ollama. Set one up in AI settings.")
    }

    /// The installed model to prefer when the user has not picked one: the
    /// suggested one, else the first that is not an embedding model.
    static func preferred(_ models: [String]) -> String? {
        if models.contains(suggestedOllamaModel) { return suggestedOllamaModel }
        return models.first { !$0.lowercased().contains("embed") } ?? models.first
    }

    /// Looks at what this Mac has. `ollama` is injectable for tests.
    public static func discover(hasClaudeKey: Bool, ollama: OllamaClient = OllamaClient()) async -> AIAvailability {
        var found = AIAvailability(hasClaudeKey: hasClaudeKey)
        (found.appleProblem, found.appleLanguages) = AppleModel.status()
        if let models = try? await ollama.models() {
            found.ollamaRunning = true
            found.ollamaModels = models
        }
        return found
    }

    /// Builds the model for a choice. `claudeKey` is only read for `.claude`.
    public static func model(for choice: AIChoice, claudeKey: @Sendable () -> String?) throws -> any TextModel {
        switch choice {
        case .apple:
            return AppleModel()
        case .ollama(let name):
            return OllamaModel(name: name)
        case .claude:
            guard let key = claudeKey(), !key.isEmpty else {
                throw NotesError.engine("Add your Anthropic API key in AI settings to use Claude.")
            }
            return ClaudeModel(apiKey: key)
        case .unavailable(let reason):
            throw NotesError.engine(reason)
        }
    }
}

// MARK: - Apple (on-device)

/// The language model that ships with macOS 26 as part of Apple Intelligence.
/// Free and private, but small: it reads about three pages at a time, so a
/// long meeting is summarised in many parts.
public struct AppleModel: TextModel {
    public init() {}

    public var displayName: String { "Apple Intelligence (on this Mac)" }
    public var transcriptBudget: Int { 5000 }
    public var isCloud: Bool { false }

    /// Why the model cannot be used (nil when it can) and the languages it writes.
    public static func status() -> (problem: String?, languages: Set<String>) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            let languages = Set(model.supportedLanguages.compactMap { $0.languageCode?.identifier })
            switch model.availability {
            case .available:
                return (nil, languages)
            case .unavailable(.appleIntelligenceNotEnabled):
                return ("Apple Intelligence is switched off. Turn it on in System Settings › Apple Intelligence & Siri.", languages)
            case .unavailable(.deviceNotEligible):
                return ("This Mac does not support Apple Intelligence.", languages)
            case .unavailable(.modelNotReady):
                return ("macOS is still downloading its AI model. Try again later.", languages)
            case .unavailable:
                return ("The model built into macOS is not available right now.", languages)
            }
        }
        #endif
        return ("The built-in model needs macOS 26 or later.", [])
    }

    public func generate(system: String, prompt: String, schema: String,
                         progress: @escaping @Sendable (Int) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: system)
                let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
                progress(response.content.count)
                return response.content
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw NotesError.engine("The model built into macOS could not write the notes: \(error.localizedDescription)")
            }
        }
        #endif
        throw NotesError.engine("The built-in model needs macOS 26 or later.")
    }
}

// MARK: - Ollama (local)

/// Talks to the Ollama app, which runs downloaded models on this Mac and
/// listens on a local port. Nothing here leaves the machine.
public struct OllamaClient: Sendable {
    public var baseURL: URL

    /// Ollama's usual address on this Mac. `TASJEEL_OLLAMA_URL` points the
    /// app at another one, e.g. a different port or a stand-in for testing.
    public init(baseURL: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["TASJEEL_OLLAMA_URL"].flatMap { URL(string: $0) }
        self.baseURL = baseURL ?? override ?? URL(string: "http://127.0.0.1:11434")!
    }

    /// Names of the downloaded models. Throws when Ollama is not running.
    public func models() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["models"] as? [[String: Any]] else {
            throw NotesError.engine("Ollama did not answer as expected.")
        }
        return list.compactMap { $0["name"] as? String }.sorted()
    }

    /// Downloads a model into Ollama. `progress` receives 0 ... 1 and a label.
    public func pull(_ model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        request.timeoutInterval = 600
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        for try await line in bytes.lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = object["error"] as? String { throw NotesError.engine("Ollama could not download \(model): \(error)") }
            let label = (object["status"] as? String) ?? "Downloading…"
            if let total = (object["total"] as? NSNumber)?.doubleValue, total > 0 {
                let done = (object["completed"] as? NSNumber)?.doubleValue ?? 0
                progress(min(done / total, 1), label.hasPrefix("pulling") ? "Downloading…" : label)
            } else {
                progress(label == "success" ? 1 : 0, label)
            }
        }
        guard status == 200 else { throw NotesError.engine("Ollama could not download \(model).") }
    }
}

public struct OllamaModel: TextModel {
    public let name: String
    public var client: OllamaClient
    /// Tokens of context to ask Ollama for. Its default is far too small for
    /// a transcript, so it is always set.
    private let context = 16384

    public init(name: String, client: OllamaClient = OllamaClient()) {
        self.name = name
        self.client = client
    }

    public var displayName: String { "\(name) (on this Mac)" }
    /// About 60% of the context, at a cautious 2.5 characters per token
    /// (Arabic and other non-Latin text takes more tokens than English).
    public var transcriptBudget: Int { 24000 }
    public var isCloud: Bool { false }

    public func generate(system: String, prompt: String, schema: String,
                         progress: @escaping @Sendable (Int) -> Void) async throws -> String {
        try await chat(system: system, prompt: prompt, schema: schema, temperature: 0.2) { progress($0.count) }
    }

    /// Free text for a conversation. Pictures are not sent: most local models
    /// cannot see, and the ones that can each want them differently.
    public func write(system: String, prompt: String, images: [ModelImage],
                      partial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await chat(system: system, prompt: prompt, schema: "", temperature: 0.5, partial: partial)
    }

    private func chat(system: String, prompt: String, schema: String, temperature: Double,
                      partial: @escaping @Sendable (String) -> Void) async throws -> String {
        var body: [String: Any] = [
            "model": name,
            "stream": true,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "options": ["temperature": temperature, "num_ctx": context],
        ]
        if let format = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) { body["format"] = format }

        var request = URLRequest(url: client.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Loading a model into memory can take a minute before the first word.
        request.timeoutInterval = 300

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            throw NotesError.engine("Ollama is not running. Open the Ollama app and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var text = ""
        for try await line in bytes.lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = object["error"] as? String {
                throw NotesError.engine("Ollama could not run \(name): \(error)")
            }
            if let message = object["message"] as? [String: Any], let piece = message["content"] as? String, !piece.isEmpty {
                text += piece
                partial(text)
            }
        }
        guard status == 200 else { throw NotesError.engine("Ollama could not run \(name) (error \(status)).") }
        return text
    }
}

// MARK: - Claude (cloud, the user's own key)

/// Claude through the Anthropic API. The best notes, in any language, and a
/// whole meeting in one request, but the transcript text is sent to
/// Anthropic, so it is used only when the user chooses it and supplies a key.
/// Audio and video are never sent.
public struct ClaudeModel: TextModel {
    public static let model = "claude-opus-5-5"

    private let apiKey: String
    private let baseURL: URL

    /// `baseURL` exists so tests can point at a local stand-in server.
    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public var displayName: String { "Claude Opus 5.5" }
    /// Far more than any meeting: a million tokens of context.
    public var transcriptBudget: Int { 1_200_000 }
    public var isCloud: Bool { true }

    public var seesImages: Bool { true }

    public func generate(system: String, prompt: String, schema: String,
                         progress: @escaping @Sendable (Int) -> Void) async throws -> String {
        var output: [String: Any] = ["effort": "medium"]
        if let parsed = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) {
            output["format"] = ["type": "json_schema", "schema": parsed]
        }
        return try await run(system: system, content: prompt, output: output) { progress($0.count) }
    }

    /// Free text for a conversation, with the pictures placed before the
    /// words. The instructions and the pictures are marked for caching: they
    /// are the same on every turn of a chat, so later turns cost less.
    public func write(system: String, prompt: String, images: [ModelImage],
                      partial: @escaping @Sendable (String) -> Void) async throws -> String {
        var blocks: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.data.base64EncodedString()]]
        }
        if !blocks.isEmpty { blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"] }
        blocks.append(["type": "text", "text": prompt])
        let instructions: [[String: Any]] = [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]]
        return try await run(system: instructions, content: blocks, output: ["effort": "medium"], partial: partial)
    }

    private func run(system: Any, content: Any, output: [String: Any],
                     partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 64000,
            "stream": true,
            // If a safety check declines the request, let the API retry it on
            // the model Anthropic recommends instead of failing.
            "fallbacks": "default",
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": output,
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        var lastError: Error = NotesError.engine("Claude could not be reached.")
        for attempt in 0 ..< 3 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
            do {
                return try await send(request, partial: partial)
            } catch let failure as Failure {
                lastError = NotesError.engine(failure.message)
                if !failure.retryable { break }
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                lastError = NotesError.engine("Claude could not be reached: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    private struct Failure: Error {
        var message: String
        var retryable: Bool
    }

    private func send(_ request: URLRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw Self.failure(status: status, body: raw)
        }

        // Server-sent events: each "data:" line is one JSON event.
        var text = ""
        var stopReason: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                // Thinking arrives as its own kind of delta; only text is the answer.
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let piece = delta["text"] as? String {
                    text += piece
                    partial(text)
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { stopReason = reason }
            case "error":
                let error = event["error"] as? [String: Any]
                let kind = error?["type"] as? String ?? ""
                throw Failure(message: "Claude reported a problem: \(error?["message"] as? String ?? kind)",
                              retryable: kind == "overloaded_error" || kind == "api_error")
            default:
                break
            }
        }
        switch stopReason {
        case "refusal":
            throw NotesError.declined
        case "max_tokens":
            throw NotesError.engine("Claude ran out of room before it finished. Try again.")
        default:
            return text
        }
    }

    /// Turns an HTTP error into something a person can act on.
    private static func failure(status: Int, body: String) -> Failure {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let detail = (object?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401:
            return Failure(message: "Anthropic did not accept the API key. Check it in AI settings.", retryable: false)
        case 402:
            return Failure(message: "Your Anthropic account has a billing problem: \(detail ?? "check your plan and credits").", retryable: false)
        case 403:
            return Failure(message: "This API key is not allowed to use \(model): \(detail ?? "permission denied").", retryable: false)
        case 429:
            return Failure(message: "Anthropic's rate limit was reached. Wait a minute and try again.", retryable: true)
        case 500 ..< 600:
            return Failure(message: "Anthropic's service is busy right now. Try again in a moment.", retryable: true)
        default:
            return Failure(message: "Claude rejected the request: \(detail ?? "error \(status)").", retryable: false)
        }
    }
}
