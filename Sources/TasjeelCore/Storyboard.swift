import Foundation

/// A storyboard is a marketing video written down as data: a brand and a list
/// of scenes, each with its words, its picture or clip, and how long it
/// lasts. A person (or, later, an AI model) writes it as JSON; Tasjeel checks
/// it and builds a Remotion project from it.
///
///     {
///       "title": "Launch video",
///       "brand": { "logo": "logo.svg", "accent": "#8F7CFF" },
///       "scenes": [
///         { "type": "hook", "text": "Export in 4K. In one click." },
///         { "type": "screen", "video": "clip.mp4", "caption": "Pick a size, press Export." },
///         { "type": "cta", "text": "Try it today", "link": "example.com" }
///       ]
///     }
///
/// Files are named relative to the storyboard's own folder.
public enum StoryboardError: LocalizedError, Equatable {
    case unreadable(String)
    /// Everything wrong with the storyboard, one line each, so it can all be
    /// fixed in one go.
    case invalid([String])

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "The storyboard could not be read: \(reason)"
        case .invalid(let problems):
            return "The storyboard needs fixing:\n" + problems.map { "• \($0)" }.joined(separator: "\n")
        }
    }
}

public enum Storyboard {
    public static let version = 1
    public static let formats = ["wide", "square", "tall"]
    public static let sceneTypes = ["hook", "screen", "feature", "quote", "numbers", "cta"]
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "webp", "svg"]
    static let videoTypes: Set<String> = ["mp4", "mov", "m4v"]

    /// How long a scene lasts when the storyboard does not say.
    static let defaultSeconds: [String: Double] = ["hook": 3, "screen": 6, "feature": 5, "quote": 4.5, "numbers": 4.5, "cta": 3.5]

    /// A checked storyboard and the files it needs brought into the project.
    public struct Plan {
        /// The storyboard with every default filled in and every file path
        /// pointing inside the project. This is what the video code reads.
        public var storyboard: [String: Any]
        /// Pictures to copy as they are.
        public var copies: [(source: URL, path: String)]
        /// Clips to trim to the part a scene uses and re-encode.
        public var clips: [Clip]

        public struct Clip {
            /// Position of the scene in `storyboard["scenes"]`.
            public var scene: Int
            public var source: URL
            public var start: Double
            public var seconds: Double
            public var path: String
        }

        public var sceneCount: Int { (storyboard["scenes"] as? [Any])?.count ?? 0 }

        public var duration: Double {
            ((storyboard["scenes"] as? [[String: Any]]) ?? []).reduce(0) { $0 + (($1["seconds"] as? NSNumber)?.doubleValue ?? 0) }
        }
    }

    /// Checks a storyboard and fills in its defaults. Throws
    /// `StoryboardError.invalid` listing every problem found.
    public static func plan(from data: Data, baseDirectory: URL) throws -> Plan {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StoryboardError.unreadable("it is not valid JSON (\((error as NSError).localizedDescription))")
        }
        guard let object = parsed as? [String: Any] else {
            throw StoryboardError.unreadable("it should be a JSON object with a \"scenes\" list")
        }

        let problems = Problems()
        var copies: [(source: URL, path: String)] = []
        var clips: [Plan.Clip] = []

        var top = Fields(object, at: "The storyboard", problems)
        if let version = top.number("version", range: 1 ... 1000), Int(version) > Self.version {
            problems.add("The storyboard is version \(Int(version)), which is newer than this Tasjeel understands (version \(Self.version)).")
        }
        let title = top.string("title") ?? "Untitled video"
        let language = top.string("language") ?? "en"
        let fps = top.number("fps", range: 1 ... 120) ?? 30
        if ![24, 25, 30, 50, 60].contains(fps) { problems.add("The storyboard: \"fps\" must be 24, 25, 30, 50 or 60.") }

        let captions = top.bool("captions") ?? true

        var formats = top.strings("formats", limit: 3) ?? Self.formats
        for format in formats where !Self.formats.contains(format) {
            problems.add("The storyboard: \"\(format)\" is not a size. Use \"wide\", \"square\" or \"tall\".")
        }
        formats = Self.formats.filter(formats.contains)
        if formats.isEmpty { formats = Self.formats }

        // Brand
        var brand: [String: Any] = ["name": NSNull(), "logo": NSNull(), "font": NSNull(),
                                    "background": "#0C0D11", "text": "#FFFFFF", "accent": "#8F7CFF"]
        if let raw = top.object("brand") {
            var fields = Fields(raw, at: "The brand", problems)
            if let name = fields.string("name") { brand["name"] = name }
            if let font = fields.string("font") { brand["font"] = font }
            for key in ["background", "text", "accent"] {
                if let color = fields.color(key) { brand[key] = color }
            }
            if let logo = fields.file("logo", types: imageTypes, kind: "a picture", in: baseDirectory) {
                let path = "media/logo.\(logo.pathExtension.lowercased())"
                copies.append((logo, path))
                brand["logo"] = path
            }
            fields.finish()
        }

        // Scenes
        var scenes: [[String: Any]] = []
        let rawScenes = top.objects("scenes") ?? []
        if rawScenes.isEmpty { problems.add("The storyboard needs at least one scene in \"scenes\".") }
        if rawScenes.count > 40 { problems.add("The storyboard has \(rawScenes.count) scenes; the most is 40.") }

        for (index, raw) in rawScenes.enumerated() {
            let number = index + 1
            var fields = Fields(raw, at: "Scene \(number)", problems)
            guard let type = fields.string("type", required: true) else { continue }
            guard sceneTypes.contains(type) else {
                problems.add("Scene \(number): \"\(type)\" is not a kind of scene. Use one of: \(sceneTypes.joined(separator: ", ")).")
                continue
            }
            fields.place = "Scene \(number) (\(type))"
            let seconds = fields.number("seconds", range: 1 ... 30) ?? defaultSeconds[type] ?? 4
            var scene: [String: Any] = ["type": type, "seconds": seconds]
            // What the narrator says. The voice, its length and the timing of
            // its words are filled in when the project is built with a voiceover.
            scene["say"] = fields.string("say", limit: 400) ?? NSNull()
            scene["voice"] = NSNull()
            scene["voiceSeconds"] = 0
            scene["words"] = [[String: Any]]()

            switch type {
            case "hook":
                scene["text"] = fields.string("text", required: true, limit: 140) ?? ""
                scene["kicker"] = fields.string("kicker", limit: 60) ?? NSNull()
            case "screen":
                let start = fields.number("start", range: 0 ... 36000) ?? 0
                scene["caption"] = fields.string("caption", limit: 140) ?? NSNull()
                scene["sound"] = fields.bool("sound") ?? false
                if let video = fields.file("video", required: true, types: videoTypes, kind: "a video", in: baseDirectory) {
                    let path = "media/scene-\(number).mp4"
                    clips.append(Plan.Clip(scene: scenes.count, source: video, start: start, seconds: seconds, path: path))
                    scene["video"] = path
                }
                // Filled in from the clip itself when the project is built.
                scene["videoWidth"] = 16
                scene["videoHeight"] = 9
            case "feature":
                scene["headline"] = fields.string("headline", required: true, limit: 100) ?? ""
                scene["points"] = fields.strings("points", limit: 4, each: 110) ?? []
                scene["image"] = NSNull()
                if let image = fields.file("image", types: imageTypes, kind: "a picture", in: baseDirectory) {
                    let path = "media/scene-\(number).\(image.pathExtension.lowercased())"
                    copies.append((image, path))
                    scene["image"] = path
                }
            case "quote":
                scene["quote"] = fields.string("quote", required: true, limit: 260) ?? ""
                scene["name"] = fields.string("name", limit: 60) ?? NSNull()
                scene["role"] = fields.string("role", limit: 80) ?? NSNull()
            case "numbers":
                scene["headline"] = fields.string("headline", limit: 100) ?? NSNull()
                let rawItems = fields.objects("items") ?? []
                if rawItems.isEmpty || rawItems.count > 3 {
                    problems.add("\(fields.place): \"items\" needs one to three figures.")
                }
                scene["items"] = rawItems.prefix(3).enumerated().map { offset, rawItem -> [String: Any] in
                    var item = Fields(rawItem, at: "\(fields.place), figure \(offset + 1)", problems)
                    let value = item.number("value", required: true, range: -1_000_000_000 ... 1_000_000_000) ?? 0
                    let result: [String: Any] = [
                        "value": value,
                        "prefix": item.string("prefix", limit: 6, trimmed: false) ?? "",
                        "suffix": item.string("suffix", limit: 8, trimmed: false) ?? "",
                        "label": item.string("label", limit: 40) ?? "",
                    ]
                    item.finish()
                    return result
                }
            default: // cta
                scene["text"] = fields.string("text", required: true, limit: 100) ?? ""
                scene["link"] = fields.string("link", limit: 80) ?? NSNull()
            }
            fields.finish()
            scenes.append(scene)
        }
        top.finish()

        guard problems.list.isEmpty else { throw StoryboardError.invalid(problems.list) }
        let storyboard: [String: Any] = [
            "version": Self.version,
            "title": title,
            "language": language,
            "rightToLeft": Locale.Language(identifier: language).characterDirection == .rightToLeft,
            "fps": Int(fps),
            "formats": formats,
            "captions": captions,
            "voiceLeadIn": Narration.leadIn,
            "brand": brand,
            "scenes": scenes,
        ]
        return Plan(storyboard: storyboard, copies: copies, clips: clips)
    }
}

