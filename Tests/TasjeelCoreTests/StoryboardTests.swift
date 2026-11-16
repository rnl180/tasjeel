import AVFoundation
import Foundation
import XCTest
@testable import TasjeelCore

/// Storyboards: checking them, completing them, and building a project.
/// (That the project renders is checked with Remotion itself, outside the
/// test suite; see the README.)
final class StoryboardTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tasjeel-storyboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func plan(_ json: String) throws -> Storyboard.Plan {
        try Storyboard.plan(from: Data(json.utf8), baseDirectory: directory)
    }

    private func problems(_ json: String) -> [String] {
        do {
            _ = try plan(json)
            return []
        } catch StoryboardError.invalid(let list) {
            return list
        } catch {
            return ["\(error)"]
        }
    }

    // MARK: - Checking

    func testSmallestStoryboardGetsItsDefaults() throws {
        let plan = try plan(#"{"scenes":[{"type":"hook","text":"Hello"}]}"#)
        let board = plan.storyboard
        XCTAssertEqual(board["title"] as? String, "Untitled video")
        XCTAssertEqual(board["fps"] as? Int, 30)
        XCTAssertEqual(board["formats"] as? [String], ["wide", "square", "tall"])
        XCTAssertEqual(board["rightToLeft"] as? Bool, false)
        let brand = try XCTUnwrap(board["brand"] as? [String: Any])
        XCTAssertEqual(brand["accent"] as? String, "#8F7CFF")
        XCTAssertTrue(brand["logo"] is NSNull)
        let scene = try XCTUnwrap((board["scenes"] as? [[String: Any]])?.first)
        XCTAssertEqual(scene["seconds"] as? Double, 3, "a hook lasts three seconds unless told otherwise")
        XCTAssertTrue(scene["kicker"] is NSNull, "absent text is null, so the video code can test for it")
        XCTAssertEqual(plan.duration, 3)
        // What is written for the video code must be valid JSON.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: board))
    }

    func testEveryProblemIsReportedAtOnce() {
        let list = problems("""
        {"titel": "Typo", "fps": 29, "formats": ["wide", "round"],
         "brand": {"accent": "purple"},
         "scenes": [
           {"type": "hook"},
           {"type": "screen", "video": "missing.mp4"},
           {"type": "feature", "headline": 7, "image": "notes.txt"},
           {"type": "numbers", "items": []},
           {"type": "slideshow"},
           {"type": "cta", "text": "Go", "seconds": 90},
           {"type": "numbers", "items": [{"value": "many"}]}
         ]}
        """)
        func has(_ fragment: String) -> Bool { list.contains { $0.contains(fragment) } }
        XCTAssertTrue(has("\"titel\" is not a field Tasjeel knows"), "misspelt fields are caught")
        XCTAssertTrue(has("\"fps\" must be 24, 25, 30, 50 or 60"))
        XCTAssertTrue(has("\"round\" is not a size"))
        XCTAssertTrue(has("The brand: \"accent\" should be a colour like #8F7CFF"))
        XCTAssertTrue(has("Scene 1 (hook): \"text\" is missing"))
        XCTAssertTrue(has("Scene 2 (screen): the file \"missing.mp4\" was not found"))
        XCTAssertTrue(has("Scene 3 (feature): \"headline\" should be text in quotes"))
        XCTAssertTrue(has("Scene 3 (feature): \"notes.txt\" is not a picture"))
        XCTAssertTrue(has("Scene 4 (numbers): \"items\" needs one to three figures"))
        XCTAssertTrue(has("Scene 5: \"slideshow\" is not a kind of scene"))
        XCTAssertTrue(has("Scene 6 (cta): \"seconds\" should be between 1 and 30"))
        XCTAssertTrue(has("Scene 7 (numbers), figure 1: \"value\" should be a number"))
        XCTAssertEqual(list.count, 12, "one line per problem, none repeated: \(list)")
    }

    func testNotJSONAndNoScenes() {
        XCTAssertThrowsError(try plan("scenes: none")) { error in
            guard case StoryboardError.unreadable = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(problems(#"{"title":"Empty"}"#), ["The storyboard needs at least one scene in \"scenes\"."])
        XCTAssertTrue(problems(#"{"version": 9, "scenes":[{"type":"hook","text":"x"}]}"#).first?.contains("newer than this Tasjeel") ?? false)
    }

    func testDetailsAreKept() throws {
        try Data("<svg/>".utf8).write(to: directory.appendingPathComponent("Logo.SVG"))
        let plan = try plan("""
        {"language": "ar", "formats": ["tall", "wide"], "fps": 60,
         "brand": {"logo": "Logo.SVG", "accent": "#22b8a6", "font": "Cairo"},
         "scenes": [
           {"type": "numbers", "items": [{"value": 99.5, "suffix": " %", "prefix": "~"}]},
           {"type": "feature", "headline": "  Sharp  ", "points": ["one", " ", "two"], "image": "Logo.SVG"}
         ]}
        """)
        let board = plan.storyboard
        XCTAssertEqual(board["rightToLeft"] as? Bool, true, "Arabic is laid out right to left")
        XCTAssertEqual(board["formats"] as? [String], ["wide", "tall"], "sizes come out in a fixed order")
        XCTAssertEqual(board["fps"] as? Int, 60)
        let brand = try XCTUnwrap(board["brand"] as? [String: Any])
        XCTAssertEqual(brand["accent"] as? String, "#22B8A6")
        XCTAssertEqual(brand["logo"] as? String, "media/logo.svg")
        let scenes = try XCTUnwrap(board["scenes"] as? [[String: Any]])
        let figure = try XCTUnwrap((scenes[0]["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(figure["suffix"] as? String, " %", "the space before a unit is kept")
        XCTAssertEqual(figure["value"] as? Double, 99.5)
        XCTAssertEqual(scenes[1]["headline"] as? String, "Sharp")
        XCTAssertEqual(scenes[1]["points"] as? [String], ["one", "two"], "blank points are dropped")
        XCTAssertEqual(scenes[1]["image"] as? String, "media/scene-2.svg")
        XCTAssertEqual(plan.copies.map(\.path), ["media/logo.svg", "media/scene-2.svg"])
    }

    /// The example in the repository is what the README points people at.
    func testTheExampleStoryboardIsValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Examples/studio")
        let data = try Data(contentsOf: folder.appendingPathComponent("storyboard.json"))
        let plan = try Storyboard.plan(from: data, baseDirectory: folder)
        let types = (plan.storyboard["scenes"] as? [[String: Any]])?.compactMap { $0["type"] as? String }
        XCTAssertEqual((types ?? []).sorted(), Storyboard.sceneTypes.sorted(), "it shows one of every kind of scene")
        XCTAssertEqual(plan.clips.count, 1)
    }

    // MARK: - Building

    func testBuildTrimsClipsAndRebuildKeepsCode() async throws {
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try await makeMovie(at: source.appendingPathComponent("clip.mov"), seconds: 4)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: source.appendingPathComponent("shot.svg"))
        let storyboard = source.appendingPathComponent("storyboard.json")
        try Data("""
        {"title": "Launch", "scenes": [
          {"type": "screen", "video": "clip.mov", "start": 1, "seconds": 2, "caption": "Look"},
          {"type": "feature", "headline": "Sharp", "image": "shot.svg"}
        ]}
        """.utf8).write(to: storyboard)

        let project = directory.appendingPathComponent("project")
        let summary = try await StudioProject.build(storyboard: storyboard, in: project)
        XCTAssertTrue(summary.created)
        XCTAssertEqual(summary.scenes, 2)
        XCTAssertEqual(summary.seconds, 7)
        for path in ["package.json", "Start.command", "scripts/render.mjs", "src/Video.tsx", "src/scenes/Hook.tsx",
                     "src/storyboard.json", "public/media/scene-1.mp4", "public/media/scene-2.svg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent(path).path), "\(path) is written")
        }

        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent("src/storyboard.json"))) as? [String: Any])
        let scene = try XCTUnwrap((written["scenes"] as? [[String: Any]])?.first)
        XCTAssertEqual(scene["video"] as? String, "media/scene-1.mp4")
        XCTAssertEqual(scene["videoWidth"] as? Int, 320, "the clip's real shape, so the scene can frame it")
        XCTAssertEqual(scene["videoHeight"] as? Int, 200)
        XCTAssertNil(scene["start"], "the clip is already trimmed, so no start time is passed on")

        let clip = AVURLAsset(url: project.appendingPathComponent("public/media/scene-1.mp4"))
        let length = try await clip.load(.duration).seconds
        XCTAssertEqual(length, 2.25, accuracy: 0.2, "only the part the scene uses is kept")
        let track = try await clip.loadTracks(withMediaType: .video)[0]
        let format = try await track.load(.formatDescriptions)[0]
        XCTAssertEqual(format.mediaSubType, .h264, "Remotion's video component does not play HEVC")

        // Change the code, change the storyboard, build again.
        let hook = project.appendingPathComponent("src/scenes/Hook.tsx")
        try "// restyled".write(to: hook, atomically: true, encoding: .utf8)
        try Data(#"{"title": "Launch", "scenes": [{"type": "hook", "text": "New words"}]}"#.utf8).write(to: storyboard)
        let again = try await StudioProject.build(storyboard: storyboard, in: project)
        XCTAssertFalse(again.created)
        XCTAssertEqual(try String(contentsOf: hook, encoding: .utf8), "// restyled", "code changes survive a rebuild")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("public/media/scene-1.mp4").path),
                       "media that is no longer used is removed")
    }

    func testAClipThatIsTooShortIsCaughtBeforeAnythingIsWritten() async throws {
        try await makeMovie(at: directory.appendingPathComponent("clip.mov"), seconds: 2)
        let storyboard = directory.appendingPathComponent("storyboard.json")
        try Data(#"{"scenes": [{"type": "screen", "video": "clip.mov", "start": 1, "seconds": 5}]}"#.utf8).write(to: storyboard)
        let project = directory.appendingPathComponent("project")
        do {
            _ = try await StudioProject.build(storyboard: storyboard, in: project)
            XCTFail("expected an error")
        } catch StoryboardError.invalid(let list) {
            XCTAssertEqual(list.count, 1)
            XCTAssertTrue(list[0].contains("is only 2 s long"), list[0])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path), "no half-built folder is left behind")
    }

    func testAFolderWithOtherThingsInItIsRefused() async throws {
        let storyboard = directory.appendingPathComponent("storyboard.json")
        try Data(#"{"scenes": [{"type": "hook", "text": "Hi"}]}"#.utf8).write(to: storyboard)
        do {
            // The storyboard's own folder is not empty and not a project.
            _ = try await StudioProject.build(storyboard: storyboard, in: directory)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("is not a Tasjeel storyboard project"), error.localizedDescription)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["storyboard.json"])
    }

    // MARK: - Helpers

    /// A small solid-colour movie, 320 x 200.
    private func makeMovie(at url: URL, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< Int(seconds * 30) {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 120, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
