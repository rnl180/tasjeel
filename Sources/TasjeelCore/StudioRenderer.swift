import Darwin
import Foundation

/// Turns a built Studio project into a video file by running Remotion, the
/// same tool the project's Render script runs, without leaving the app.
///
/// Remotion needs Node.js, which Tasjeel looks for but does not install.
/// Remotion itself is downloaded once into the Studio folder and shared by
/// every project, so a second video does not download it again.
public enum StudioRenderer {
    public enum RenderError: LocalizedError, Equatable {
        case noNode
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noNode:
                return "Making the video needs Node.js, which was not found on this Mac. Install it from nodejs.org, then try again."
            case .failed(let reason):
                return reason
            }
        }
    }

    static let compositions = ["wide": "Wide", "square": "Square", "tall": "Tall"]

    // MARK: - Node.js

    public struct Node: Equatable, Sendable {
        /// The folder holding `node` and `npm`.
        public var directory: String
        /// The PATH given to everything Tasjeel runs.
        public var path: String
    }

    /// Finds Node.js. An app started from the Dock does not see the PATH a
    /// terminal has, so the usual install places are looked in directly.
    public static func findNode() -> Node? {
        findNode(in: searchFolders(home: FileManager.default.homeDirectoryForCurrentUser,
                                   environment: ProcessInfo.processInfo.environment))
    }

    /// Where Node.js might be, most likely first.
    static func searchFolders(home: URL, environment: [String: String]) -> [String] {
        var folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                    home.appendingPathComponent(".volta/bin").path,
                    home.appendingPathComponent(".local/bin").path,
                    home.appendingPathComponent(".asdf/shims").path,
                    home.appendingPathComponent(".nodenv/shims").path,
                    home.appendingPathComponent("Library/Application Support/fnm/aliases/default/bin").path,
                    home.appendingPathComponent(".local/share/fnm/aliases/default/bin").path]
        // nvm keeps one folder per version; take the newest.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        folders += versions.map { nvm.appendingPathComponent("\($0)/bin").path }
        return folders
    }

    static func findNode(in folders: [String]) -> Node? {
        let fm = FileManager.default
        for folder in folders where fm.isExecutableFile(atPath: folder + "/node") && fm.isExecutableFile(atPath: folder + "/npm") {
            let rest = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] + folders.filter { $0 != folder }
            var seen = Set<String>()
            let path = ([folder] + rest).filter { seen.insert($0).inserted }.joined(separator: ":")
            return Node(directory: folder, path: path)
        }
        return nil
    }

    // MARK: - The shared copy of Remotion

    /// The Remotion version the project template asks for, e.g. "4.0.544".
    static var remotionVersion: String {
        let package = RemotionTemplate.studioFiles.first { $0.path == "package.json" }?.text ?? ""
        let object = (try? JSONSerialization.jsonObject(with: Data(package.utf8))) as? [String: Any]
        return ((object?["dependencies"] as? [String: Any])?["remotion"] as? String) ?? "current"
    }

    /// Where the shared copy lives: a hidden folder beside the projects.
    public static func runtimeURL(in root: URL) -> URL {
        root.appendingPathComponent(".remotion-\(remotionVersion)", isDirectory: true)
    }

    private static func hasRemotion(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("node_modules/.bin/remotion").path)
    }

    /// True when making a video from `project` would first download Remotion.
    public static func needsDownload(project: URL, root: URL) -> Bool {
        !hasRemotion(project) && !hasRemotion(runtimeURL(in: root))
    }

    // MARK: - Rendering

    /// Renders one size of a built project and returns the video file.
    /// `progress` receives a fraction, when one is known, and a description.
    public static func render(project: URL, format: String, root: URL,
                              progress: @escaping @Sendable (Double?, String) -> Void) async throws -> URL {
        guard let composition = compositions[format] else { throw RenderError.failed("“\(format)” is not a size Tasjeel can render.") }
        guard let node = findNode() else { throw RenderError.noNode }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = node.path
        // Plain output, one line at a time, instead of a drawn progress bar.
        environment["CI"] = "1"
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"

        let fm = FileManager.default
        let modules = project.appendingPathComponent("node_modules")
        if !hasRemotion(project) {
            let runtime = runtimeURL(in: root)
            if !hasRemotion(runtime) {
                progress(nil, "Downloading Remotion (first time only, a few minutes)…")
                try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
                let package = (RemotionTemplate.studioFiles.first { $0.path == "package.json" }?.text ?? "{}")
                    .replacingOccurrences(of: "__NAME__", with: "tasjeel-studio-remotion")
                try package.write(to: runtime.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
                let log = Log()
                let status = try await Subprocess.run([node.directory + "/npm", "install", "--no-audit", "--no-fund"],
                                                      in: runtime, environment: environment) { log.add($0) }
                guard status == 0, hasRemotion(runtime) else {
                    throw RenderError.failed("Remotion could not be downloaded. Check your internet connection and try again.\n\(log.tail)")
                }
            }
            // A link left over from a moved project points nowhere.
            if (try? fm.destinationOfSymbolicLink(atPath: modules.path)) != nil { try? fm.removeItem(at: modules) }
            if !fm.fileExists(atPath: modules.path) {
                try fm.createSymbolicLink(at: modules, withDestinationURL: runtime.appendingPathComponent("node_modules"))
            }
        }

        let output = project.appendingPathComponent("out/\(format).mp4")
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written beside the real file, so a failed render leaves the last
        // good video in place.
        let partial = project.appendingPathComponent("out/.\(format)-rendering.mp4")
        try? fm.removeItem(at: partial)
        progress(0, "Preparing…")

        let log = Log()
        let furthest = Furthest()
        let status = try await Subprocess.run([modules.appendingPathComponent(".bin/remotion").path, "render", composition, partial.path],
                                              in: project, environment: environment) { line in
            log.add(line)
            // Lines can arrive out of order; the bar never goes backwards.
            guard let update = Self.progress(in: line), furthest.advance(to: update.fraction) else { return }
            progress(update.fraction, update.label)
        }
        guard status == 0, fm.fileExists(atPath: partial.path) else {
            try? fm.removeItem(at: partial)
            throw RenderError.failed("The video could not be rendered.\n\(log.tail)")
        }
        try? fm.removeItem(at: output)
        try fm.moveItem(at: partial, to: output)
        progress(1, "Done")
        return output
    }

    /// Reads Remotion's output for how far along it is.
    static func progress(in line: String) -> (fraction: Double?, label: String)? {
        let lower = line.lowercased()
        if lower.contains("chrome") && lower.contains("download") {
            return (nil, "Downloading the browser Remotion draws with (first time only)…")
        }
        if lower.contains("bundl") { return (0.02, "Preparing…") }

        // "Rendered 120/765", "Encoded 765/765"
        var fraction: Double?
        if let match = line.range(of: #"(\d+)\s*/\s*(\d+)"#, options: .regularExpression) {
            let numbers = line[match].split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if numbers.count == 2, numbers[1] > 0 { fraction = min(numbers[0] / numbers[1], 1) }
        }
        guard let fraction else { return nil }
        if lower.contains("encod") || lower.contains("stitch") { return (0.85 + fraction * 0.15, "Finishing…") }
        if lower.contains("render") { return (0.05 + fraction * 0.8, "Drawing the frames…") }
        return nil
    }

    /// How far a render has got, so a late line cannot move it back.
    private final class Furthest: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0

        /// False when `fraction` is behind what was already reported.
        func advance(to fraction: Double?) -> Bool {
            guard let fraction else { return true }
            return lock.withLock {
                guard fraction >= value else { return false }
                value = fraction
                return true
            }
        }
    }

    /// The last few lines a tool printed, for explaining a failure.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func add(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lock.withLock {
                lines.append(trimmed)
                if lines.count > 12 { lines.removeFirst() }
            }
        }

        var tail: String { lock.withLock { lines.suffix(6).joined(separator: "\n") } }
    }
}

