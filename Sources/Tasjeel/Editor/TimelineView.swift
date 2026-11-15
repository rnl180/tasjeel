import SwiftUI
import TasjeelCore

/// The bottom strip: editing tools, then the clip and zoom tracks.
struct TimelinePanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                let inset: CGFloat = 18
                let width = max(geo.size.width - inset * 2, 200) * model.timelineZoom
                ScrollView(.horizontal) {
                    TimelineTracks(model: model, width: width)
                        .padding(.horizontal, inset)
                        .padding(.top, 2)
                }
                .scrollIndicators(model.timelineZoom > 1.01 ? .visible : .hidden)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ToolButton(symbol: "scissors", title: "Split", help: "Cut the clip in two at the playhead (S)") { model.split() }
                .disabled(!model.canSplit)
            ToolButton(symbol: "trash", title: "Delete", help: "Remove the selected part (Delete)") { model.deleteSelection() }
                .disabled(!model.canDelete)
            Rectangle().fill(Theme.stroke).frame(width: 1, height: 18).padding(.horizontal, 4)
            ToolButton(symbol: "arrow.right.to.line", title: "Trim start", help: "Remove everything before the playhead ([)") { model.trimStart() }
                .disabled(!model.canTrimStart)
            ToolButton(symbol: "arrow.left.to.line", title: "Trim end", help: "Remove everything after the playhead (])") { model.trimEnd() }
                .disabled(!model.canTrimEnd)
            if case .gap(let index) = model.selection {
                ToolButton(symbol: "arrow.uturn.backward.circle", title: "Restore", help: "Put the selected part back") { model.restoreGap(index) }
            } else if model.hasCuts {
                ToolButton(symbol: "arrow.uturn.backward.circle", title: "Restore all", help: "Put back everything that was cut") { model.restoreAll() }
            }
            Rectangle().fill(Theme.stroke).frame(width: 1, height: 18).padding(.horizontal, 4)
            ToolButton(symbol: "plus.magnifyingglass", title: "Add zoom", help: "Zoom in at the playhead (Z)") { model.addZoom() }
            Spacer()
            Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            Slider(value: $model.timelineZoom, in: 1 ... 24)
                .controlSize(.mini)
                .tint(Theme.subtext)
                .frame(width: 110)
                .help("Stretch the timeline for finer cuts")
                .accessibilityLabel("Timeline zoom")
            Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .disabled(!model.isReady)
    }
}