// MARK: - Looking at a storyboard

public extension Storyboard {
    /// A storyboard reduced to what a person wants to see of it: one line or
    /// two per scene, how long it is, and which picture or clip it shows.
    struct Outline: Equatable, Sendable {
        public struct Scene: Equatable, Identifiable, Sendable {
            /// Position in the storyboard, from 0.
            public var id: Int
            public var type: String
            /// "Opening line", "Recording", ...
            public var label: String
            public var text: String
            public var detail: String?
            public var seconds: Double
            /// The picture or clip the scene shows, and where in a clip it starts.
            public var media: URL?
            public var start: Double?
            /// What the narrator says during it.
            public var say: String?
        }

        public var title: String
        public var language: String
        public var rightToLeft: Bool
        public var formats: [String]
        public var seconds: Double
        public var background: String
        public var text: String
        public var accent: String
        public var logo: URL?
        public var scenes: [Scene]
    }

    static let sceneLabels = ["hook": "Opening line", "screen": "Recording", "feature": "Feature",
                              "quote": "Quote", "numbers": "Figures", "cta": "Call to action"]

    static func outline(of plan: Plan) -> Outline {
        let board = plan.storyboard
        let brand = board["brand"] as? [String: Any] ?? [:]
        let pictures = Dictionary(plan.copies.map { ($0.path, $0.source) }, uniquingKeysWith: { first, _ in first })
        let clips = Dictionary(plan.clips.map { ($0.scene, $0) }, uniquingKeysWith: { first, _ in first })
        let rawScenes = board["scenes"] as? [[String: Any]] ?? []

        let scenes = rawScenes.enumerated().map { index, scene -> Outline.Scene in
            let type = scene["type"] as? String ?? ""
            func text(_ key: String) -> String? { scene[key] as? String }
            var main = "", detail: String?, media: URL?, start: Double?
            switch type {
            case "hook":
                main = text("text") ?? ""
                detail = text("kicker")
            case "screen":
                main = text("caption") ?? "A piece of \(clips[index]?.source.lastPathComponent ?? "a recording")"
                media = clips[index]?.source
                start = clips[index]?.start
                if let clip = clips[index] { detail = "\(clip.source.lastPathComponent), from \(NotesFormat.stamp(clip.start))" }
            case "feature":
                main = text("headline") ?? ""
                let points = scene["points"] as? [String] ?? []
                detail = points.isEmpty ? nil : points.joined(separator: " · ")
                media = text("image").flatMap { pictures[$0] }
            case "quote":
                main = "“\(text("quote") ?? "")”"
                detail = [text("name"), text("role")].compactMap { $0 }.joined(separator: ", ")
            case "numbers":
                let items = scene["items"] as? [[String: Any]] ?? []
                main = items.map { item in
                    let value = (item["value"] as? NSNumber)?.doubleValue ?? 0
                    var number = value == value.rounded() ? String(Int(value)) : String(value)
                    if abs(value) >= 10000, value == value.rounded() {
                        let grouped = NumberFormatter()
                        grouped.locale = Locale(identifier: "en_US")
                        grouped.numberStyle = .decimal
                        number = grouped.string(from: NSNumber(value: Int(value))) ?? number
                    }
                    let figure = "\(item["prefix"] as? String ?? "")\(number)\(item["suffix"] as? String ?? "")"
                    let label = item["label"] as? String ?? ""
                    return label.isEmpty ? figure : "\(figure) \(label)"
                }.joined(separator: " · ")
                detail = text("headline")
            default:
                main = text("text") ?? ""
                detail = text("link")
            }
            if detail?.isEmpty == true { detail = nil }
            return Outline.Scene(id: index, type: type, label: sceneLabels[type] ?? type, text: main, detail: detail,
                                 seconds: (scene["seconds"] as? NSNumber)?.doubleValue ?? 0, media: media, start: start, say: text("say"))
        }
        return Outline(title: board["title"] as? String ?? "Untitled video", language: board["language"] as? String ?? "en",
                       rightToLeft: board["rightToLeft"] as? Bool ?? false, formats: board["formats"] as? [String] ?? formats,
                       seconds: plan.duration, background: brand["background"] as? String ?? "#0C0D11",
                       text: brand["text"] as? String ?? "#FFFFFF", accent: brand["accent"] as? String ?? "#8F7CFF",
                       logo: (brand["logo"] as? String).flatMap { pictures[$0] }, scenes: scenes)
    }

