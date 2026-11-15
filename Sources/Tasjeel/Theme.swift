import SwiftUI
import TasjeelCore

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    init(hexString: String) {
        let c = Backgrounds.rgb(hex: hexString)
        self.init(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: 1)
    }
}

/// One dark palette for the whole app: near-black surfaces, a single violet
/// accent for selection, and red reserved for recording.
enum Theme {
    static let window = Color(hex: 0x0C0D11)
    static let panel = Color(hex: 0x121318)
    static let card = Color(hex: 0x191B22)
    static let raised = Color(hex: 0x22252E)
    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.16)
    static let text = Color.white.opacity(0.94)
    static let subtext = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.34)
    static let accent = Color(hex: 0x8F7CFF)
    static let record = Color(hex: 0xFF4A3D)
    static let good = Color(hex: 0x3DD68C)
    static let warn = Color(hex: 0xF5B546)
}

// MARK: - Formatting

enum Format {
    /// 75 -> "1:15", 3725 -> "1:02:05"
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// With tenths, for the editor: "1:15.4"
    static func precise(_ seconds: Double) -> String {
        let t = max(0, seconds)
        let whole = Int(t)
        let tenths = Int((t - Double(whole)) * 10)
        return "\(clock(Double(whole))).\(tenths)"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Controls

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 15 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 18 : 14)
            .frame(height: large ? 44 : 30)
            .frame(maxWidth: large ? .infinity : nil)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: large ? 12 : 8, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

struct QuietButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(selected ? Color.white : Theme.text)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                (selected ? Theme.accent : (configuration.isPressed ? Theme.raised.opacity(0.7) : Theme.raised)),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// A square, icon-only button with a tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 30
    var tint: Color = Theme.text
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(hovering ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.7)
            .foregroundStyle(Theme.faint)
    }
}

/// Label, value and slider on two lines.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var display: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer()
                Text(display(value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.subtext)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
        }
    }
}

/// A compact segmented control that works with any hashable value.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Theme.subtext)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(on ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }
}

extension View {
    func cardSurface(radius: CGFloat = 12) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.stroke))
    }
}
