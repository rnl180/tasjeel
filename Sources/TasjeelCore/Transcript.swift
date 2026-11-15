import Foundation

/// One line of a transcript. Times are in source (un-cut) seconds.
public struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    /// Which audio track the words came from: `.mic` is you, `.system` is
    /// everyone you heard. Nil when the recording has a single sound source.
    public var speaker: AudioTrackKind?

    public init(id: UUID = UUID(), start: Double, end: Double, text: String, speaker: AudioTrackKind? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    /// BCP 47 language tag, e.g. "en-US" or "ar-SA".
    public var language: String
    public var createdAt: Date
    public var segments: [TranscriptSegment]

    public init(language: String, createdAt: Date = Date(), segments: [TranscriptSegment]) {
        self.language = language
        self.createdAt = createdAt
        self.segments = segments
    }

    /// True when the transcript can tell your voice from the others'.
    public var hasSpeakers: Bool {
        let kinds = Set(segments.compactMap(\.speaker))
        return kinds.count > 1
    }

    /// The lines that survive the cuts, re-timed to the edited video.
    public func edited(with map: TimeMap) -> [TranscriptSegment] {
        segments.compactMap { segment in
            let middle = (segment.start + segment.end) / 2
            guard let span = map.segments.first(where: { $0.contains(middle) }) else { return nil }
            var out = segment
            out.start = map.composition(fromSource: max(segment.start, span.start))
            out.end = map.composition(fromSource: min(segment.end, span.end) - 0.0001)
            return out.end > out.start ? out : nil
        }
    }

    /// The line being spoken at `time` (source seconds).
    public func segment(at time: Double) -> TranscriptSegment? {
        segments.first { time >= $0.start && time < $0.end }
    }
}

// MARK: - Building segments

/// A word (or short run of text) with the moment it was spoken.
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    /// First word of a new recognition result; a space may be needed before it.
    public var startsResult: Bool

    public init(text: String, start: Double, end: Double, startsResult: Bool = false) {
        self.text = text
        self.start = start
        self.end = end
        self.startsResult = startsResult
    }
}

public enum TranscriptSegmenter {
    private static let sentenceEnds: Set<Character> = [".", "?", "!", "؟", "。", "！", "？", "…"]

    /// Groups words into caption-sized lines: break at the end of a sentence,
    /// at a pause, or when a line gets too long to read comfortably.
    public static func segments(from words: [TimedWord], speaker: AudioTrackKind?, maxLength: Int = 84,
                                maxDuration: Double = 7, pause: Double = 1.2) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var text = ""
        var start = 0.0
        var end = 0.0

        func flush() {
            let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !clean.isEmpty, end > start {
                result.append(TranscriptSegment(start: start, end: end, text: clean, speaker: speaker))
            }
            text = ""
        }

        for word in words where !word.text.isEmpty {
            let empty = text.allSatisfy(\.isWhitespace)
            if !empty, word.start - end > pause || word.end - start > maxDuration || text.count + word.text.count > maxLength {
                flush()
            }
            if text.allSatisfy(\.isWhitespace) {
                text = ""
                start = word.start
            } else if word.startsResult, let last = text.last, !last.isWhitespace, let first = word.text.first, !first.isWhitespace {
                text += " "
            }
            text += word.text
            end = max(end, word.end)
            if let last = word.text.last(where: { !$0.isWhitespace }), sentenceEnds.contains(last), text.count >= 24 {
                flush()
            }
        }
        flush()
        return absorbingFragments(result)
    }

    /// A length or duration limit can strand a word or two on a line of their
    /// own ("…do any of you have any" / "questions"). Fold such a fragment back
    /// into the line it continues.
    private static func absorbingFragments(_ lines: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for line in lines {
            if var previous = result.last,
               line.text.split(separator: " ").count <= 2,
               line.start - previous.end < 0.4,
               let tail = previous.text.last, !sentenceEnds.contains(tail) {
                previous.text += " " + line.text
                previous.end = line.end
                result[result.count - 1] = previous
            } else {
                result.append(line)
            }
        }
        return result
    }

    /// The speech models stretch the first word after a silence back over the
    /// silence itself ("Yes," lasting 1.5 s when speech began a second in).
    /// A word that lasts far longer than its length explains is pulled in so
    /// that it starts when the talking actually starts.
    public static func tightened(_ words: [TimedWord]) -> [TimedWord] {
        words.map { word in
            let letters = word.text.filter { !$0.isWhitespace }.count
            let expected = 0.25 + 0.09 * Double(letters)
            let actual = word.end - word.start
            guard actual > max(0.9, expected * 1.6) else { return word }
            var out = word
            out.start = word.end - expected
            return out
        }
    }

    /// Without headphones the microphone also hears the call coming out of the
    /// speakers, so the other side's words would appear twice. Drops microphone
    /// lines that say the same thing at the same time as a system-sound line.
    public static func removingEcho(mic: [TranscriptSegment], system: [TranscriptSegment]) -> [TranscriptSegment] {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let systemWords = system.map { ($0, words($0.text)) }
        return mic.filter { line in
            let mine = words(line.text)
            guard !mine.isEmpty else { return false }
            // Gather everything the other side said while this line was spoken.
            var heard = Set<String>()
            for (other, theirs) in systemWords where other.end > line.start - 1 && other.start < line.end + 1 {
                heard.formUnion(theirs)
            }
            guard !heard.isEmpty else { return true }
            let shared = Double(mine.intersection(heard).count) / Double(mine.count)
            return shared < 0.6
        }
    }
}

// MARK: - Export formats

public enum TranscriptFormat {
    public static func speakerName(_ kind: AudioTrackKind?) -> String? {
        switch kind {
        case .mic: return "You"
        case .system: return "Others"
        case nil: return nil
        }
    }

    /// `00:01:02,345`, the SubRip timestamp.
    public static func srtTime(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// Subtitles in SubRip format, which every player and video site reads.
    public static func srt(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(srtTime(segment.start)) --> \(srtTime(segment.end))\n\(segment.text)\n"
        }
        .joined(separator: "\n")
    }

    /// Readable notes: a timestamp, who spoke (when known), and what was said.
    /// Consecutive lines from the same speaker are joined into one paragraph.
    public static func text(_ segments: [TranscriptSegment], speakers: Bool) -> String {
        var paragraphs: [(start: Double, speaker: AudioTrackKind?, text: String, end: Double)] = []
        for segment in segments {
            if var last = paragraphs.last, last.speaker == segment.speaker, segment.start - last.end < 4, last.text.count < 600 {
                last.text += " " + segment.text
                last.end = segment.end
                paragraphs[paragraphs.count - 1] = last
            } else {
                paragraphs.append((segment.start, segment.speaker, segment.text, segment.end))
            }
        }
        return paragraphs.map { paragraph in
            let total = Int(paragraph.start)
            let stamp = total >= 3600
                ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60)
            if speakers, let name = speakerName(paragraph.speaker) {
                return "[\(stamp)] \(name): \(paragraph.text)"
            }
            return "[\(stamp)] \(paragraph.text)"
        }
        .joined(separator: "\n\n") + "\n"
    }
}