    /// A storyboard written out the way a person would: title first, each
    /// scene starting with its type, and the rest in a steady order.
    static func text(for storyboard: [String: Any]) -> String {
        let order = ["version", "title", "language", "formats", "fps", "captions", "brand", "scenes",
                     "type", "seconds", "say", "kicker", "text", "video", "start", "caption", "sound", "headline", "points", "image",
                     "quote", "name", "role", "items", "value", "prefix", "suffix", "label", "link",
                     "logo", "background", "accent", "font"]
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

        func leaf(_ value: Any) -> String {
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
        func write(_ value: Any, indent: String) -> String {
            let inner = indent + "  "
            if let object = value as? [String: Any] {
                if object.isEmpty { return "{}" }
                let keys = object.keys.sorted { (rank[$0] ?? order.count, $0) < (rank[$1] ?? order.count, $1) }
                // Small groups of plain values (a figure, a brand) read better on one line.
                let plain = object.values.allSatisfy { !($0 is [Any]) && !($0 is [String: Any]) }
                if plain, !indent.isEmpty {
                    let line = "{ " + keys.map { "\(leaf($0)): \(leaf(object[$0]!))" }.joined(separator: ", ") + " }"
                    if line.count + indent.count <= 100 { return line }
                }
                return "{\n" + keys.map { "\(inner)\(leaf($0)): \(write(object[$0]!, indent: inner))" }.joined(separator: ",\n") + "\n\(indent)}"
            }
            if let list = value as? [Any] {
                if list.isEmpty { return "[]" }
                if list.allSatisfy({ $0 is String }), list.count <= 3, list.map({ ($0 as? String)?.count ?? 0 }).reduce(0, +) < 40 {
                    return "[" + list.map(leaf).joined(separator: ", ") + "]"
                }
                return "[\n" + list.map { inner + write($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
            }
            return leaf(value)
        }
        return write(storyboard, indent: "") + "\n"
    }
}

// MARK: - Reading fields

/// Collects problems as they are found, so the user sees all of them at once.
final class Problems {
    private(set) var list: [String] = []

    func add(_ problem: String) {
        if !list.contains(problem) { list.append(problem) }
    }
}

/// Reads one JSON object field by field, reporting anything missing, of the
/// wrong kind, out of range, or not recognised (usually a typing mistake).
struct Fields {
    private let object: [String: Any]
    var place: String
    private let problems: Problems
    private var seen: Set<String> = []

    init(_ object: [String: Any], at place: String, _ problems: Problems) {
        self.object = object
        self.place = place
        self.problems = problems
    }

    private mutating func value(_ key: String, required: Bool) -> Any? {
        seen.insert(key)
        guard let found = object[key], !(found is NSNull) else {
            if required { problems.add("\(place): \"\(key)\" is missing.") }
            return nil
        }
        return found
    }

    /// `trimmed: false` keeps spaces at the ends, which matter in " fps".
    mutating func string(_ key: String, required: Bool = false, limit: Int = 200, trimmed: Bool = true) -> String? {
        guard let found = value(key, required: required) else { return nil }
        guard let raw = found as? String else {
            problems.add("\(place): \"\(key)\" should be text in quotes.")
            return nil
        }
        let text = trimmed ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if required { problems.add("\(place): \"\(key)\" is empty.") }
            return nil
        }
        if text.count > limit {
            problems.add("\(place): \"\(key)\" is \(text.count) characters long; keep it under \(limit) so it fits on screen.")
        }
        return text
    }

    mutating func number(_ key: String, required: Bool = false, range: ClosedRange<Double>) -> Double? {
        guard let found = value(key, required: required) else { return nil }
        // JSON true and false also arrive as NSNumber; they are not numbers here.
        guard let number = found as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            problems.add("\(place): \"\(key)\" should be a number.")
            return nil
        }
        guard range.contains(number.doubleValue) else {
            problems.add("\(place): \"\(key)\" should be between \(Self.plain(range.lowerBound)) and \(Self.plain(range.upperBound)).")
            return nil
        }
        return number.doubleValue
    }

    mutating func bool(_ key: String) -> Bool? {
        guard let found = value(key, required: false) else { return nil }
        guard let number = found as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            problems.add("\(place): \"\(key)\" should be true or false.")
            return nil
        }
        return number.boolValue
    }

