import AppKit
import AVFoundation
import SwiftUI
import TasjeelCore

/// The floating pieces shown while recording: the control pill, the camera
/// bubble and the countdown. They belong to this app, and display recordings
/// leave this app out, so none of them end up in the video.
@MainActor
final class OverlayController {
    private var hud: NSPanel?
    private var bubble: NSPanel?
    private var countdown: NSPanel?
    private let countdownModel = CountdownModel()

    func showHUD(on screen: NSScreen?) {
        hud?.close()
        let host = NSHostingView(rootView: RecordingHUD().environmentObject(AppState.shared))
        let size = host.fittingSize
        let panel = makePanel(size: size)
        panel.contentView = host
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 26))
        panel.orderFrontRegardless()
        hud = panel
    }

    func showBubble(session: AVCaptureSession, on screen: NSScreen?) {
        bubble?.close()
        let side: CGFloat = 196
        let panel = makePanel(size: CGSize(width: side, height: side))
        panel.contentView = CameraBubbleView(session: session, side: side)
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: area.maxX - side - 28, y: area.minY + 28))
        panel.orderFrontRegardless()
        bubble = panel
    }

    /// Where the bubble was left, so the editor starts with the camera in the same corner.
    func bubbleCorner() -> Corner {
        guard let bubble, let area = bubble.screen?.frame else { return .bottomRight }
        let left = bubble.frame.midX < area.midX
        let bottom = bubble.frame.midY < area.midY
        switch (left, bottom) {
        case (true, true): return .bottomLeft
        case (true, false): return .topLeft
        case (false, true): return .bottomRight
        case (false, false): return .topRight
        }
    }

    func showCountdown(_ number: Int, on screen: NSScreen?) {
        countdownModel.number = number
        if countdown == nil {
            let side: CGFloat = 176
            let panel = makePanel(size: CGSize(width: side, height: side))
            panel.ignoresMouseEvents = true
            panel.contentView = NSHostingView(rootView: CountdownView(model: countdownModel))
            let area = (screen ?? NSScreen.main)?.frame ?? .zero
            panel.setFrameOrigin(NSPoint(x: area.midX - side / 2, y: area.midY - side / 2))
            panel.orderFrontRegardless()
            countdown = panel
        }
    }

    func hideCountdown() {
        countdown?.close()
        countdown = nil
    }

    func hideAll() {
        hideCountdown()
        hud?.close()
        hud = nil
        bubble?.close()
        bubble = nil
    }

    private func makePanel(size: CGSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

// MARK: - Control pill

struct RecordingHUD: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 10) {
            status
            Rectangle().fill(Theme.strokeStrong).frame(width: 1, height: 20)
            controls
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color(hex: 0x16171C, opacity: 0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.strokeStrong))
        .padding(6)
        .fixedSize()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var status: some View {
        switch app.phase {
        case .recording, .paused:
            HStack(spacing: 8) {
                Circle()
                    .fill(app.phase == .paused ? Theme.warn : Theme.record)
                    .frame(width: 9, height: 9)
                Text(Format.clock(app.elapsed))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 44, alignment: .leading)
                if app.phase == .paused {
                    Text("Paused").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warn)
                }
            }
        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            }
        default:
            Text("Get ready…").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
        }
    }

    @ViewBuilder private var controls: some View {
        switch app.phase {
        case .recording, .paused:
            HStack(spacing: 4) {
                IconButton(symbol: app.phase == .paused ? "play.fill" : "pause.fill",
                           help: app.phase == .paused ? "Resume" : "Pause") { app.togglePause() }
                Button {
                    app.stopRecording()
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 10, height: 10)
                        Text("Stop").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.record, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Stop and open in the editor (⌥⇧R)")
                IconButton(symbol: "trash", help: "Discard recording", tint: Theme.subtext) { app.confirmDiscard() }
            }
        case .finishing:
            EmptyView()
        default:
            Button("Cancel") { app.cancelRecording() }
                .buttonStyle(QuietButtonStyle())
        }
    }
}

// MARK: - Countdown

@MainActor
final class CountdownModel: ObservableObject {
    @Published var number = 3
}

struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.72))
            Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 2)
            Text("\(model.number)")
                .font(.system(size: 92, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(8)
        .animation(.easeOut(duration: 0.25), value: model.number)
    }
}

// MARK: - Camera bubble

/// A round, draggable live view of the webcam.
final class CameraBubbleView: NSView {
    private let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession, side: CGFloat) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.cornerRadius = side / 2
        root.masksToBounds = true
        root.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        root.borderWidth = 3
        layer = root

        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        root.addSublayer(preview)
        // Show yourself mirrored, the way a mirror (and every video call) does.
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }

    override var mouseDownCanMoveWindow: Bool { true }
}
