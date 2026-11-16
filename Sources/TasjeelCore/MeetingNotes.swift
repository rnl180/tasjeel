import Foundation

/// A topic in the recording and the moment it starts (source seconds).
public struct NoteChapter: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var title: String

    public init(id: UUID = UUID(), start: Double, title: String) {
        self.id = id
        self.start = start
        self.title = title
    }
}

/// Something somebody said they would do.
public struct ActionItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    /// Who is to do it, when the recording says: "You", "Others" or a name.
    public var owner: String?

    public init(id: UUID = UUID(), text: String, owner: String? = nil) {
        self.id = id
        self.text = text
        self.owner = owner
    }
}

/// What an AI model made of a transcript: a title, a summary, the points
/// worth keeping, and chapters for finding your way around the video.
public struct MeetingNotes: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var chapters: [NoteChapter]
    /// The model that wrote the notes, as shown to the user.
    public var engine: String
    /// BCP 47 tag of the transcript the notes were written from.
    public var language: String
    public var createdAt: Date

    public init(title: String, summary: String, keyPoints: [String] = [], decisions: [String] = [],
                actionItems: [ActionItem] = [], chapters: [NoteChapter] = [], engine: String, language: String,
                createdAt: Date = Date()) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.chapters = chapters
        self.engine = engine
        self.language = language
        self.createdAt = createdAt
    }

    /// The chapters as they apply to the edited video. A chapter that starts
    /// inside a cut begins where the video picks up again; a chapter that was
    /// cut out completely is dropped.
    public func editedChapters(with map: TimeMap) -> [NoteChapter] {
        let sorted = chapters.sorted { $0.start < $1.start }
        var result: [NoteChapter] = []
        for (index, chapter) in sorted.enumerated() {
            let end = index + 1 < sorted.count ? sorted[index + 1].start : Double.greatestFiniteMagnitude
            // First kept moment at or after the chapter's start.
            let kept = map.segments
                .filter { $0.end > chapter.start }
                .map { max($0.start, chapter.start) }
                .min()
            guard let begins = kept, begins < end else { continue }
            var out = chapter
            out.start = map.composition(fromSource: begins)
            result.append(out)
        }
        return result
    }

    /// The chapter being played at `time` (source seconds).
    public func chapter(at time: Double) -> NoteChapter? {
        chapters.sorted { $0.start < $1.start }.last { $0.start <= time }
    }
}

// MARK: - Export formats

public enum NotesFormat {
    /// `1:02:03` or `2:03`.
    public static func stamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// One line per chapter, `0:00 Title`, the form video sites turn into
    /// clickable chapters when pasted into a description.
    public static func chapterList(_ chapters: [NoteChapter]) -> String {
        chapters.map { "\(stamp($0.start)) \($0.title)" }.joined(separator: "\n")
    }

    /// The notes as a Markdown document. `chapters` lets the caller pass the
    /// chapters re-timed to the edited video.
    public static func markdown(_ notes: MeetingNotes, chapters: [NoteChapter]? = nil) -> String {
        var parts = ["# \(notes.title)"]
        if !notes.summary.isEmpty { parts.append(notes.summary) }
        func list(_ heading: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            parts.append("## \(heading)\n\n" + lines.map { "- \($0)" }.joined(separator: "\n"))
        }
        list("Key points", notes.keyPoints)
        list("Decisions", notes.decisions)
        if !notes.actionItems.isEmpty {
            let lines = notes.actionItems.map { item -> String in
                if let owner = item.owner, !owner.isEmpty { return "- [ ] \(item.text) (\(owner))" }
                return "- [ ] \(item.text)"
            }
            parts.append("## Action items\n\n" + lines.joined(separator: "\n"))
        }
        let shown = chapters ?? notes.chapters
        if !shown.isEmpty {
            parts.append("## Chapters\n\n" + shown.map { "- \(stamp($0.start)) \($0.title)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}
