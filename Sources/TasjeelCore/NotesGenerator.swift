import Foundation

/// A language model that turns a prompt into text. Tasjeel talks to three of
/// them (Apple's on-device model, a local model in Ollama, Claude through the
/// user's own API key) and none of the code that writes notes cares which.
public protocol TextModel: Sendable {
    /// Shown to the user and saved with the notes, e.g. "Claude Opus 5.5".
    var displayName: String { get }
    /// How many characters of transcript fit comfortably in one request.
    /// Longer transcripts are summarised in parts and then combined.
    var transcriptBudget: Int { get }
    /// True when the text of the request leaves this Mac.
    var isCloud: Bool { get }
    /// Answers `prompt`. `schema` is a JSON Schema the answer should follow,
    /// for models that can be held to one. `progress` receives the number of
    /// characters written so far.
    func generate(system: String, prompt: String, schema: String,
                  progress: @escaping @Sendable (Int) -> Void) async throws -> String
}

public enum NotesError: LocalizedError, Equatable {
    case noSpeech
    case unreadable
    case declined
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .noSpeech:
            return "There is no speech in the transcript to write notes from."
        case .unreadable:
            return "The AI model did not return notes in a form Tasjeel could read. Try again, or pick a different model in AI settings."
        case .declined:
            return "The AI model declined to write notes for this recording."
        case .engine(let reason):
            return reason
        }
    }
}

