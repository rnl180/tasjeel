@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// One spoken word and when it is heard, counted from the start of its line.
public struct NarrationWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum VoiceError: LocalizedError, Equatable {
    case service(String)

    public var errorDescription: String? {
        switch self {
        case .service(let reason): return reason
        }
    }
}

/// ElevenLabs, which turns a scene's narration into speech and says when each
/// character is spoken, so captions can follow the voice word by word.
///
/// It is used only when the user adds their own ElevenLabs key. The words to
/// be spoken are sent to ElevenLabs; nothing else is.
public struct ElevenLabsClient: Sendable {
    /// The model ElevenLabs' documentation names as its default and
    /// recommends for quality. It speaks Arabic among 29 languages and takes
    /// up to 10,000 characters a request.
    public static let model = "eleven_multilingual_v2"

    private let apiKey: String
    private let baseURL: URL

    /// `TASJEEL_ELEVENLABS_URL` points a development build at a stand-in.
    public init(apiKey: String, baseURL: URL? = nil) {
        self.apiKey = apiKey
        let override = ProcessInfo.processInfo.environment["TASJEEL_ELEVENLABS_URL"].flatMap { URL(string: $0) }
        self.baseURL = baseURL ?? override ?? URL(string: "https://api.elevenlabs.io")!
    }

    public struct Voice: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// "American, female, narration": whatever the voice is labelled with.
        public var detail: String

