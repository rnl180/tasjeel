import AppKit
import CoreImage
import CoreText
import Foundation

/// Draws one caption line: white text on a dark rounded plate, centred near
/// the bottom of the canvas. Core Text lays the words out, so right-to-left
/// languages such as Arabic come out correctly.
enum CaptionRenderer {
    /// Returns the caption as an image already positioned on the canvas
    /// (Core Image coordinates, origin bottom-left), or nil for empty text.
    static func image(text: String, canvas: CGSize) -> CIImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let short = min(canvas.width, canvas.height)
        let fontSize = max(13, short * 0.04)
        let padding = fontSize * 0.55
        let maxTextWidth = canvas.width * 0.82 - padding * 2

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: trimmed, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])

        let setter = CTFramesetterCreateWithAttributedString(string)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude), nil
        )
        let textSize = CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
        let width = Int(textSize.width + padding * 2), height = Int(textSize.height + padding * 1.5)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let plate = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: fontSize * 0.45, cornerHeight: fontSize * 0.45, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.66))
        ctx.fillPath()

        let textRect = CGRect(x: padding, y: padding * 0.75, width: textSize.width, height: textSize.height)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        let x = ((canvas.width - CGFloat(width)) / 2).rounded()
        let y = (short * 0.055).rounded()
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}