/// Writes meeting notes from a transcript with whichever model it is given.
public enum NotesGenerator {
    /// `progress` receives a fraction (0 ... 1) and a short description.
    public static func notes(for transcript: Transcript, duration: Double, model: any TextModel,
                             progress: @escaping @Sendable (Double, String) -> Void) async throws -> MeetingNotes {
        let lines = transcriptLines(transcript)
        guard !lines.isEmpty else { throw NotesError.noSpeech }
        let system = NotesPrompt.system(language: transcript.language, speakers: transcript.hasSpeakers)
        let parts = chunks(of: lines, budget: max(model.transcriptBudget, 1500))

        let draft: NotesDraft
        if parts.count == 1 {
            progress(0.05, "Reading the transcript…")
            draft = try await ask(model, system: system, prompt: NotesPrompt.whole(parts[0]), duration: duration) { written in
                // No way to know the length in advance; creep towards the end.
                progress(min(0.95, 0.1 + Double(written) / 2500), "Writing notes…")
            }
        } else {
            // Too long for one request: write notes for each part, then
            // combine them into one set.
            var drafts: [NotesDraft] = []
            let share = 0.8 / Double(parts.count)
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                let base = Double(index) * share
                let label = "Reading part \(index + 1) of \(parts.count)…"
                progress(base, label)
                let prompt = NotesPrompt.part(part, index: index + 1, count: parts.count)
                drafts.append(try await ask(model, system: system, prompt: prompt, duration: duration) { written in
                    progress(base + share * min(0.95, Double(written) / 1800), label)
                })
            }
            progress(0.82, "Putting the notes together…")
            draft = try await combine(drafts, model: model, system: system, duration: duration) { written in
                progress(min(0.97, 0.82 + Double(written) / 12000), "Putting the notes together…")
            }
        }
        progress(1, "Done")
        guard !draft.summary.isEmpty || !draft.keyPoints.isEmpty else { throw NotesError.unreadable }
        return MeetingNotes(title: draft.title, summary: draft.summary, keyPoints: draft.keyPoints, decisions: draft.decisions,
                            actionItems: draft.actionItems, chapters: NotesParser.tidied(draft.chapters, duration: duration),
                            engine: model.displayName, language: transcript.language)
    }

    // MARK: - Steps

    /// One request, read leniently, with a single retry: small local models
    /// occasionally wrap or break their JSON.
    private static func ask(_ model: any TextModel, system: String, prompt: String, duration: Double,
                            progress: @escaping @Sendable (Int) -> Void) async throws -> NotesDraft {
        for attempt in 0 ..< 2 {
            try Task.checkCancellation()
            let text = try await model.generate(system: system, prompt: prompt, schema: NotesPrompt.schema, progress: progress)
            if let draft = NotesParser.draft(from: text) { return draft }
            if attempt == 1 { break }
        }
        throw NotesError.unreadable
    }

    /// Merges the notes of several parts. When even those are too long for
    /// one request (a small model and a long meeting), merges them in groups
    /// first.
    private static func combine(_ drafts: [NotesDraft], model: any TextModel, system: String, duration: Double,
                                progress: @escaping @Sendable (Int) -> Void) async throws -> NotesDraft {
        let budget = max(model.transcriptBudget, 1500)
        let texts = drafts.map(NotesPrompt.describe)
        if texts.reduce(0, { $0 + $1.count }) > budget, drafts.count > 2 {
            var groups: [[NotesDraft]] = [[]]
            var size = 0
            for (draft, text) in zip(drafts, texts) {
                if size + text.count > budget, groups[groups.count - 1].count >= 2 {
                    groups.append([])
                    size = 0
                }
                groups[groups.count - 1].append(draft)
                size += text.count
            }
            if groups.count > 1, groups.count < drafts.count {
                var merged: [NotesDraft] = []
                for group in groups {
                    merged.append(group.count == 1 ? group[0]
                        : try await combine(group, model: model, system: system, duration: duration, progress: { _ in }))
                }
                return try await combine(merged, model: model, system: system, duration: duration, progress: progress)
            }
        }
        var result = try await ask(model, system: system, prompt: NotesPrompt.combine(texts), duration: duration, progress: progress)
        // The parts know their own chapters best; fall back to them if the
        // combining step returned none.
        if result.chapters.isEmpty { result.chapters = drafts.flatMap(\.chapters) }
        return result
    }

    // MARK: - Transcript text

    /// `[12:34] You: text`, one string per transcript line.
    static func transcriptLines(_ transcript: Transcript) -> [String] {
        let speakers = transcript.hasSpeakers
        return transcript.segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let who = speakers ? (TranscriptFormat.speakerName(segment.speaker).map { "\($0): " } ?? "") : ""
            return "[\(NotesFormat.stamp(segment.start))] \(who)\(text)"
        }
    }

    /// Splits lines into pieces of at most `budget` characters, never
    /// breaking a line.
    static func chunks(of lines: [String], budget: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count + 1 > budget {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.isEmpty { result.append(current) }
        // Even pieces read better than a long one followed by a scrap.
        if result.count > 1, let last = result.last, last.count < budget / 4 {
            let total = lines.reduce(0) { $0 + $1.count + 1 }
            let even = total / result.count + 200
            if even < budget { return chunks(of: lines, budget: even) }
        }
        return result
    }
}

// MARK: - Prompts

enum NotesPrompt {
    static func system(language: String, speakers: Bool) -> String {
        let name = Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
        var text = """
        You write notes from the transcript of a screen recording: usually a meeting, sometimes a walkthrough or a demo. \
        Each line starts with the time it was said, like [12:34].
        """
        if speakers {
            text += " \"You\" is the person who made the recording; \"Others\" is everyone else on the call, which may be more than one person."
        }
        text += """


        The transcript was made by speech recognition. Expect misheard words, wrong names and missing punctuation, and work out \
        what was meant. Report only what was said: if something is unclear, leave it out rather than guess.

        Write every piece of text in \(name), the language of the transcript. Answer with one JSON object and nothing else:

        - "title": a short, specific name for the recording, at most eight words, with no date.
        - "summary": two to five sentences on what it was about and what came out of it.
        - "key_points": the points worth remembering, most important first, at most eight. One sentence each.
        - "decisions": things that were actually agreed. An empty list if nothing was decided.
        - "action_items": things someone said they would do or was asked to do. "task" says what; "owner" says who \
        (a name if one was said, otherwise "You" or "Others", or "" when it is not clear). An empty list if there are none.
        - "chapters": the main topics in the order they came up. "time" is the stamp of the line where the topic starts, \
        copied exactly from the transcript; "title" is two to six words. Roughly one chapter for every few minutes, \
        fewer for a short recording, never more than twelve. The first chapter starts at the first line.
        """
        return text
    }

