import SwiftUI
import TasjeelCore

/// The right-hand panel: how the video looks, the camera, zooms and sound.
struct Inspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            Segmented(options: EditorModel.Tab.allCases.map { ($0, $0.rawValue) }, selection: $model.tab)
                .padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.tab {
                    case .look: LookTab(model: model)
                    case .camera: CameraTab(model: model)
                    case .zoom: ZoomTab(model: model)
                    case .audio: AudioTab(model: model)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(!model.isReady)
    }
}

private struct Group<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title)
            content()
        }
    }
}

private struct Hint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.subtext)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Look

private struct LookTab: View {
    @ObservedObject var model: EditorModel

    private var isPlain: Bool { model.edit.background.kind == .none && model.edit.padding == 0 }

    var body: some View {
        Group(title: "Style") {
            HStack(spacing: 8) {
                StyleChoice(title: "Plain", detail: "Just the screen", selected: isPlain) {
                    model.mutate { $0.applyPlainLook() }
                }
                StyleChoice(title: "Studio", detail: "Wallpaper and frame", selected: !isPlain) {
                    if isPlain { model.mutate { $0.applyStudioLook() } }
                }
            }
        }

        Group(title: "Shape") {
            Segmented(options: AspectPreset.allCases.map { ($0, $0.label) }, selection: model.binding(\.aspect, key: "aspect"))
        }

        Group(title: "Background") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                Swatch(selected: model.edit.background.kind == .none, help: "No background") {
                    model.mutate { $0.background = .none }
                } content: {
                    ZStack {
                        Color.black
                        Image(systemName: "circle.slash").font(.system(size: 13)).foregroundStyle(Theme.subtext)
                    }
                }
                ForEach(Backgrounds.gradients) { preset in
                    let style = Backdrop.gradient(preset.id)
                    Swatch(selected: model.edit.background == style, help: preset.name) {
                        pick(style)
                    } content: {
                        GradientThumb(style: style)
                    }
                }
                ForEach(Backgrounds.colors, id: \.self) { hex in
                    let style = Backdrop.color(hex)
                    Swatch(selected: model.edit.background == style, help: "Solid colour") {
                        pick(style)
                    } content: {
                        Color(hexString: hex)
                    }
                }
            }
        }

        Group(title: "Frame") {
            SliderRow(title: "Padding", value: model.binding(\.padding, key: "padding"), range: 0 ... 0.16) {
                "\(Int(($0 / 0.16 * 100).rounded()))%"
            }
            SliderRow(title: "Rounded corners", value: model.binding(\.cornerRadius, key: "radius"), range: 0 ... 0.06) {
                "\(Int(($0 / 0.06 * 100).rounded()))%"
            }
            SliderRow(title: "Shadow", value: model.binding(\.shadow, key: "shadow"), range: 0 ... 1)
        }
    }

    /// Choosing a wallpaper on a plain video adds a frame too, otherwise the
    /// wallpaper would be hidden behind the full-size screen.
    private func pick(_ style: Backdrop) {
        model.mutate { edit in
            edit.background = style
            if edit.padding == 0 {
                edit.padding = 0.06
                if edit.cornerRadius == 0 { edit.cornerRadius = 0.018 }
            }
        }
    }
}

private struct StyleChoice: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.subtext)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .frame(height: 50)
            .background(selected ? Theme.accent.opacity(0.16) : Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct Swatch<Content: View>: View {
    let selected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.strokeStrong))
                .padding(2.5)
                .overlay(RoundedRectangle(cornerRadius: 9.5, style: .continuous).strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct GradientThumb: View {
    let style: Backdrop

    private static var cache: [String: CGImage] = [:]

    var body: some View {
        if let image = Self.image(for: style) {
            Image(decorative: image, scale: 1).resizable()
        } else {
            Color.black
        }
    }

    private static func image(for style: Backdrop) -> CGImage? {
        if let hit = cache[style.gradientID] { return hit }
        let image = Backgrounds.image(for: style, size: CGSize(width: 120, height: 80))
        cache[style.gradientID] = image
        return image
    }
}

// MARK: - Camera

private struct CameraTab: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if !model.hasCamera {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "video.slash").font(.system(size: 22)).foregroundStyle(Theme.faint)
                Text("No camera in this recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Hint("Pick a camera before you start recording and you will appear in a corner of the video. You can move, resize or hide yourself here afterwards.")
            }
            .padding(.top, 6)
        } else {
            Group(title: "Camera") {
                Toggle("Show camera", isOn: model.binding(\.camera.visible, key: "cam-visible"))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.edit.camera.visible {
                Group(title: "Shape") {
                    Segmented(options: CameraShape.allCases.map { ($0, $0.label) }, selection: model.binding(\.camera.shape, key: "cam-shape"))
                    SliderRow(title: "Size", value: model.binding(\.camera.size, key: "cam-size"), range: 0.12 ... 0.5)
                }
                Group(title: "Position") {
                    CornerPicker(corner: model.binding(\.camera.corner, key: "cam-corner"), aspect: model.canvasAspect)
                }
                Group(title: "Options") {
                    Toggle("Mirror (like a selfie)", isOn: model.binding(\.camera.mirrored, key: "cam-mirror"))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Theme.accent)
                        .font(.system(size: 13))
                }
            }
        }
    }
}

