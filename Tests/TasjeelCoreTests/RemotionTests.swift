import Foundation
import XCTest
@testable import TasjeelCore

/// The Remotion export: what goes into the project folder and its data file.
/// (Whether the project runs is checked with Remotion itself, outside the
/// test suite; see the README.)
final class RemotionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tasjeel-remotion-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDataDescribesTheEditedVideo() throws {
        let transcript = Transcript(language: "ar-SA", segments: [
            TranscriptSegment(start: 2, end: 6, text: "مرحبا بالجميع", speaker: .mic),
            TranscriptSegment(start: 60, end: 64, text: "cut away", speaker: .system),
            TranscriptSegment(start: 130, end: 134, text: "شكرا", speaker: .system),
        ])
        let notes = MeetingNotes(title: "T", summary: "S", keyPoints: ["K"], decisions: [],
                                 actionItems: [ActionItem(text: "Do it", owner: "You"), ActionItem(text: "And this")],
                                 chapters: [NoteChapter(start: 0, title: "Intro"), NoteChapter(start: 125, title: "End")],
                                 engine: "x", language: "ar-SA")
        // Keep 0-50 and 120-300, so the edited video is 230 s long.
        let map = TimeMap(segments: [TimeSpan(start: 0, end: 50), TimeSpan(start: 120, end: 300)])
        let data = try RemotionProject.data(title: "عرض", size: CGSize(width: 1920, height: 1242), fps: 30, duration: 230,
                                            timeMap: map, transcript: transcript, notes: notes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "عرض")
        XCTAssertEqual(object["rightToLeft"] as? Bool, true)
        XCTAssertEqual(object["width"] as? Int, 1920)
        XCTAssertEqual(object["durationInSeconds"] as? Double, 230)
        XCTAssertEqual(object["video"] as? String, "recording.mp4")

        let captions = try XCTUnwrap(object["captions"] as? [[String: Any]])
        XCTAssertEqual(captions.map { $0["text"] as? String }, ["مرحبا بالجميع", "شكرا"], "the cut line is left out")
        XCTAssertEqual(captions.map { $0["start"] as? Double }, [2, 60], "times are on the edited video's clock")
        XCTAssertEqual(captions.map { $0["speaker"] as? String }, ["You", "Others"])