    mutating func strings(_ key: String, limit: Int, each: Int = 200) -> [String]? {
        guard let found = value(key, required: false) else { return nil }
        guard let list = found as? [Any], list.allSatisfy({ $0 is String }) else {
            problems.add("\(place): \"\(key)\" should be a list of text in quotes.")
            return nil
        }
        let texts = list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if texts.count > limit { problems.add("\(place): \"\(key)\" has \(texts.count) entries; the most is \(limit).") }
        for text in texts where text.count > each {
            problems.add("\(place): an entry in \"\(key)\" is \(text.count) characters long; keep it under \(each).")
        }
        return Array(texts.prefix(limit))
    }

    mutating func object(_ key: String) -> [String: Any]? {
        guard let found = value(key, required: false) else { return nil }
        guard let object = found as? [String: Any] else {
            problems.add("\(place): \"\(key)\" should be a group in curly brackets.")
            return nil
        }
        return object
    }

    mutating func objects(_ key: String) -> [[String: Any]]? {
        guard let found = value(key, required: false) else { return nil }
        guard let list = found as? [Any], list.allSatisfy({ $0 is [String: Any] }) else {
            problems.add("\(place): \"\(key)\" should be a list of groups in curly brackets.")
            return nil
        }
        return list.compactMap { $0 as? [String: Any] }
    }

