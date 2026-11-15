import CoreGraphics
import Foundation

public struct GradientPreset: Identifiable, Sendable {
    public struct Glow: Sendable {
        let hex: String
        let x: Double
        let y: Double
        let radius: Double
        let alpha: Double
    }

    public let id: String
    public let name: String
    let stops: [String]
    /// Degrees, 0 = left to right, 90 = bottom to top.
    let angle: Double
    let glows: [Glow]
}

/// Wallpapers drawn in code, so the app ships no image assets.
public enum Backgrounds {
    public static let gradients: [GradientPreset] = [
        GradientPreset(id: "dusk", name: "Dusk", stops: ["#2B1E5C", "#7B3FA0", "#F0668A"], angle: 35,
                       glows: [.init(hex: "#FFB36B", x: 0.85, y: 0.15, radius: 0.55, alpha: 0.55)]),
        GradientPreset(id: "ocean", name: "Ocean", stops: ["#0B1E4A", "#1F5FBF", "#4FD1E0"], angle: 40,
                       glows: [.init(hex: "#8FF3D0", x: 0.9, y: 0.85, radius: 0.5, alpha: 0.35)]),
        GradientPreset(id: "ember", name: "Ember", stops: ["#3A0D1E", "#C2362F", "#FF9A3D"], angle: 30,
                       glows: [.init(hex: "#FFE08A", x: 0.15, y: 0.9, radius: 0.5, alpha: 0.4)]),
        GradientPreset(id: "mint", name: "Mint", stops: ["#0E3B3A", "#1E9C7F", "#B8F2A6"], angle: 45,
                       glows: [.init(hex: "#E9FFB0", x: 0.8, y: 0.2, radius: 0.45, alpha: 0.35)]),
        GradientPreset(id: "violet", name: "Violet", stops: ["#1B1446", "#5B3FD6", "#B58CFF"], angle: 55,
                       glows: [.init(hex: "#FF8AD8", x: 0.15, y: 0.2, radius: 0.5, alpha: 0.4)]),
        GradientPreset(id: "sand", name: "Sand", stops: ["#E9D8C2", "#E7B894", "#D98C7A"], angle: 25,
                       glows: [.init(hex: "#FFF4DC", x: 0.2, y: 0.85, radius: 0.55, alpha: 0.6)]),
        GradientPreset(id: "slate", name: "Slate", stops: ["#15181F", "#2B3340", "#4A5568"], angle: 60,
                       glows: [.init(hex: "#8FA3C4", x: 0.85, y: 0.9, radius: 0.5, alpha: 0.25)]),
        GradientPreset(id: "paper", name: "Paper", stops: ["#F4F5F8", "#E3E6EE", "#CCD2E0"], angle: 70,
                       glows: [.init(hex: "#FFFFFF", x: 0.2, y: 0.8, radius: 0.5, alpha: 0.7)]),
    ]

    public static let colors: [String] = ["#0B0C10", "#1C1F2A", "#FFFFFF", "#E8EBF2", "#2952E3", "#16A37B", "#E5484D", "#F2A93B"]

    public static func gradient(id: String) -> GradientPreset {
        gradients.first { $0.id == id } ?? gradients[0]
    }

    public static func rgb(hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 0, 0) }
        return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }

    static func cgColor(hex: String, alpha: CGFloat = 1) -> CGColor {
        let c = rgb(hex: hex)
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    /// Renders a background at the given pixel size. Returns nil for `.none`.
    public static func image(for style: Backdrop, size: CGSize) -> CGImage? {
        guard style.kind != .none else { return nil }
        let w = max(2, Int(size.width.rounded())), h = max(2, Int(size.height.rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)

        switch style.kind {
        case .none:
            return nil
        case .color:
            ctx.setFillColor(cgColor(hex: style.colorHex))
            ctx.fill(rect)
        case .gradient:
            let preset = gradient(id: style.gradientID)
            let colors = preset.stops.map { cgColor(hex: $0) } as CFArray
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: nil) {
                let a = preset.angle * .pi / 180
                let dx = cos(a) * Double(w) / 2, dy = sin(a) * Double(h) / 2
                let c = CGPoint(x: rect.midX, y: rect.midY)
                ctx.drawLinearGradient(g, start: CGPoint(x: c.x - dx, y: c.y - dy), end: CGPoint(x: c.x + dx, y: c.y + dy),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            for glow in preset.glows {
                let colors = [cgColor(hex: glow.hex, alpha: glow.alpha), cgColor(hex: glow.hex, alpha: 0)] as CFArray
                guard let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { continue }
                let centre = CGPoint(x: glow.x * Double(w), y: glow.y * Double(h))
                ctx.drawRadialGradient(g, startCenter: centre, startRadius: 0, endCenter: centre,
                                       endRadius: glow.radius * Double(max(w, h)), options: [])
            }
        }
        return ctx.makeImage()
    }
}