        let chapters = try XCTUnwrap(object["chapters"] as? [[String: Any]])
        XCTAssertEqual(chapters.map { $0["start"] as? Double }, [0, 55])
        let actions = try XCTUnwrap((object["notes"] as? [String: Any])?["actionItems"] as? [[String: Any]])
        XCTAssertEqual(actions[0]["owner"] as? String, "You")
        XCTAssertTrue(actions[1]["owner"] is NSNull, "no owner is null, not a missing key")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("مرحبا"), "Arabic is written as itself, not as escapes")
    }

    func testDataWithoutTranscriptOrNotes() throws {
        let data = try RemotionProject.data(title: "Plain", size: CGSize(width: 1280, height: 800), fps: 60, duration: 12.3456,
                                            timeMap: TimeMap(segments: [TimeSpan(start: 0, end: 12.3456)]), transcript: nil, notes: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["captions"] as? [Any])?.count, 0)
        XCTAssertEqual((object["chapters"] as? [Any])?.count, 0)
        XCTAssertTrue(object["notes"] is NSNull)
        XCTAssertEqual(object["durationInSeconds"] as? Double, 12.346)
        XCTAssertEqual(object["fps"] as? Int, 60)
    }

    func testProjectIsWrittenAndReExportKeepsYourChanges() throws {
        let first = Data(#"{"title":"one"}"#.utf8)
        XCTAssertTrue(try RemotionProject.write(to: directory, title: "Weekly Sync: Q4 / Plans!", data: first), "a new project")

        func text(_ path: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
        }
        for path in ["package.json", "tsconfig.json", ".gitignore", "AGENTS.md", "CLAUDE.md", "README.md", "Start.command",
                     "Render.command", "src/index.ts", "src/Root.tsx", "src/Video.tsx", "src/settings.ts", "src/types.ts",
                     "src/components/Captions.tsx", "src/recording.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path), "\(path) is written")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("gitignore").path))

        let package = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try text("package.json").utf8)) as? [String: Any])
        XCTAssertEqual(package["name"] as? String, "weekly-sync-q4-plans")
        let dependencies = try XCTUnwrap(package["dependencies"] as? [String: String])
        XCTAssertEqual(dependencies["remotion"], dependencies["@remotion/cli"], "Remotion packages must share one version")
        XCTAssertEqual(dependencies["remotion"], dependencies["@remotion/media"])
        XCTAssertTrue(try text("README.md").hasPrefix("# Weekly Sync: Q4 / Plans!"))
        XCTAssertFalse(try text("README.md").contains("__TITLE__"))

        let start = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("Start.command").path)
        XCTAssertEqual((start[.posixPermissions] as? NSNumber)?.intValue, 0o755, "Start can be double-clicked")
        XCTAssertTrue(try text("Start.command").hasPrefix("#!/bin/bash"))

        // The user (or an AI agent) changes the code, then exports again.
        try "// my own captions".write(to: directory.appendingPathComponent("src/components/Captions.tsx"), atomically: true, encoding: .utf8)
        let second = Data(#"{"title":"two"}"#.utf8)
        XCTAssertFalse(try RemotionProject.write(to: directory, title: "Renamed", data: second), "an existing project is updated")
        XCTAssertEqual(try text("src/components/Captions.tsx"), "// my own captions", "code changes survive a re-export")
        XCTAssertEqual(try text("src/recording.json"), #"{"title":"two"}"#, "the data is refreshed")
        XCTAssertTrue(try text("README.md").hasPrefix("# Weekly Sync"))
    }

    func testAFolderThatIsNotAProjectIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(RemotionProject.canExport(to: directory), "an empty folder is fine")
        try "important".write(to: directory.appendingPathComponent("thesis.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(RemotionProject.canExport(to: directory))
        XCTAssertThrowsError(try RemotionProject.write(to: directory, title: "X", data: Data("{}".utf8)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["thesis.txt"], "nothing was added")
    }

    /// The order the app uses: make the folder, export the video into it,
    /// then write the code around it.
    func testVideoIsExportedBeforeTheCodeIsWritten() throws {
        try RemotionProject.prepare(directory)
        try Data("video".utf8).write(to: RemotionProject.videoURL(in: directory))
        XCTAssertTrue(try RemotionProject.write(to: directory, title: "X", data: Data("{}".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("src/Video.tsx").path))
        XCTAssertEqual(try Data(contentsOf: RemotionProject.videoURL(in: directory)), Data("video".utf8), "the video is untouched")
    }

    func testPackageNames() {
        XCTAssertEqual(RemotionProject.packageName(for: "Café Démo 2"), "cafe-demo-2")
        XCTAssertEqual(RemotionProject.packageName(for: "عرض المنتج"), "tasjeel-recording", "no Latin letters to build a name from")
        XCTAssertEqual(RemotionProject.packageName(for: "  --Hello--  "), "hello")
    }

    /// The Swift copies of the templates are generated from the folders in
    /// Templates. If this fails, run scripts/embed-remotion-template.py.
    func testEmbeddedTemplatesMatchTheTemplateFolders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (name, files) in [("remotion", RemotionTemplate.files), ("studio", RemotionTemplate.studioFiles)] {
            let folder = root.appendingPathComponent("Templates/\(name)")
            var onDisk: [String: String] = [:]
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                guard url.lastPathComponent != ".DS_Store" else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                onDisk[relative] = try String(contentsOf: url, encoding: .utf8)
            }
            let embedded = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.text) })
            XCTAssertEqual(Set(embedded.keys), Set(onDisk.keys), name)
            for (path, text) in onDisk {
                XCTAssertEqual(embedded[path], text, "\(name)/\(path) differs: run scripts/embed-remotion-template.py")
            }
        }
    }
}
