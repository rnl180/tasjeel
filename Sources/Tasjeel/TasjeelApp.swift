import AppKit
import Carbon.HIToolbox
import SwiftUI
import TasjeelCore

struct TasjeelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window("Tasjeel", id: "library") {
            LibraryWindow()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(app.phase.isActive ? "Stop Recording" : "New Recording") { app.toggleRecording() }
                    .keyboardShortcut("n")
                Button("Open Recordings Folder") { app.revealLibraryFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("New Video with AI…") { app.openStudio() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Video from Storyboard File…") { app.buildFromStoryboard() }
            }
        }

        MenuBarExtra {
            MenuBarMenu().environmentObject(app)
        } label: {
            MenuBarLabel(app: app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // ⌥⇧R starts and stops a recording from any app.
        hotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: optionKey | shiftKey) {
            MainActor.assumeIsolated { AppState.shared.toggleRecording() }
        }
        Task { @MainActor in
            await AppState.shared.refreshSources()
            DebugSnapshot.runIfRequested()
        }
    }

    /// Keep running in the menu bar when the library window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting mid-recording saves the recording first instead of losing it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let capturing = MainActor.assumeIsolated { AppState.shared.phase.isCapturing }
        guard capturing else { return .terminateNow }
        Task { @MainActor in
            await AppState.shared.finishBeforeQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @ObservedObject var app: AppState

    var body: some View {
        if app.phase.isCapturing {
            Label(Format.clock(app.elapsed), systemImage: app.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "record.circle")
        }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch app.phase {
        case .idle:
            Button("Start Recording") { app.startRecording() }
                .keyboardShortcut("r", modifiers: [.option, .shift])
        case .recording, .paused:
            Button("Stop Recording") { app.stopRecording() }
                .keyboardShortcut("r", modifiers: [.option, .shift])
            Button(app.phase == .paused ? "Resume" : "Pause") { app.togglePause() }
            Button("Discard Recording…") { app.confirmDiscard() }
        case .preparing, .countdown:
            Button("Cancel") { app.cancelRecording() }
        case .finishing:
            Text("Saving…")
        }
        Divider()
        Button("Open Library") {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Studio") { app.openStudio() }
        Button("Open Recordings Folder") { app.revealLibraryFolder() }
        Divider()
        Button("Quit Tasjeel") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
