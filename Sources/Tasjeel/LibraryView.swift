import AppKit
import SwiftUI
import TasjeelCore

/// The main window: recorder settings on the left, recordings on the right.
struct LibraryWindow: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            RecordPanel()
                .frame(width: 332)
                .background(Theme.panel)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            LibraryGrid()
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .alert("Tasjeel", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alert ?? "")
        }
        .task { await app.refreshSources() }
    }
}

// MARK: - Recorder settings

struct RecordPanel: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 46)
                .padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !app.hasScreenAccess { permissionCard }
                    sourceSection
                    inputsSection
                    optionsSection
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 12)
            recordButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x6B4CE6), Color(hex: 0xFF4A3D)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().strokeBorder(.white, lineWidth: 2.5).frame(width: 20, height: 20)
                Circle().fill(.white).frame(width: 9, height: 9)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tasjeel").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Text("Record, trim, share. All on this Mac.").font(.system(size: 11.5)).foregroundStyle(Theme.subtext)
            }
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allow screen recording", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.warn)
            Text("macOS asks once. Turn on Tasjeel under Screen & System Audio Recording, then reopen the app.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { app.requestScreenAccess() }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warn.opacity(0.3)))
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Record")
            Segmented(options: [(SourceKind.display, "Entire display"), (SourceKind.window, "One window")], selection: $app.sourceKind)
            VStack(spacing: 0) {
                if app.sourceKind == .display {
                    SettingRow(symbol: "display", title: "Display") {
                        Picker("Display", selection: $app.displayID) {
                            if app.displays.isEmpty { Text("Main display").tag(CGDirectDisplayID(0)) }
                            ForEach(app.displays) { display in
                                Text("\(display.name)  \(display.detail)").tag(display.id)
                            }
                        }
                    }
                } else {
                    SettingRow(symbol: "macwindow", title: "Window") {
                        Picker("Window", selection: $app.windowID) {
                            if app.windows.isEmpty { Text("No windows found").tag(CGWindowID(0)) }
                            ForEach(app.windows) { window in
                                Text(window.name).tag(window.id)
                            }
                        }
                    }
                }
            }
            .cardSurface()
        }
    }

    private var inputsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Include")
            VStack(spacing: 0) {
                SettingRow(symbol: "video", title: "Camera", active: !app.cameraID.isEmpty) {
                    Picker("Camera", selection: $app.cameraID) {
                        Text("Off").tag("")
                        ForEach(app.cameras) { Text($0.name).tag($0.id) }
                    }
                }
                RowDivider()
                SettingRow(symbol: "mic", title: "Microphone", active: !app.microphoneID.isEmpty) {
                    Picker("Microphone", selection: $app.microphoneID) {
                        Text("Off").tag("")
                        ForEach(app.microphones) { Text($0.name).tag($0.id) }
                    }
                }
                RowDivider()
                SettingRow(symbol: "speaker.wave.2", title: "Computer sound", active: app.systemAudio) {
                    Toggle("Computer sound", isOn: $app.systemAudio)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Theme.accent)
                }
            }
            .cardSurface()
            Text("Computer sound is what you hear: the other people in a call, videos, alerts.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Options")
            VStack(spacing: 0) {
                SettingRow(symbol: "speedometer", title: "Smoothness") {
                    Picker("Smoothness", selection: $app.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                }
                RowDivider()
                SettingRow(symbol: "timer", title: "3 second countdown") {
                    Toggle("Countdown", isOn: $app.countdown)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Theme.accent)
                }
            }
            .cardSurface()
        }
    }

    private var recordButton: some View {
        VStack(spacing: 9) {
            Button {
                app.toggleRecording()
            } label: {
                HStack(spacing: 9) {
                    if app.phase == .idle {
                        Circle().fill(.white).frame(width: 11, height: 11)
                        Text("Start Recording")
                    } else {
                        RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 11, height: 11)
                        Text(app.phase.isCapturing ? "Stop Recording" : "Cancel")
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle(color: Theme.record, large: true))
            .disabled(app.phase == .finishing)

            Text("⌥⇧R starts and stops from any app")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
        }
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 46)
    }
}

/// Icon, title and a control on the right.
private struct SettingRow<Control: View>: View {
    let symbol: String
    let title: String
    var active = true
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.text : Theme.faint)
                .frame(width: 26, height: 26)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            control()
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
    }
}

// MARK: - Library

struct LibraryGrid: View {
    @EnvironmentObject private var app: AppState
    @State private var search = ""
    @State private var renaming: LibraryEntry?
    @State private var newTitle = ""
    @State private var deleting: LibraryEntry?

    private var filtered: [LibraryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return app.items }
        return app.items.filter { $0.recording.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if app.items.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text("No recordings match “\(search)”.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.subtext)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 236, maximum: 340), spacing: 18)], spacing: 22) {
                        ForEach(filtered) { item in
                            RecordingCard(item: item, open: { app.open(item) }, rename: {
                                newTitle = item.recording.title
                                renaming = item
                            }, delete: { deleting = item })
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 28)
                    .padding(.top, 4)
                }
            }
        }
        .alert("Rename recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let item = renaming { app.rename(item, to: newTitle) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Move “\(deleting?.recording.title ?? "")” to the Trash?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let item = deleting { app.trash(item) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("You can put it back from the Trash.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text(app.items.isEmpty ? "Your recordings appear here" : "\(app.items.count) recording\(app.items.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.faint)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 150)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
            IconButton(symbol: "square.and.arrow.down", help: "Import a video file to edit") { app.importVideo() }
            IconButton(symbol: "folder", help: "Open the recordings folder") { app.revealLibraryFolder() }
        }
        .padding(.horizontal, 26)
        .padding(.top, 40)
        .padding(.bottom, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card).frame(width: 88, height: 88)
                Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.faint)
            }
            Text("No recordings yet").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Choose what to include on the left, then press Start Recording.\nWhen you stop, the recording opens here for trimming and export.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.subtext)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

struct RecordingCard: View {
    let item: LibraryEntry
    let open: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @State private var size: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: item.thumbnailURL)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(hovering ? Theme.accent : Theme.stroke, lineWidth: hovering ? 1.5 : 1)
                    )
                if hovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(.black.opacity(0.55), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(Format.clock(item.recording.edit.keptDuration > 0 ? item.recording.edit.keptDuration : item.recording.duration))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(8)
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.recording.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(Format.day(item.recording.createdAt))
                        if let size { Text("·"); Text(Format.bytes(size)) }
                        if item.recording.camera != nil { Image(systemName: "video.fill").font(.system(size: 9)) }
                        if item.recording.audioTracks.contains(.mic) { Image(systemName: "mic.fill").font(.system(size: 9)) }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.subtext)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .task(id: item.id) {
            let item = item
            size = await Task.detached { item.sizeOnDisk }.value
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(item.recording.title), \(Format.clock(item.recording.duration))")
    }

    @ViewBuilder private var menuItems: some View {
        Button("Open in Editor", action: open)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.screenURL]) }
        Button("Rename…", action: rename)
        Divider()
        Button("Move to Trash", role: .destructive, action: delete)
    }
}

/// Loads a thumbnail off the main thread and keeps it in memory.
struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            Theme.card
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.faint)
            }
        }
        .task(id: url) {
            if let hit = Self.cache.object(forKey: url as NSURL) {
                image = hit
                return
            }
            let url = url
            let loaded = await Task.detached { NSImage(contentsOf: url) }.value
            if let loaded { Self.cache.setObject(loaded, forKey: url as NSURL) }
            image = loaded
        }
    }
}
