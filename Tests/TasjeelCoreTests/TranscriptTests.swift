import CoreImage
import XCTest
@testable import TasjeelCore

final class TranscriptTests: XCTestCase {
    private func words(_ text: String, from start: Double, each: Double = 0.3) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TimedWord(text: (index == 0 ? "" : " ") + word, start: start + Double(index) * each, end: start + Double(index + 1) * each)
        }
    }

    func testLinesBreakAtSentencesAndPauses() {
        var all = words("Good morning everyone and welcome.", from: 1)
        all += words("Second sentence is here.", from: 2.6)
        all += words("after a long pause", from: 10) // no full stop, but 6 s of silence before it
        let lines = TranscriptSegmenter.segments(from: all, speaker: .mic)
        XCTAssertEqual(lines.map(\.text), ["Good morning everyone and welcome.", "Second sentence is here.", "after a long pause"])
        XCTAssertEqual(lines[0].start, 1, accuracy: 1e-9)
        XCTAssertEqual(lines[2].start, 10, accuracy: 1e-9)
        XCTAssertTrue(lines.allSatisfy { $0.speaker == .mic && $0.end > $0.start })
    }

    func testUnpunctuatedSpeechStillBreaksIntoReadableLines() {
        // Dictation in some languages returns no punctuation at all.
        let long = Array(repeating: "كلمة", count: 60).joined(separator: " ")
        let lines = TranscriptSegmenter.segments(from: words(long, from: 0, each: 0.25), speaker: nil)
        XCTAssertGreaterThan(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.text.count <= 100 && $0.end - $0.start <= 8.5 })
        XCTAssertEqual(lines.map(\.text).joined(separator: " "), long, "no words lost")
    }

    func testStrandedWordsRejoinTheirLine() {
        // 7 s runs out one word before the sentence does.
        var all = words("so today we will go over the launch plan for the new product do you have any", from: 0, each: 0.4)
        all += words("questions", from: all.last!.end, each: 0.5)
        let lines = TranscriptSegmenter.segments(from: all, speaker: nil)
        XCTAssertEqual(lines.last?.text.hasSuffix("have any questions"), true)
        XCTAssertFalse(lines.contains { $0.text == "questions" })
    }

    func testFirstWordAfterSilenceIsPulledIn() {
        // The model reports "Yes," as lasting 1.5 s because it swallowed the silence.
        let tightened = TranscriptSegmenter.tightened([
            TimedWord(text: "Yes,", start: 15.0, end: 16.5),
            TimedWord(text: " I", start: 16.5, end: 16.92),
        ])
        XCTAssertEqual(tightened[0].end, 16.5)
        XCTAssertEqual(tightened[0].start, 15.89, accuracy: 0.01)
        XCTAssertEqual(tightened[1].start, 16.5, "normal words are untouched")
    }

    func testEchoOfTheCallIsDroppedFromTheMicrophone() {
        let system = [TranscriptSegment(start: 2, end: 6, text: "The onboarding flow shipped on Tuesday.", speaker: .system)]
        let mic = [
            // Speakers bleeding into the microphone: same words, same time.
            TranscriptSegment(start: 2.3, end: 6.2, text: "the onboarding flow shipped on Tuesday", speaker: .mic),
            // Really you, talking over them about something else.
            TranscriptSegment(start: 4, end: 5.5, text: "Sorry, one second please.", speaker: .mic),
            // You, later.
            TranscriptSegment(start: 9, end: 11, text: "The onboarding flow looks great.", speaker: .mic),
        ]
        let kept = TranscriptSegmenter.removingEcho(mic: mic, system: system)
        XCTAssertEqual(kept.map(\.text), ["Sorry, one second please.", "The onboarding flow looks great."])
    }

    func testCutsRemoveAndRetimeLines() {
        let transcript = Transcript(language: "en-US", segments: [
            TranscriptSegment(start: 1, end: 3, text: "kept at the start"),
            TranscriptSegment(start: 5, end: 7, text: "inside the cut"),
            TranscriptSegment(start: 11, end: 13, text: "kept after the cut"),
        ])
        // Keep 0-4 and 10-20: six seconds are removed in the middle.
        let edited = transcript.edited(with: TimeMap(segments: [TimeSpan(start: 0, end: 4), TimeSpan(start: 10, end: 20)]))
        XCTAssertEqual(edited.map(\.text), ["kept at the start", "kept after the cut"])
        XCTAssertEqual(edited[1].start, 5, accuracy: 1e-6)
        XCTAssertEqual(edited[1].end, 7, accuracy: 1e-3)
        XCTAssertEqual(transcript.segment(at: 6)?.text, "inside the cut")
        XCTAssertNil(transcript.segment(at: 8))
    }

    func testSubtitleAndTextFormats() {
        let lines = [
            TranscriptSegment(start: 0.5, end: 2.25, text: "Hello there.", speaker: .system),
            TranscriptSegment(start: 2.4, end: 4, text: "How are you?", speaker: .system),
            TranscriptSegment(start: 3725.04, end: 3727, text: "Fine, thanks.", speaker: .mic),
        ]
        XCTAssertEqual(TranscriptFormat.srt(lines), """
        1
        00:00:00,500 --> 00:00:02,250
        Hello there.

        2
        00:00:02,400 --> 00:00:04,000
        How are you?

        3
        01:02:05,040 --> 01:02:07,000
        Fine, thanks.

        """)
        XCTAssertEqual(TranscriptFormat.text(lines, speakers: true),
                       "[0:00] Others: Hello there. How are you?\n\n[1:02:05] You: Fine, thanks.\n")
        XCTAssertEqual(TranscriptFormat.text(Array(lines.prefix(1)), speakers: false), "[0:00] Hello there.\n")
    }

    func testCaptionIsDrawnNearTheBottomOnlyWhenGiven() throws {
        let renderer = FrameRenderer()
        let canvas = CGSize(width: 1280, height: 720)
        let screen = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(origin: .zero, size: canvas))
        let edit = EditState(duration: 10)

        func brightPixels(_ image: CIImage, in rect: CGRect) -> Int {
            let w = Int(rect.width), h = Int(rect.height)
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            renderer.context.render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: rect, format: .RGBA8,
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 200 && bytes[$0 + 1] > 200 && bytes[$0 + 2] > 200 }.count
        }

        // Bottom-centre band, where captions sit (Core Image y runs upwards).
        let band = CGRect(x: 240, y: 30, width: 800, height: 110)
        let top = CGRect(x: 240, y: 560, width: 800, height: 110)

        let plain = renderer.render(screen: screen, camera: nil, sourceTime: 0, canvas: canvas, screenSize: canvas, edit: edit)
        XCTAssertEqual(brightPixels(plain, in: band), 0)

        let captioned = renderer.render(screen: screen, camera: nil, sourceTime: 0, canvas: canvas, screenSize: canvas, edit: edit,
                                        caption: "Thanks for joining the weekly product sync.")
        XCTAssertGreaterThan(brightPixels(captioned, in: band), 400, "white caption text near the bottom")
        XCTAssertEqual(brightPixels(captioned, in: top), 0, "and nowhere else")

        // Arabic lays out right-to-left through the same path.
        let arabic = renderer.render(screen: screen, camera: nil, sourceTime: 0, canvas: canvas, screenSize: canvas, edit: edit,
                                     caption: "صباح الخير جميعا")
        XCTAssertGreaterThan(brightPixels(arabic, in: band), 200)
    }

    func testCaptionsFollowTheSwitchInTheEdit() throws {
        var edit = EditState(duration: 10)
        XCTAssertFalse(edit.captions)
        edit.captions = true
        let data = try JSONEncoder().encode(edit)
        XCTAssertTrue(try JSONDecoder().decode(EditState.self, from: data).captions)
        // Projects saved before captions existed still open, with captions off.
        let old = try JSONDecoder().decode(EditState.self, from: Data(#"{"segments":[{"start":0,"end":4}]}"#.utf8))
        XCTAssertFalse(old.captions)
    }
}