/// A little picture of the canvas with a dot in each corner.
private struct CornerPicker: View {
    @Binding var corner: Corner
    let aspect: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card)
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke)
            VStack {
                HStack {
                    dot(.topLeft, "Top left")
                    Spacer()
                    dot(.topRight, "Top right")
                }
                Spacer()
                HStack {
                    dot(.bottomLeft, "Bottom left")
                    Spacer()
                    dot(.bottomRight, "Bottom right")
                }
            }
            .padding(9)
        }
        .aspectRatio(max(0.8, min(aspect, 2)), contentMode: .fit)
        .frame(maxWidth: 220)
    }

    private func dot(_ value: Corner, _ label: String) -> some View {
        let on = corner == value
        return Button {
            corner = value
        } label: {
            Circle()
                .fill(on ? Theme.accent : Theme.raised)
                .overlay(Circle().strokeBorder(on ? Color.white.opacity(0.9) : Theme.strokeStrong, lineWidth: on ? 2 : 1))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Zoom

private struct ZoomTab: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Group(title: "Zoom in on the action") {
            let clicks = model.recording.clicks.count
            Button {
                model.autoZoom()
            } label: {
                Label(clicks == 0 ? "Auto zoom" : "Auto zoom on \(clicks) click\(clicks == 1 ? "" : "s")", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(clicks == 0)
            Hint(clicks == 0
                ? "No mouse clicks were recorded, so there is nothing to follow. Add zooms by hand instead."
                : "Zooms in wherever you clicked while recording and follows from one click to the next.")
            Button {
                model.addZoom()
            } label: {
                Label("Add zoom at playhead", systemImage: "plus.magnifyingglass").frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle())
        }

        if let zoom = model.selectedZoom {
            Group(title: "Selected zoom") {
                SliderRow(title: "Amount", value: Binding(get: { zoom.scale }, set: { v in
                    model.updateZoom(zoom.id, key: "zoom-scale") { $0.scale = v }
                }), range: 1.2 ... 4) { String(format: "%.1f×", $0) }

                Text("Drag the dot to where the zoom should look.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                FocusPad(model: model, zoom: zoom)

                HStack {
                    Text("\(Format.precise(zoom.start)) – \(Format.precise(zoom.end))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.subtext)
                    Spacer()
                    Button("Delete zoom") { model.deleteSelection() }.buttonStyle(QuietButtonStyle())
                }
            }
        }

        if !model.edit.zooms.isEmpty {
            Group(title: "All zooms") {
                VStack(spacing: 4) {
                    ForEach(model.edit.zooms) { zoom in
                        let selected = model.selection == .zoom(zoom.id)
                        Button {
                            model.selection = .zoom(zoom.id)
                            model.pause()
                            model.seek(toSource: zoom.start + ZoomMath.ramp)
                        } label: {
                            HStack {
                                Image(systemName: "plus.magnifyingglass").font(.system(size: 11))
                                Text(Format.precise(zoom.start)).font(.system(size: 12.5).monospacedDigit())
                                Spacer()
                                Text(String(format: "%.1f×", zoom.scale)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.subtext)
                            }
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(selected ? Theme.accent.opacity(0.2) : Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Remove all zooms") { model.clearZooms() }.buttonStyle(QuietButtonStyle())
            }
        }
    }
}

/// A small frame of the recording; drag the dot to aim the zoom.
private struct FocusPad: View {
    @ObservedObject var model: EditorModel
    let zoom: ZoomSegment

    var body: some View {
        let aspect = model.screenSize.width / max(model.screenSize.height, 1)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image = model.thumbnail(near: zoom.start) {
                    Image(decorative: image, scale: 1).resizable()
                } else {
                    Theme.card
                }
                Color.black.opacity(0.25)
                Circle()
                    .fill(Theme.accent)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .offset(x: CGFloat(zoom.x) * geo.size.width - 9, y: CGFloat(zoom.y) * geo.size.height - 9)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let x = min(max(value.location.x / geo.size.width, 0), 1)
                    let y = min(max(value.location.y / geo.size.height, 0), 1)
                    model.updateZoom(zoom.id, key: "zoom-focus") {
                        $0.x = Double(x)
                        $0.y = Double(y)
                    }
                }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.strokeStrong))
        .accessibilityLabel("Zoom focus point")
    }
}

// MARK: - Audio

private struct AudioTab: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if !model.hasMic, !model.hasSystemAudio {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "speaker.slash").font(.system(size: 22)).foregroundStyle(Theme.faint)
                Text("No sound in this recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Hint("Turn on Microphone or Computer sound before recording to capture audio.")
            }
            .padding(.top, 6)
        } else {
            Group(title: "Volume") {
                if model.hasMic {
                    SliderRow(title: "Your microphone", value: model.binding(\.micVolume, key: "mic-volume"), range: 0 ... 2)
                }
                if model.hasSystemAudio {
                    SliderRow(title: "Computer sound", value: model.binding(\.systemVolume, key: "system-volume"), range: 0 ... 2)
                }
                Hint("Your voice and the computer's sound were recorded separately, so you can balance them or mute one. 100% is as recorded.")
            }
        }
    }
}