        public init(id: String, name: String, detail: String = "") {
            self.id = id
            self.name = name
            self.detail = detail
        }
    }

    /// How much of the plan's allowance is used. ElevenLabs counts characters.
    public struct Usage: Equatable, Sendable {
        public var used: Int
        public var limit: Int

        public var left: Int { max(limit - used, 0) }
    }

    public struct Speech: Equatable, Sendable {
        /// An MP3.
        public var audio: Data
        public var words: [NarrationWord]
    }

    // MARK: - Requests

    /// The voices in the user's account, their own first, sorted by name.
    public func voices() async throws -> [Voice] {
        var found: [Voice] = []
        var token: String?
        // A few pages at most: nobody picks from a list of thousands.
        for _ in 0 ..< 4 {
            var components = URLComponents(url: baseURL.appendingPathComponent("v2/voices"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "include_total_count", value: "false")]
            if let token { components.queryItems?.append(URLQueryItem(name: "next_page_token", value: token)) }
            let object = try await json(request(components.url!))
            for raw in object["voices"] as? [[String: Any]] ?? [] {
                guard let id = raw["voice_id"] as? String, let name = raw["name"] as? String, !id.isEmpty else { continue }
                let labels = raw["labels"] as? [String: String] ?? [:]
                let detail = ["accent", "gender", "age", "use_case", "descriptive"].compactMap { labels[$0] }
                    .map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
                found.append(Voice(id: id, name: name, detail: detail))
            }
            guard object["has_more"] as? Bool == true, let next = object["next_page_token"] as? String, !next.isEmpty else { break }
            token = next
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func usage() async throws -> Usage {
        let object = try await json(request(baseURL.appendingPathComponent("v1/user/subscription")))
        guard let used = (object["character_count"] as? NSNumber)?.intValue,
              let limit = (object["character_limit"] as? NSNumber)?.intValue else {
            throw VoiceError.service("ElevenLabs did not say how much of your plan is left.")
        }
        return Usage(used: used, limit: limit)
    }

    /// Speaks `text`. `before` and `after` are the lines around it, which
    /// help the voice carry on naturally from one scene to the next; they
    /// are not spoken and not charged.
    public func speak(_ text: String, voice: String, before: String? = nil, after: String? = nil) async throws -> Speech {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/text-to-speech/\(voice)/with-timestamps"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var body: [String: Any] = ["text": text, "model_id": Self.model]
        if let before, !before.isEmpty { body["previous_text"] = before }
        if let after, !after.isEmpty { body["next_text"] = after }
        var request = request(components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let object = try await json(request)
        guard let encoded = object["audio_base64"] as? String, let audio = Data(base64Encoded: encoded), audio.count > 200 else {
            throw VoiceError.service("ElevenLabs answered without any sound. Try again.")
        }
        let alignment = (object["alignment"] as? [String: Any]) ?? (object["normalized_alignment"] as? [String: Any]) ?? [:]
        return Speech(audio: audio, words: Self.words(characters: alignment["characters"] as? [String] ?? [],
                                                      starts: (alignment["character_start_times_seconds"] as? [NSNumber] ?? []).map(\.doubleValue),
                                                      ends: (alignment["character_end_times_seconds"] as? [NSNumber] ?? []).map(\.doubleValue)))
    }

    /// Joins the characters ElevenLabs timed into words: a word starts when
    /// its first character does and ends when its last one does.
    static func words(characters: [String], starts: [Double], ends: [Double]) -> [NarrationWord] {
        var words: [NarrationWord] = []
        var current = ""
        var began = 0.0, finished = 0.0
        for (index, character) in characters.enumerated() where index < starts.count && index < ends.count {
            if character.allSatisfy(\.isWhitespace) {
                if !current.isEmpty { words.append(NarrationWord(text: current, start: began, end: finished)) }
                current = ""
                continue
            }
            if current.isEmpty { began = starts[index] }
            current += character
            finished = max(ends[index], began)
        }
        if !current.isEmpty { words.append(NarrationWord(text: current, start: began, end: finished)) }
        return words
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 30
        return request
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        var last: Error = VoiceError.service("ElevenLabs could not be reached.")
        for attempt in 0 ..< 3 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                last = VoiceError.service("ElevenLabs could not be reached: \(error.localizedDescription)")
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if status == 200, let object { return object }
            let failure = Self.failure(status: status, body: object)
            last = VoiceError.service(failure.message)
            if !failure.retryable { break }
        }
        throw last
    }

    /// Turns an error from ElevenLabs into something a person can act on.
    static func failure(status: Int, body: [String: Any]?) -> (message: String, retryable: Bool) {
        // {"detail": {"type": "...", "code": "...", "message": "..."}}, or for
        // a malformed request {"detail": [{"msg": "..."}]}.
        let detail = body?["detail"] as? [String: Any]
        let code = detail?["code"] as? String ?? detail?["status"] as? String ?? ""
        let said = detail?["message"] as? String ?? ((body?["detail"] as? [[String: Any]])?.first?["msg"] as? String)
        switch (status, code) {
        case (401, _), (_, "invalid_api_key"), (_, "missing_api_key"):
            return ("ElevenLabs did not accept the API key. Check it in AI settings.", false)
        case (402, _), (_, "insufficient_credits"), (_, "quota_exceeded"):
            return ("Your ElevenLabs plan does not have enough credits left for this voiceover.", false)
        case (_, "voice_not_found"), (_, "voice_access_denied"):
            return ("That voice is no longer available in your ElevenLabs account. Choose another voice.", false)
        case (_, "text_too_long"):
            return ("A scene's narration is too long for ElevenLabs to speak in one go. Shorten it.", false)
        case (403, _):
            return ("Your ElevenLabs key is not allowed to do this: \(said ?? "permission denied").", false)
        case (429, _):
            return ("ElevenLabs is busy or your plan's rate limit was reached. Wait a moment and try again.", true)
        case (500 ..< 600, _):
            return ("ElevenLabs' service is having trouble right now. Try again in a moment.", true)
        default:
            return ("ElevenLabs rejected the request: \(said ?? "error \(status)").", false)
        }
    }
}

/// The voiceover of a video: which lines need speaking, the speech kept from
/// earlier so nothing is paid for twice, and the speaking itself.
public enum Narration {
    /// One scene's line, spoken and saved.
    public struct Line: Codable, Equatable, Sendable {
        /// The MP3 in the cache.
        public var file: URL
        public var seconds: Double
        public var words: [NarrationWord]
    }

    /// One scene's line, to be spoken.
    public struct Need: Equatable, Sendable {
        /// Position of the scene in the storyboard, from 0.
        public var scene: Int
        public var text: String
        /// Names the saved speech: the same words in the same voice give the
        /// same name.
        public var key: String
        public var isSpoken: Bool
    }

    /// Silence before a scene's line starts and after it ends.
    public static let leadIn = 0.25
    public static let leadOut = 0.45

    /// How long a line is likely to take, before it has been spoken: about
    /// fourteen characters a second, the pace of an unhurried narrator.
    /// Arabic and Hebrew leave most vowels unwritten, so the same number of
    /// characters takes longer to say.
    public static func estimate(_ text: String) -> Double {
        let rightToLeft = text.unicodeScalars.filter { (0x0590 ... 0x08FF).contains($0.value) }.count * 2 > text.unicodeScalars.count
        return Double(text.count) / (rightToLeft ? 10 : 14)
    }

    static func key(text: String, voice: String) -> String {
        let digest = SHA256.hash(data: Data("\(ElevenLabsClient.model)|\(voice)|\(text)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The lines a storyboard asks to have spoken, and whether each is
    /// already in `cache` in this voice.
    public static func needs(in plan: Storyboard.Plan, voice: String, cache: URL) -> [Need] {
        let scenes = plan.storyboard["scenes"] as? [[String: Any]] ?? []
        return scenes.enumerated().compactMap { index, scene in
            guard let text = scene["say"] as? String, !text.isEmpty else { return nil }
            let key = key(text: text, voice: voice)
            return Need(scene: index, text: text, key: key, isSpoken: line(key, in: cache) != nil)
        }
    }

    /// Characters that would be sent to ElevenLabs, and so charged.
    public static func charactersToSpeak(_ needs: [Need]) -> Int {
        needs.filter { !$0.isSpoken }.reduce(0) { $0 + $1.text.count }
    }

    private static func line(_ key: String, in cache: URL) -> Line? {
        let audio = cache.appendingPathComponent("\(key).mp3")
        guard FileManager.default.fileExists(atPath: audio.path),
              let data = try? Data(contentsOf: cache.appendingPathComponent("\(key).json")),
              var line = try? JSONDecoder().decode(Line.self, from: data), line.seconds > 0 else { return nil }
        line.file = audio
        return line
    }

    /// The lines already spoken, by scene, without asking for any more.
    public static func spoken(_ needs: [Need], cache: URL) -> [Int: Line] {
        var lines: [Int: Line] = [:]
        for need in needs { lines[need.scene] = line(need.key, in: cache) }
        return lines
    }

    /// Speaks every line that is not in the cache yet and returns them all,
    /// by scene. `progress` receives how many are done and how many there are.
    public static func speak(_ needs: [Need], voice: String, client: ElevenLabsClient, cache: URL,
                             progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [Int: Line] {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var lines: [Int: Line] = [:]
        let waiting = needs.filter { !$0.isSpoken }
        var done = 0
        for (position, need) in needs.enumerated() {
            if let have = line(need.key, in: cache) {
                lines[need.scene] = have
                continue
            }
            try Task.checkCancellation()
            progress(done, waiting.count)
            let speech = try await client.speak(need.text, voice: voice,
                                                before: position > 0 ? needs[position - 1].text : nil,
                                                after: position + 1 < needs.count ? needs[position + 1].text : nil)
            let audio = cache.appendingPathComponent("\(need.key).mp3")
            try speech.audio.write(to: audio, options: .atomic)
            // The file's own length, which includes any quiet at its end.
            var seconds = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? 0
            if !seconds.isFinite || seconds <= 0 { seconds = speech.words.last?.end ?? 0 }
            guard seconds > 0 else {
                try? FileManager.default.removeItem(at: audio)
                throw VoiceError.service("ElevenLabs sent sound that could not be played. Try again.")
            }
            let line = Line(file: audio, seconds: (seconds * 100).rounded() / 100, words: speech.words)
            try JSONEncoder().encode(line).write(to: cache.appendingPathComponent("\(need.key).json"), options: .atomic)
            lines[need.scene] = line
            done += 1
        }
        progress(waiting.count, waiting.count)
        return lines
    }
}