    /// `#RRGGBB`, returned in upper case.
    mutating func color(_ key: String) -> String? {
        guard let text = string(key) else { return nil }
        let digits = text.dropFirst()
        guard text.hasPrefix("#"), digits.count == 6, digits.allSatisfy(\.isHexDigit) else {
            problems.add("\(place): \"\(key)\" should be a colour like #8F7CFF.")
            return nil
        }
        return text.uppercased()
    }

    /// A file that exists and is of an accepted type.
    mutating func file(_ key: String, required: Bool = false, types: Set<String>, kind: String, in base: URL) -> URL? {
        guard let name = string(key, required: required, limit: 1024) else { return nil }
        let expanded = (name as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
        guard types.contains(url.pathExtension.lowercased()) else {
            problems.add("\(place): \"\(name)\" is not \(kind) Tasjeel can use here. Use \(types.sorted().map { "." + $0 }.joined(separator: ", ")).")
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            problems.add("\(place): the file \"\(name)\" was not found. File names are relative to the storyboard's folder.")
            return nil
        }
        return url.standardizedFileURL
    }

    /// Reports fields that were never asked for: nearly always a misspelling.
    func finish() {
        for key in object.keys.sorted() where !seen.contains(key) {
            problems.add("\(place): \"\(key)\" is not a field Tasjeel knows. Check the spelling.")
        }
    }

    private static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