private struct ToolButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(hovering && enabled ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Tracks

private enum TimelineMetrics {
    static let ruler: CGFloat = 20
    static let clipTop: CGFloat = 24
    static let clipHeight: CGFloat = 58
    static let zoomTop: CGFloat = 92
    static let zoomHeight: CGFloat = 26
    static let total: CGFloat = 126
}

private struct TimelineTracks: View {
    @ObservedObject var model: EditorModel
    let width: CGFloat

    private var pps: CGFloat { width / CGFloat(max(model.duration, 0.1)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Ruler(duration: model.duration, width: width)
                .frame(width: width, height: TimelineMetrics.ruler)

            clipTrack
                .frame(width: width, height: TimelineMetrics.clipHeight)
                .offset(y: TimelineMetrics.clipTop)

            // One gesture covers ruler and clip: drag to scrub, click to select.
            Color.clear
                .frame(width: width, height: TimelineMetrics.clipTop + TimelineMetrics.clipHeight)
                .contentShape(Rectangle())
                .gesture(scrubGesture)

            zoomTrack
                .frame(width: width, height: TimelineMetrics.zoomHeight)
                .offset(y: TimelineMetrics.zoomTop)

            Playhead()
                .frame(width: 13, height: TimelineMetrics.total)
                .offset(x: CGFloat(model.currentTime) * pps - 6.5)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: TimelineMetrics.total, alignment: .topLeading)
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if abs(value.translation.width) > 2 || abs(value.translation.height) > 2 {
                    model.pause()
                    model.seek(toSource: Double(value.location.x / pps))
                }
            }
            .onEnded { value in
                guard abs(value.translation.width) <= 2, abs(value.translation.height) <= 2 else { return }
                let time = Double(value.location.x / pps)
                if let gap = model.gaps.firstIndex(where: { $0.contains(time) }) {
                    model.selection = .gap(gap)
                } else if let segment = model.edit.segments.firstIndex(where: { $0.contains(time) }) {
                    // Only worth selecting when there is more than one part.
                    model.selection = model.edit.segments.count > 1 ? .segment(segment) : .none
                    model.seek(toSource: time)
                } else {
                    model.selection = .none
                    model.seek(toSource: time)
                }
            }
    }

    // MARK: Clip

    private var clipTrack: some View {
        ZStack(alignment: .topLeading) {
            Filmstrip(thumbnails: model.thumbnails.map(\.image), width: width, height: TimelineMetrics.clipHeight)

            // Removed parts: dimmed and hatched.
            ForEach(Array(model.gaps.enumerated()), id: \.offset) { index, gap in
                let selected = model.selection == .gap(index)
                ZStack {
                    Color.black.opacity(0.72)
                    Hatching().stroke(Color.white.opacity(selected ? 0.3 : 0.12), lineWidth: 1)
                }
                .overlay(Rectangle().strokeBorder(selected ? Theme.warn : Color.clear, lineWidth: 2))
                .frame(width: max(1, CGFloat(gap.duration) * pps), height: TimelineMetrics.clipHeight)
                .offset(x: CGFloat(gap.start) * pps)
            }

            // Kept parts: an outline, brighter when selected.
            ForEach(Array(model.edit.segments.enumerated()), id: \.offset) { index, segment in
                let selected = model.selection == .segment(index)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.white.opacity(0.22), lineWidth: selected ? 2.5 : 1)
                    .background(selected ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(width: max(2, CGFloat(segment.duration) * pps), height: TimelineMetrics.clipHeight)
                    .offset(x: CGFloat(segment.start) * pps)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }

    // MARK: Zoom

    private var zoomTrack: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(alignment: .leading) {
                    if model.edit.zooms.isEmpty {
                        Label("Zoom track: press Add zoom, or use Auto zoom in the Zoom tab", systemImage: "plus.magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faint)
                            .padding(.leading, 10)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selection = .none }

            // Where clicks happened during recording.
            ForEach(Array(model.recording.clicks.enumerated()), id: \.offset) { _, click in
                Circle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 4, height: 4)
                    .offset(x: CGFloat(click.t) * pps - 2, y: TimelineMetrics.zoomHeight - 6)
                    .allowsHitTesting(false)
            }

            ForEach(model.edit.zooms) { zoom in
                ZoomBlock(model: model, zoom: zoom, pps: pps)
                    .offset(x: CGFloat(zoom.start) * pps)
            }
        }
    }
}

/// A zoom on the timeline: drag the middle to move, the ends to resize.
private struct ZoomBlock: View {
    @ObservedObject var model: EditorModel
    let zoom: ZoomSegment
    let pps: CGFloat
    @State private var origin: ZoomSegment?

    private var selected: Bool { model.selection == .zoom(zoom.id) }
    private var width: CGFloat { max(14, CGFloat(zoom.end - zoom.start) * pps) }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.accent.opacity(selected ? 0.95 : 0.55))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(selected ? 0.9 : 0.25), lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .leading) {
                if width > 54 {
                    Text(String(format: "%.1f×", zoom.scale))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.leading, 9)
                }
            }
            .overlay(alignment: .leading) { handle(edge: .leading) }
            .overlay(alignment: .trailing) { handle(edge: .trailing) }
            .frame(width: width, height: TimelineMetrics.zoomHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if origin == nil {
                            origin = zoom
                            model.selection = .zoom(zoom.id)
                            model.tab = .zoom
                        }
                        guard let origin, abs(value.translation.width) > 2 else { return }
                        let length = origin.end - origin.start
                        let start = min(max(0, origin.start + Double(value.translation.width / pps)), model.duration - length)
                        model.updateZoom(zoom.id, key: "zoom-move") {
                            $0.start = start
                            $0.end = start + length
                        }
                    }
                    .onEnded { _ in origin = nil }
            )
            .help("Drag to move, drag an end to resize")
            .accessibilityLabel("Zoom at \(Format.clock(zoom.start))")
    }

    private func handle(edge: Edge) -> some View {
        Capsule()
            .fill(.white.opacity(selected ? 0.9 : 0.5))
            .frame(width: 3, height: 12)
            .frame(width: 10, height: TimelineMetrics.zoomHeight)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if origin == nil {
                            origin = zoom
                            model.selection = .zoom(zoom.id)
                        }
                        guard let origin else { return }
                        let delta = Double(value.translation.width / pps)
                        model.updateZoom(zoom.id, key: "zoom-resize") {
                            if edge == .leading {
                                $0.start = min(max(0, origin.start + delta), origin.end - 0.4)
                            } else {
                                $0.end = max(origin.end + delta, origin.start + 0.4)
                            }
                        }
                    }
                    .onEnded { _ in origin = nil }
            )
    }
}

// MARK: - Pieces

private struct Filmstrip: View {
    let thumbnails: [CGImage]
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            Theme.card
            if !thumbnails.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(thumbnails.count), height: height)
                            .clipped()
                    }
                }
                .opacity(0.9)
            }
        }
        .frame(width: width, height: height)
    }
}

private struct Hatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 9
        }
        return path
    }
}

private struct Playhead: View {
    var body: some View {
        VStack(spacing: 0) {
            // A small flag on top makes the line easy to find and grab by eye.
            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 3)
                .fill(Theme.record)
                .frame(width: 13, height: 14)
            Rectangle().fill(Theme.record).frame(width: 2)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
    }
}

/// Time labels across the top, spaced so they never crowd.
private struct Ruler: View {
    let duration: Double
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            guard duration > 0, size.width > 0 else { return }
            let pps = size.width / CGFloat(duration)
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
            let step = steps.first { CGFloat($0) * pps >= 74 } ?? 3600
            var t = 0.0
            while t <= duration + 0.001 {
                let x = CGFloat(t) * pps
                context.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.white.opacity(0.25)))
                let label = step < 1 ? Format.precise(t) : Format.clock(t)
                let text = Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.white.opacity(0.45))
                // Keep the last label from running off the right edge.
                if x + 34 < size.width || t == 0 {
                    context.draw(text, at: CGPoint(x: x + 4, y: size.height - 13), anchor: .leading)
                }
                t += step
            }
        }
        .allowsHitTesting(false)
    }
}