/// Runs a command-line tool and reads what it prints, line by line.
///
/// The tool is started in its own process group, so cancelling stops it and
/// everything it started (npm starts node, which starts a browser).
enum Subprocess {
    static func run(_ command: [String], in directory: URL, environment: [String: String],
                    onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw StudioRenderer.RenderError.failed("This Mac could not start \(command[0]).") }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        // The tool starts with no signals blocked or ignored. Otherwise it
        // inherits whatever the calling thread had, and may never hear the
        // request to stop.
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let started = posix_spawn(&pid, command[0], &actions, &attributes, &argv, &envp)
        close(writeEnd)
        guard started == 0 else {
            close(readEnd)
            throw StudioRenderer.RenderError.failed("This Mac could not start \((command[0] as NSString).lastPathComponent).")
        }

        let child = pid
        return try await withTaskCancellationHandler {
            let status: Int32 = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    while true {
                        let count = read(readEnd, &buffer, buffer.count)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { break }
                        pending.append(buffer, count: count)
                        // Progress bars redraw with a carriage return, not a new line.
                        while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                            let line = String(decoding: pending[pending.startIndex ..< end], as: UTF8.self)
                            pending.removeSubrange(pending.startIndex ... end)
                            if !line.isEmpty { onLine(line) }
                        }
                    }
                    if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                    close(readEnd)
                    var raw: Int32 = 0
                    while waitpid(child, &raw, 0) < 0, errno == EINTR {}
                    // Exited normally: its exit code. Stopped by a signal: not zero.
                    let exited = (raw & 0x7F) == 0
                    continuation.resume(returning: exited ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F))
                }
            }
            try Task.checkCancellation()
            return status
        } onCancel: {
            kill(-child, SIGTERM)
        }
    }
}
