import Foundation

/// Writes and revises a storyboard from a conversation. The model answers in
/// plain words and, when the video changes, with the whole storyboard; every
/// storyboard is checked before it is accepted, and a faulty one is sent back
/// to the model once with the list of what is wrong.
public enum StoryboardWriter {
    public struct Answer: Equatable, Sendable {
        /// What the model says to the user.
        public var reply: String
        /// The new storyboard, ready to save, when the answer changed it.
        public var storyboard: String?
        /// Why the storyboard in the answer was turned down, when it was.
        public var problems: [String]
        /// Lasting facts about the project the model asked to have kept.
        public var remembered: [String]

        public init(reply: String, storyboard: String? = nil, problems: [String] = [], remembered: [String] = []) {
            self.reply = reply
            self.storyboard = storyboard
            self.problems = problems
            self.remembered = remembered
        }
    }

    public enum WriterError: LocalizedError, Equatable {
        case silent
        case declined

        public var errorDescription: String? {
            switch self {
            case .silent:
                return "The AI model did not answer. Try again."
            case .declined:
                return "The AI model declined this request. Try describing the video differently."
            }
        }
    }

    /// Answers the last message in `messages`, which must be the user's.
    ///
    /// - Parameters:
    ///   - storyboard: the storyboard file as it is now, if there is one.
    ///   - directory: the project folder; files in a storyboard are relative to it.
    ///   - memory: what is known about the project the video belongs to.
    ///   - looks: pictures of the materials, for models that can see.
    ///   - partial: receives the reply so far while it is being written.
    public static func answer(messages: [StudioMessage], materials: [StudioMaterial], storyboard: String?, directory: URL,
                              memory: String? = nil, model: any TextModel, looks: StudioWorkspace.Looks = .init(),
                              partial: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Answer {
        let images = model.seesImages ? looks.images : []
        let prompt = Prompt.request(messages: messages, materials: materials, storyboard: storyboard, memory: memory,
                                    labels: model.seesImages ? looks.labels : [:], budget: model.transcriptBudget)
        let first = try await ask(model, prompt: prompt, images: images) { partial(Reply.visible($0)) }
        guard var proposed = first.storyboard else { return Answer(reply: first.reply, remembered: first.remembered) }
        var reply = first.reply
        var raw = first.raw

        // A faulty storyboard goes back to the model with exactly what is
        // wrong. Twice at most: some problems (a scene longer than its clip)
        // only show once the others are fixed.
        var problems = await check(proposed, directory: directory)
        for _ in 0 ..< 2 where !problems.isEmpty {
            try Task.checkCancellation()
            let again = try await ask(model, prompt: Prompt.repair(prompt, answer: raw, problems: problems), images: images) { _ in }
            guard let fixed = again.storyboard else { break }
            proposed = fixed
            raw = again.raw
            if !again.reply.isEmpty { reply = again.reply }
            problems = await check(fixed, directory: directory)
        }
        guard problems.isEmpty else { return Answer(reply: first.reply, problems: problems, remembered: first.remembered) }
        return Answer(reply: reply.isEmpty ? "The storyboard is ready." : reply, storyboard: Storyboard.text(for: proposed),
                      remembered: first.remembered)
    }

    private static func ask(_ model: any TextModel, prompt: String, images: [ModelImage],
                            partial: @escaping @Sendable (String) -> Void) async throws -> Reply {
        let raw: String
        do {
            raw = try await model.write(system: Prompt.system, prompt: prompt, images: images, partial: partial)
        } catch NotesError.declined {
            throw WriterError.declined
        }
        let reply = Reply(raw)
        if reply.reply.isEmpty, reply.storyboard == nil, reply.remembered.isEmpty { throw WriterError.silent }
        return reply
    }

    /// Everything wrong with a storyboard, in the words shown to a person.
    static func check(_ storyboard: [String: Any], directory: URL) async -> [String] {
        guard let data = try? JSONSerialization.data(withJSONObject: storyboard) else { return ["The storyboard could not be read."] }
        do {
            let plan = try Storyboard.plan(from: data, baseDirectory: directory)
            return await StudioProject.clipProblems(in: plan)
        } catch StoryboardError.invalid(let problems) {
            return problems
        } catch {
            return [error.localizedDescription]
        }
    }

    // MARK: - Reading an answer

    /// A model's answer split into the words for the user, the storyboard,
    /// and anything it asked to have remembered.
    struct Reply {
        var raw: String
        var reply: String
        var storyboard: [String: Any]?
        var remembered: [String] = []

        init(_ text: String) {
            var body = text
            // Reasoning some local models print before the answer.
            while let open = body.range(of: "<think>"), let close = body.range(of: "</think>", range: open.upperBound ..< body.endIndex) {
                body.removeSubrange(open.lowerBound ..< close.upperBound)
            }
            raw = body

            // Things to remember come in their own block, one to a line.
            for block in Self.fences(in: body).reversed() where block.language == "remember" {
                let lines = body[block.inner].split(separator: "\n").map { line -> String in
                    var line = line.trimmingCharacters(in: .whitespaces)
                    for mark in ["- ", "* ", "• "] where line.hasPrefix(mark) { line = String(line.dropFirst(mark.count)) }
                    return line.trimmingCharacters(in: .whitespaces)
                }
                remembered = lines.filter { !$0.isEmpty } + remembered
                body.removeSubrange(block.whole)
            }
            reply = body.trimmingCharacters(in: .whitespacesAndNewlines)

            // The storyboard is the last fenced block that holds one...
            for block in Self.fences(in: body).reversed() {
                if let found = Self.storyboard(in: String(body[block.inner])) {
                    storyboard = found
                    var rest = body
                    rest.removeSubrange(block.whole)
                    reply = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
            }
            // ...or, from a model that forgot the fence, the braces themselves.
            if let first = body.firstIndex(of: "{"), let last = body.lastIndex(of: "}"), first < last,
               let found = Self.storyboard(in: String(body[first ... last])) {
                storyboard = found
                reply = (String(body[..<first]) + String(body[body.index(after: last)...])).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        /// The part of a half-written answer that is safe to show: the words
        /// before the storyboard starts.
        static func visible(_ partial: String) -> String {
            var text = partial
            if let open = text.range(of: "<think>") {
                if let close = text.range(of: "</think>", range: open.upperBound ..< text.endIndex) {
                    text.removeSubrange(open.lowerBound ..< close.upperBound)
                } else {
                    text.removeSubrange(open.lowerBound...)
                }
            }
            if let fence = text.range(of: "```") { text = String(text[..<fence.lowerBound]) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func storyboard(in text: String) -> [String: Any]? {
            guard let data = text.data(using: .utf8),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            // Some models wrap it: {"storyboard": {...}}.
            if object["scenes"] == nil, let inner = object["storyboard"] as? [String: Any] { object = inner }
            return object["scenes"] != nil ? object : nil
        }

        private static func fences(in text: String) -> [(whole: Range<String.Index>, inner: Range<String.Index>, language: String)] {
            var found: [(Range<String.Index>, Range<String.Index>, String)] = []
            var cursor = text.startIndex
            while let open = text.range(of: "```", range: cursor ..< text.endIndex) {
                // Skip the language name on the opening line.
                let lineEnd = text[open.upperBound...].firstIndex(of: "\n") ?? text.endIndex
                guard let close = text.range(of: "```", range: lineEnd ..< text.endIndex) else { break }
                let language = text[open.upperBound ..< lineEnd].trimmingCharacters(in: .whitespaces).lowercased()
                found.append((open.lowerBound ..< close.upperBound, lineEnd ..< close.lowerBound, language))
                cursor = close.upperBound
            }
            return found
        }
    }

    // MARK: - What the model is told

    enum Prompt {
        static let system = """
        You are the writer inside Tasjeel Studio, a Mac app that makes short marketing videos. The person you are talking to describes a video and hands over material: screenshots, a logo, screen recordings. You write the video as a storyboard. Tasjeel turns the storyboard into a finished video in three sizes (wide, square and tall), with the layout and motion done for you. The person then asks for changes and you revise it.

        The person reads your reply in a chat beside a preview of the video. They are not expected to read JSON, so talk about the video (its scenes, its words, its timing), not about fields.

        # How to answer

        Write a short reply in the language the person writes in: what you made or changed, and anything they should check or supply. A few plain sentences, no headings and no lists of every scene; they can see the scenes.

        When you create or change the video, put the complete storyboard after your reply in one ```json block. Always send the whole storyboard, never a fragment, because Tasjeel replaces the file with what you send. When nothing changes (they asked a question, or you need an answer before you can write), leave the block out.

        Write a first version as soon as you know roughly what the product is and who the video is for. A draft to react to is worth more than questions. Ask before writing only when you could not make an honest video without the answer.

        # The storyboard

        {
          "title": "Launch video",
          "language": "en",
          "formats": ["wide", "square", "tall"],
          "brand": { "name": "Acme", "logo": "materials/logo.png", "background": "#0C0D11", "text": "#FFFFFF", "accent": "#8F7CFF" },
          "scenes": [
            { "type": "hook", "text": "Export in 4K. In one click.", "kicker": "NEW" },
            { "type": "screen", "video": "materials/demo.mov", "start": 12, "seconds": 6, "caption": "Pick a size, press Export." },
            { "type": "cta", "text": "Try it today", "link": "example.com" }
          ]
        }

        Top level: "title"; "language" (the language of the video's words, such as "en" or "ar"; Arabic and Hebrew are laid out right to left automatically); "formats" (any of "wide", "square", "tall"; leave it out for all three); "brand"; "scenes" (1 to 40, in order).

        Brand: "name" (shown at the end when there is no logo), "logo" (a picture from the materials), and three colours written like "#8F7CFF": "background", "text", "accent". Leave a colour out to keep the default dark look. When you can see the product or the logo, pick colours that suit it, and keep text easy to read against the background.

        Every scene has a "type" and may have "seconds" (1 to 30). The number after each field is the most characters it may hold; text is shown large, so shorter is better.

        - "hook": the opening line, its words rising in one by one. "text" (required, 140), "kicker" (a small line above, such as "NEW", 60). 3 seconds if you do not say.
        - "screen": a piece of a video from the materials, shown as a floating window. "video" (required), "start" (where in the video to begin, in seconds), "caption" (a line under it, 140), "sound" (true to keep the video's sound; silent otherwise). 6 seconds. "start" plus "seconds" must not run past the end of the video.
        - "feature": one thing the product does. "headline" (required, 100), "points" (up to 4 short lines, 110 each), "image" (a picture from the materials, optional). 5 seconds.
        - "quote": something a customer said. "quote" (required, 260), "name" (60), "role" (80). 4.5 seconds.
        - "numbers": one to three figures that count up. "items" (required), each with "value" (a number), and optionally "prefix" (such as "$", 6), "suffix" (such as "K", "%" or " fps", 8) and "label" (40); "headline" (100). 4.5 seconds.
        - "cta": the closing scene, with the logo. "text" (required, 100), "link" (a web address shown in a button, 80). 3.5 seconds.

        Use no other fields; Tasjeel rejects a storyboard with a field it does not know.

        # What makes it good, honest and buildable

        - Use only the files listed under Materials, written exactly as they are listed. If a scene would need a picture or clip that is not there, write the video without it (a feature scene works without an image) and say in your reply what would improve it.
        - Never invent a customer's words, a person's name, or a figure. Use a quote or numbers scene only with words and figures the person gave you, that are in the project's memory, or that you can read in their material. If one would help the video, ask for it in your reply.
        - Do not promise what the material does not show. Describe the product as the person described it.
        - Unless asked otherwise: 15 to 45 seconds in all, four to eight scenes, opening with a hook and closing with a cta. Give a scene enough time to be read: about one second for every three words on screen, and never under 2.5 seconds.
        - For a recording, choose the part worth showing. When you are told what is said at which time, use it to pick "start".
        - Write like a person talking to another person. One idea per scene. No filler such as "revolutionary" or "seamless".

        # The project's memory

        A video usually belongs to a project: a product or an app the person makes many videos for. When the request starts with "About the project", that is what Tasjeel has remembered about it. Rely on it instead of asking again: its audience, the way it talks, its features, its brand colours and logo. Facts listed there as true may be shown in the video. What the person says in the chat wins over the memory where they differ.

        When the person tells you something that will still be true for the next video (who the product is for, a feature, a figure, a customer's words, how they like things written, a colour), add a block like this after everything else, one fact to a line, each understandable on its own:

        ```remember
        The audience is clinic owners in the Gulf, not developers.
        They never want the word "AI" on screen.
        ```

        Tasjeel saves those lines to the project's memory and shows the person what was saved. Leave the block out when there is nothing new and lasting; a request about this one video ("shorter intro") is not something to remember, and neither is anything already in the memory.
        """

        static func request(messages: [StudioMessage], materials: [StudioMaterial], storyboard: String?, memory: String? = nil,
                            labels: [String: [String]], budget: Int) -> String {
            var parts: [String] = []
            if var memory = memory?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
                // Never more than a third of what a small model can read.
                if memory.count > budget / 3 { memory = String(memory.prefix(budget / 3)) + " […]" }
                parts.append("# About the project\n\n\(memory)")
            }

            // Notes on materials (what is said in a recording) are trimmed
            // for models that can only read a little.
            let noteBudget = max(400, budget / 4 / max(materials.filter { $0.note != nil }.count, 1))
            if materials.isEmpty {
                parts.append("# Materials\n\nNone yet.")
            } else {
                let lines = materials.map { describe($0, shown: labels[$0.file] ?? [], noteBudget: noteBudget) }
                parts.append("# Materials\n\n" + lines.joined(separator: "\n"))
            }

            if let storyboard, !storyboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("# The storyboard as it is now\n\n```json\n\(storyboard.trimmingCharacters(in: .whitespacesAndNewlines))\n```")
            } else {
                parts.append("# The storyboard as it is now\n\nThere is none yet.")
            }

            let latest = messages.last?.text ?? ""
            var earlier = Array(messages.dropLast().suffix(40))
            let fixed = parts.joined().count + latest.count + system.count
            // The oldest lines go first when the model cannot hold them all.
            while earlier.count > 2, fixed + earlier.reduce(0, { $0 + $1.text.count + 12 }) > budget { earlier.removeFirst() }
            if !earlier.isEmpty {
                let lines = earlier.map { "\($0.role == .user ? "Person" : "You"): \($0.text)" }
                parts.append("# The conversation so far\n\n" + lines.joined(separator: "\n\n"))
            }
            parts.append("# The person's new message\n\n\(latest)")
            return parts.joined(separator: "\n\n")
        }

        static func describe(_ material: StudioMaterial, shown: [String], noteBudget: Int) -> String {
            var line = "- \"\(material.file)\": "
            switch material.kind {
            case .picture:
                line += "a picture, \(material.width) by \(material.height)."
            case .video:
                let seconds = material.seconds ?? 0
                let length = seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
                line += "a video, \(length) seconds long, \(material.width) by \(material.height)."
            }
            if !shown.isEmpty { line += " Shown to you as \(shown.joined(separator: ", "))." }
            if var note = material.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                if note.count > noteBudget { note = String(note.prefix(noteBudget)) + " […]" }
                line += "\n  " + note.replacingOccurrences(of: "\n", with: "\n  ")
            }
            return line
        }

        static func repair(_ request: String, answer: String, problems: [String]) -> String {
            """
            \(request)

            # Your answer, which Tasjeel could not use

            \(answer.trimmingCharacters(in: .whitespacesAndNewlines))

            # What is wrong with that storyboard

            \(problems.map { "- \($0)" }.joined(separator: "\n"))

            Answer the person's message again with these fixed: your reply, then the complete corrected storyboard in a ```json block. The person never saw the answer above, so do not mention the correction.
            """
        }
    }

    // MARK: - Describing a recording

    /// What a Tasjeel recording is about, for the note on its material: its
    /// title, the summary from its notes, and what is said when.
    public static func note(forRecording title: String, transcript: Transcript?, notes: MeetingNotes?) -> String {
        var lines = ["A Tasjeel screen recording called \"\(title)\"."]
        if let summary = notes?.summary, !summary.isEmpty { lines.append("About: \(summary)") }
        if let chapters = notes?.chapters, !chapters.isEmpty {
            lines.append("Parts: " + chapters.map { "\(NotesFormat.stamp($0.start)) \($0.title)" }.joined(separator: "; "))
        }
        if let segments = transcript?.segments, !segments.isEmpty {
            lines.append("What is said, with the time each line starts:")
            lines += segments.map { "[\(NotesFormat.stamp($0.start))] \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }
}
