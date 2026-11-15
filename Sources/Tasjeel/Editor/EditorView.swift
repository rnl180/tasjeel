import AppKit
import AVFoundation
import SwiftUI
import TasjeelCore

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(model: model)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PreviewArea(model: model)
                    TransportBar(model: model)
                }
                Rectangle().fill(Theme.stroke).frame(width: 1)
                Inspector(model: model)
                    .frame(width: 304)
                    .background(Theme.panel)
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            TimelinePanel(model: model)
                .frame(height: 208)
                .background(Theme.panel)
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .background(EditorShortcuts(model: model))
        .task { await model.load() }
    }
}

/// Keyboard shortcuts, as invisible buttons so they work wherever focus is.
private struct EditorShortcuts: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Group {
            Button("Play or Pause") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("Split") { model.split() }.keyboardShortcut("s", modifiers: [])
            Button("Delete") { model.deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
            Button("Trim Start") { model.trimStart() }.keyboardShortcut("[", modifiers: [])
            Button("Trim End") { model.trimEnd() }.keyboardShortcut("]", modifiers: [])
            Button("Add Zoom") { model.addZoom() }.keyboardShortcut("z", modifiers: [])
            Button("Back One Frame") { model.step(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward One Frame") { model.step(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Undo") { model.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Top bar

private struct EditorTopBar: View {
    @ObservedObject var model: EditorModel
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @State private var showingExport = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            title
            Spacer(minLength: 12)
            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { model.undo() }.disabled(!model.canUndo)
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { model.redo() }.disabled(!model.canRedo)
            IconButton(symbol: "folder", help: "Show the original files in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.directory.appendingPathComponent(model.recording.screen.file)])
            }
            exportControl
        }
        .padding(.leading, 84) // room for the window's close/minimise/zoom buttons
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(Theme.panel)
    }

    @ViewBuilder private var title: some View {
        if editingTitle {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .frame(width: 300, height: 28)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onExitCommand { editingTitle = false }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
        } else {
            Button {
                draftTitle = model.recording.title
                editingTitle = true
                titleFocused = true
            } label: {
                HStack(spacing: 8) {
                    Text(model.recording.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    Text(model.recording.sourceName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename")
        }
    }

    private func commitTitle() {
        guard editingTitle else { return }
        editingTitle = false
        model.rename(draftTitle)
    }

    @ViewBuilder private var exportControl: some View {
        if let progress = model.exportProgress {
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(width: 130)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.subtext)
                    .frame(width: 36, alignment: .trailing)
                Button("Cancel") { model.cancelExport() }.buttonStyle(QuietButtonStyle())
            }
        } else {
            Button {
                showingExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.isReady)
            .popover(isPresented: $showingExport, arrowEdge: .bottom) {
                ExportPanel(model: model, isPresented: $showingExport)
            }
        }
    }
}

// MARK: - Export settings

private struct ExportPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var isPresented: Bool
    @AppStorage("exportLongSide") private var longSide = 1920
    @AppStorage("exportFPS") private var fps = 30
    @AppStorage("exportCodec") private var codec = ExportCodec.h264.rawValue

    private var settings: ExportSettings {
        ExportSettings(longSide: longSide == 0 ? nil : longSide, fps: fps, codec: ExportCodec(rawValue: codec) ?? .h264)
    }

    private var outputSize: CGSize {
        CompositionBuilder.canvasSize(aspect: model.edit.aspect, source: model.screenSize, longSide: settings.longSide)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export video").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                row("Size") {
                    Picker("Size", selection: $longSide) {
                        Text("Same as recording").tag(0)
                        Text("4K").tag(3840)
                        Text("1440p").tag(2560)
                        Text("1080p").tag(1920)
                        Text("720p").tag(1280)
                    }
                }
                row("Smoothness") {
                    Picker("Smoothness", selection: $fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                }
                row("Format") {
                    Picker("Format", selection: $codec) {
                        ForEach(ExportCodec.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                }
            }
            Text("MP4 · \(Int(outputSize.width)) × \(Int(outputSize.height)) · \(Format.clock(model.finalDuration)) long")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.buttonStyle(QuietButtonStyle())
                Button("Export…") {
                    isPresented = false
                    chooseDestination()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            control().labelsHidden().pickerStyle(.menu).frame(width: 190, alignment: .trailing)
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = model.recording.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".") + ".mp4"
        panel.canCreateDirectories = true
        let settings = settings
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.export(to: url, settings: settings)
        }
    }
}

// MARK: - Preview

private struct PreviewArea: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ZStack {
            Theme.window
            if let error = model.loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Theme.warn)
                    Text("This recording could not be opened").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.subtext).multilineTextAlignment(.center)
                }
                .padding(40)
            } else if model.isReady {
                PlayerSurface(player: model.player)
                    .aspectRatio(model.canvasAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    .padding(26)
                    .onTapGesture { model.togglePlay() }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { ExportToast(model: model).padding(.bottom, 14) }
    }
}

/// Appears over the preview when an export finishes or fails.
private struct ExportToast: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Group {
            if let url = model.exportedURL {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    Text("Saved \(url.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(QuietButtonStyle())
                    IconButton(symbol: "xmark", help: "Dismiss", size: 24) { model.exportedURL = nil }
                }
                .modifier(ToastStyle())
            } else if let error = model.exportError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    Text(error).lineLimit(2)
                    IconButton(symbol: "xmark", help: "Dismiss", size: 24) { model.exportError = nil }
                }
                .modifier(ToastStyle())
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.exportedURL)
    }
}

private struct ToastStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 42)
            .frame(maxWidth: 560)
            .fixedSize(horizontal: true, vertical: false)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.strokeStrong))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        playerLayer.videoGravity = .resizeAspect
        root.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            Text(Format.precise(model.timeMap.composition(fromSource: model.currentTime)))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
            Text("/ \(Format.precise(model.finalDuration))")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.subtext)
            Spacer()
            IconButton(symbol: "backward.end.fill", help: "Go to the start") { model.seek(toSource: 0) }
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(.white, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            IconButton(symbol: "forward.end.fill", help: "Go to the end") { model.seek(toSource: model.duration) }
            Spacer()
            if model.hasCuts {
                Text("\(Format.clock(model.duration - model.finalDuration)) cut")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
            }
            // Balances the time readout on the left so play stays centred.
            Color.clear.frame(width: model.hasCuts ? 60 : 124, height: 1)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .disabled(!model.isReady)
    }
}
