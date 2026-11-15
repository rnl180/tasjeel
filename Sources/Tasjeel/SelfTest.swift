import AppKit
import AVFoundation
import Foundation
import TasjeelCore

/// Command-line entry points for development. Neither shows any UI.
enum SelfTest {
    /// `Tasjeel --import <video> [--camera <video>] [--title <text>] [--out <folder>]`
    ///
    /// Adds a video file to the library (or to `--out`) and prints its folder.
    static func importVideo() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--import") else {
            print("FAIL usage: --import <video>")
            exit(1)
        }
        Task {
            do {
                let store = ProjectStore(root: value("--out").map { URL(fileURLWithPath: $0) })
                let entry = try await store.importVideo(at: URL(fileURLWithPath: path),
                                                        camera: value("--camera").map { URL(fileURLWithPath: $0) },
                                                        title: value("--title"))
                print("OK folder=\(entry.directory.path)")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `Tasjeel --selftest-record [seconds] [--mic] [--out <folder>]`
    ///
    /// Records the main display for a few seconds, pauses once in the middle,
    /// and prints what ended up on disk. Used to check the capture pipeline
    /// from a terminal that has Screen Recording permission.
    static func record() {
        let args = CommandLine.arguments
        let seconds = args.dropFirst().compactMap { Double($0) }.first ?? 3
        let useMic = args.contains("--mic")
        var root: URL?
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count { root = URL(fileURLWithPath: args[i + 1]) }

        Task { @MainActor in
            do {
                let sources = try await CaptureSources.shareable()
                guard let display = sources.displays.first else {
                    print("FAIL no display")
                    exit(1)
                }
                let store = ProjectStore(root: root)
                let options = RecordingOptions(target: .display(display.display), sourceName: display.name,
                                               excluding: sources.ownApplication, systemAudio: true, microphone: useMic)
                let session = try RecordingSession(options: options, camera: nil, store: store)
                try await session.arm()
                try await Task.sleep(nanoseconds: 400_000_000)
                try session.begin()

                // Record, pause for a second, record again: the pause must not
                // appear in the file.
                try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1_000_000_000))
                session.pause()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                session.resume()
                try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1_000_000_000))

                let elapsed = session.elapsed
                let item = try await session.finish(title: "Self test")
                let r = item.recording
                print("OK folder=\(item.directory.path)")
                print("OK duration=\(String(format: "%.2f", r.duration)) elapsed=\(String(format: "%.2f", elapsed)) size=\(r.screen.width)x\(r.screen.height) audio=\(r.audioTracks.map(\.rawValue))")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription) (\(error))")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