    static func whole(_ transcript: String) -> String {
        "Here is the transcript.\n\n<transcript>\n\(transcript)\n</transcript>"
    }

    static func part(_ transcript: String, index: Int, count: Int) -> String {
        """
        This is part \(index) of \(count) of a longer recording. Write notes for this part only; they will be combined \
        with the notes for the other parts afterwards. Keep them brief.

        <transcript>
        \(transcript)
        </transcript>
        """
    }

    static func combine(_ parts: [String]) -> String {
        """
        A long recording was read in \(parts.count) parts. Here are the notes for each part, in order. Combine them into \
        one set of notes for the whole recording: one title, one summary, and the key points, decisions and action items \
        with repeats merged. For the chapters, choose from the chapters listed and keep their times exactly as given.

        \(parts.enumerated().map { "<part number=\"\($0.offset + 1)\">\n\($0.element)\n</part>" }.joined(separator: "\n\n"))
        """
    }

    /// One part's notes as plain text for the combining step.
    static func describe(_ draft: NotesDraft) -> String {
        var lines: [String] = []
        if !draft.title.isEmpty { lines.append("Title: \(draft.title)") }
        if !draft.summary.isEmpty { lines.append("Summary: \(draft.summary)") }
        if !draft.keyPoints.isEmpty { lines.append("Key points:\n" + draft.keyPoints.map { "- \($0)" }.joined(separator: "\n")) }
        if !draft.decisions.isEmpty { lines.append("Decisions:\n" + draft.decisions.map { "- \($0)" }.joined(separator: "\n")) }
        if !draft.actionItems.isEmpty {
            lines.append("Action items:\n" + draft.actionItems.map { item in
                "- \(item.text)" + ((item.owner ?? "").isEmpty ? "" : " (owner: \(item.owner ?? ""))")
            }.joined(separator: "\n"))
        }
        if !draft.chapters.isEmpty {
            lines.append("Chapters:\n" + draft.chapters.map { "- [\(NotesFormat.stamp($0.start))] \($0.title)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    /// The shape of the answer, as a JSON Schema. Every object lists all its
    /// fields as required and allows no others, which is what the stricter
    /// engines insist on.
    static let schema = """
    {"type":"object","properties":{"title":{"type":"string"},"summary":{"type":"string"},\
    "key_points":{"type":"array","items":{"type":"string"}},"decisions":{"type":"array","items":{"type":"string"}},\
    "action_items":{"type":"array","items":{"type":"object","properties":{"task":{"type":"string"},"owner":{"type":"string"}},\
    "required":["task","owner"],"additionalProperties":false}},\
    "chapters":{"type":"array","items":{"type":"object","properties":{"time":{"type":"string"},"title":{"type":"string"}},\
    "required":["time","title"],"additionalProperties":false}}},\
    "required":["title","summary","key_points","decisions","action_items","chapters"],"additionalProperties":false}
    """
}

// MARK: - Reading the answer

/// Notes as a model returned them, before tidying.
struct NotesDraft: Equatable {
    var title = ""
    var summary = ""
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
    var chapters: [NoteChapter] = []
}

enum NotesParser {
    /// Reads a model's answer. Models that cannot be held to a schema wrap
    /// their JSON in prose or code fences, rename fields and change types, so
    /// this takes whatever is recognisable. Nil when there is no JSON object.
    static func draft(from text: String) -> NotesDraft? {
        guard let object = jsonObject(in: text) else { return nil }
        func value(_ names: String...) -> Any? {
            for name in names {
                if let found = object[name] { return found }
            }
            let lowered = Dictionary(object.map { ($0.key.lowercased().replacingOccurrences(of: "_", with: ""), $0.value) },
                                     uniquingKeysWith: { first, _ in first })
            for name in names {
                if let found = lowered[name.lowercased().replacingOccurrences(of: "_", with: "")] { return found }
            }
            return nil
        }
        func string(_ any: Any?) -> String {
            switch any {
            case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
            case let n as NSNumber: return n.stringValue
            default: return ""
            }
        }
        func strings(_ any: Any?) -> [String] {
            switch any {
            case let list as [Any]:
                return list.map { item -> String in
                    if let dict = item as? [String: Any] {
                        return string(dict["text"] ?? dict["point"] ?? dict["decision"] ?? dict.values.first { $0 is String })
                    }
                    return string(item)
                }
                .filter { !$0.isEmpty }
            case let s as String:
                return s.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t")) }
                    .filter { !$0.isEmpty }
            default:
                return []
            }
        }

        var draft = NotesDraft()
        draft.title = string(value("title", "name"))
        draft.summary = string(value("summary", "overview"))
        draft.keyPoints = strings(value("key_points", "keyPoints", "points", "highlights"))
        draft.decisions = strings(value("decisions"))

        if let items = value("action_items", "actionItems", "actions", "todos") as? [Any] {
            draft.actionItems = items.compactMap { item in
                if let dict = item as? [String: Any] {
                    let text = string(dict["task"] ?? dict["text"] ?? dict["action"] ?? dict["item"] ?? dict["description"])
                    let owner = string(dict["owner"] ?? dict["assignee"] ?? dict["who"])
                    let unknown = ["", "unknown", "unclear", "n/a", "none", "null"].contains(owner.lowercased())
                    return text.isEmpty ? nil : ActionItem(text: text, owner: unknown ? nil : owner)
                }
                let text = string(item)
                return text.isEmpty ? nil : ActionItem(text: text)
            }
        }
        if let items = value("chapters", "topics", "sections") as? [Any] {
            draft.chapters = items.compactMap { item in
                guard let dict = item as? [String: Any] else { return nil }
                let title = string(dict["title"] ?? dict["name"] ?? dict["topic"])
                guard !title.isEmpty, let start = seconds(dict["time"] ?? dict["start"] ?? dict["timestamp"]) else { return nil }
                return NoteChapter(start: start, title: title)
            }
        }
        return draft
    }

    /// Chapters in order, inside the recording, not bunched together, and
    /// starting at the beginning.
    static func tidied(_ chapters: [NoteChapter], duration: Double) -> [NoteChapter] {
        // Chapters closer together than this are one topic: 15 seconds, or
        // less in a recording too short for that to make sense.
        let apart = min(15, max(4, duration / 12))
        var result: [NoteChapter] = []
        for chapter in chapters.sorted(by: { $0.start < $1.start }) where chapter.start >= 0 && chapter.start < max(duration, 1) {
            if let last = result.last, chapter.start - last.start < apart { continue }
            result.append(chapter)
        }
        if !result.isEmpty { result[0].start = 0 }
        return Array(result.prefix(20))
    }

    /// `12:34`, `1:02:03`, `[12:34]`, `754` or 754 as seconds.
    static func seconds(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        guard let raw = any as? String else { return nil }
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]() \t"))
        let pieces = text.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !pieces.isEmpty, pieces.count <= 3, !pieces.contains(where: { $0 == nil }) else { return nil }
        return pieces.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// Finds the JSON object in an answer that may also contain reasoning,
    /// prose or code fences.
    static func jsonObject(in text: String) -> [String: Any]? {
        var body = text
        // Reasoning some local models print before the answer.
        while let open = body.range(of: "<think>"), let close = body.range(of: "</think>", range: open.upperBound ..< body.endIndex) {
            body.removeSubrange(open.lowerBound ..< close.upperBound)
        }
        guard let first = body.firstIndex(of: "{"), let last = body.lastIndex(of: "}"), first < last else { return nil }
        let candidate = String(body[first ... last])
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}
