import Foundation

/// Writes a recording out as a Remotion project: a folder of React code that
/// plays the exported video with captions, chapter cards and a title on top,
/// and that an AI coding agent (or a person) can restyle.
///
/// Tasjeel does the part it is good at (capture, cuts, zooms, the camera) and
/// hands Remotion one finished MP4 plus a JSON file describing it. Every time
/// in that file is on the exported video's clock.
public enum RemotionProject {
    /// The recording inside the project's `public` folder. H.264, because the
    /// video component Remotion recommends does not play HEVC.
    public static let videoPath = "public/recording.mp4"
    public static let dataPath = "src/recording.json"

    public static func videoURL(in directory: URL) -> URL { directory.appendingPathComponent(videoPath) }

    public enum ProjectError: LocalizedError {
        case notAProject(String)

        public var errorDescription: String? {
            switch self {
            case .notAProject(let name):
                return "“\(name)” already exists and is not a Tasjeel Remotion project. Choose a new name."
            }
        }
    }

    /// True when `directory` can be exported to: it does not exist yet, is
    /// empty, or already holds a project written by this exporter.
    public static func canExport(to directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue else { return false }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(dataPath).path) { return true }
        // Otherwise it must hold nothing but, at most, a video this exporter
        // put there a moment ago (the video is written before the code).
        func names(_ url: URL) -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).subtracting([".DS_Store"])
        }
        let video = videoURL(in: directory)
        return names(directory).isSubset(of: [video.deletingLastPathComponent().lastPathComponent])
            && names(video.deletingLastPathComponent()).isSubset(of: [video.lastPathComponent])
    }

    /// Creates the project's folders so the video can be exported into it.
    public static func prepare(_ directory: URL) throws {
        guard canExport(to: directory) else { throw ProjectError.notAProject(directory.lastPathComponent) }
        try FileManager.default.createDirectory(at: videoURL(in: directory).deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Writes the code and the data. Returns true when the project is new.
    ///
    /// Code files that already exist are left alone, so exporting again
    /// refreshes the video and its data without undoing changes made to the
    /// project since; only `recording.json` is always rewritten.
    @discardableResult
    public static func write(to directory: URL, title: String, data: Data) throws -> Bool {
        try prepare(directory)
        let fresh = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path)
        for file in RemotionTemplate.files {
            // A file called .gitignore in this repository would apply to the
            // repository itself, so the template keeps it without the dot.
            let path = file.path == "gitignore" ? ".gitignore" : file.path
            let url = directory.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = file.text
                .replacingOccurrences(of: "__NAME__", with: packageName(for: title))
                .replacingOccurrences(of: "__TITLE__", with: title)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if path.hasSuffix(".command") {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        let dataURL = directory.appendingPathComponent(dataPath)
        try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dataURL, options: .atomic)
        return fresh
    }

    /// The contents of `src/recording.json`. `duration` is the exported
    /// video's length; captions and chapters are re-timed with `timeMap` so
    /// they match it after cuts.
    public static func data(title: String, size: CGSize, fps: Int, duration: Double, timeMap: TimeMap,
                            transcript: Transcript?, notes: MeetingNotes?) throws -> Data {
        func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        let language = transcript?.language ?? notes?.language ?? Locale.current.identifier(.bcp47)
        let captions: [[String: Any]] = (transcript?.edited(with: timeMap) ?? []).map { line in
            [
                "start": rounded(line.start),
                "end": rounded(min(line.end, duration)),
                "text": line.text,
                "speaker": TranscriptFormat.speakerName(line.speaker) as Any? ?? NSNull(),
            ]
        }
        let chapters: [[String: Any]] = (notes?.editedChapters(with: timeMap) ?? []).map {
            ["start": rounded($0.start), "title": $0.title]
        }
        var object: [String: Any] = [
            "title": title,
            "language": language,
            "rightToLeft": Locale.Language(identifier: language).characterDirection == .rightToLeft,
            "fps": fps,
            "width": Int(size.width),
            "height": Int(size.height),
            "durationInSeconds": rounded(duration),
            "video": URL(fileURLWithPath: videoPath).lastPathComponent,
            "captions": captions,
            "chapters": chapters,
            "notes": NSNull(),
        ]
        if let notes {
            object["notes"] = [
                "summary": notes.summary,
                "keyPoints": notes.keyPoints,
                "decisions": notes.decisions,
                "actionItems": notes.actionItems.map { ["text": $0.text, "owner": $0.owner as Any? ?? NSNull()] as [String: Any] },
            ] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// A name npm accepts: lower-case letters, digits and hyphens.
    static func packageName(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en")).lowercased()
        var name = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                name.unicodeScalars.append(scalar)
            } else if !name.hasSuffix("-"), !name.isEmpty {
                name += "-"
            }
        }
        name = String(name.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? "tasjeel-recording" : name
    }
}
