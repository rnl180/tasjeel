import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal

/// Where everything sits on the canvas. Core Image coordinates: origin bottom-left.
public struct RenderLayout: Hashable, Sendable {
    public let canvas: CGSize
    public let screenRect: CGRect
    public let radius: CGFloat
    public let cameraRect: CGRect?
    public let cameraRadius: CGFloat

    public init(canvas: CGSize, screenSize: CGSize, edit: EditState, hasCamera: Bool) {
        self.canvas = canvas
        let short = min(canvas.width, canvas.height)
        let pad = CGFloat(edit.padding) * short
        let content = CGRect(origin: .zero, size: canvas).insetBy(dx: pad, dy: pad)

        // Aspect-fit the screen into the padded area.
        let sw = max(screenSize.width, 1), sh = max(screenSize.height, 1)
        let fit = min(content.width / sw, content.height / sh)
        let size = CGSize(width: sw * fit, height: sh * fit)
        screenRect = CGRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2,
                            width: size.width, height: size.height).integral
        radius = CGFloat(edit.cornerRadius) * short

        if hasCamera, edit.camera.visible {
            let h = CGFloat(edit.camera.size) * short
            let w = edit.camera.shape == .wide ? h * 16 / 9 : h
            let margin = short * 0.035
            let x = (edit.camera.corner == .topLeft || edit.camera.corner == .bottomLeft) ? margin : canvas.width - margin - w
            let y = (edit.camera.corner == .bottomLeft || edit.camera.corner == .bottomRight) ? margin : canvas.height - margin - h
            cameraRect = CGRect(x: x, y: y, width: w, height: h).integral
            switch edit.camera.shape {
            case .circle: cameraRadius = h / 2
            case .rounded: cameraRadius = h * 0.2
            case .wide: cameraRadius = h * 0.16
            }
        } else {
            cameraRect = nil
            cameraRadius = 0
        }
    }
}

/// Draws one finished frame: wallpaper, the screen recording (zoomed, rounded,
/// with a drop shadow) and the camera overlay. Used for preview and export, so
/// what you see while editing is exactly what gets exported.
public final class FrameRenderer: @unchecked Sendable {
    public static let shared = FrameRenderer()

    public let context: CIContext
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]

    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    public func render(screen: CIImage?, camera: CIImage?, sourceTime: Double, canvas: CGSize,
                       screenSize: CGSize, edit: EditState, caption: String? = nil) -> CIImage {
        let layout = RenderLayout(canvas: canvas, screenSize: screenSize, edit: edit, hasCamera: camera != nil)
        let canvasRect = CGRect(origin: .zero, size: canvas)
        var out = backdrop(layout: layout, edit: edit)

        if let screen {
            let r = layout.screenRect
            let ext = screen.extent
            // Work out one scale and one offset for the whole placement (fit
            // into the frame, then zoom), so the picture is resampled once.
            var scale = CGSize(width: r.width / ext.width, height: r.height / ext.height)
            var offset = CGPoint(x: r.minX, y: r.minY)

            let zoom = ZoomMath.state(at: sourceTime, zooms: edit.zooms)
            if zoom.scale > 1.0005 {
                let s = CGFloat(zoom.scale)
                let focus = CGPoint(x: r.minX + CGFloat(zoom.x) * r.width, y: r.maxY - CGFloat(zoom.y) * r.height)
                let e = CGFloat(zoom.progress)
                // Drift the focus point towards the centre, but never so far
                // that the magnified picture stops covering its frame.
                var target = CGPoint(x: focus.x + (r.midX - focus.x) * e, y: focus.y + (r.midY - focus.y) * e)
                target.x = min(max(target.x, r.maxX - s * (r.maxX - focus.x)), r.minX + s * (focus.x - r.minX))
                target.y = min(max(target.y, r.maxY - s * (r.maxY - focus.y)), r.minY + s * (focus.y - r.minY))
                scale = CGSize(width: scale.width * s, height: scale.height * s)
                offset = CGPoint(x: s * (r.minX - focus.x) + target.x, y: s * (r.minY - focus.y) + target.y)
            }
            var image = screen.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            image = Self.resampled(image, scale: scale)
                .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
            image = image.cropped(to: r)

            if layout.radius > 0.5 {
                out = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: out,
                    kCIInputMaskImageKey: Self.roundedRect(r, radius: layout.radius, color: .white),
                ])
            } else {
                out = image.composited(over: out)
            }
        }

        if let camera, let rect = layout.cameraRect {
            out = cameraUnderlay(layout: layout).composited(over: out)

            // Centre-crop the camera to the overlay's aspect ratio.
            let ext = camera.extent
            let aspect = rect.width / rect.height
            var crop = ext
            if ext.width / ext.height > aspect {
                let w = ext.height * aspect
                crop = CGRect(x: ext.midX - w / 2, y: ext.minY, width: w, height: ext.height)
            } else {
                let h = ext.width / aspect
                crop = CGRect(x: ext.minX, y: ext.midY - h / 2, width: ext.width, height: h)
            }
            var image = camera.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            if edit.camera.mirrored {
                image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                    .concatenating(CGAffineTransform(translationX: crop.width, y: 0)))
            }
            let s = rect.width / crop.width
            image = Self.resampled(image, scale: CGSize(width: s, height: s))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                .cropped(to: rect)
            out = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out,
                kCIInputMaskImageKey: Self.roundedRect(rect, radius: layout.cameraRadius, color: .white),
            ])
        }

        if let caption, let image = captionImage(caption, canvas: canvas) {
            out = image.composited(over: out)
        }

        return out.cropped(to: canvasRect)
    }

    /// A caption stays up for seconds, so its picture is drawn once and reused.
    private func captionImage(_ text: String, canvas: CGSize) -> CIImage? {
        let key = "cap|\(canvas)|\(text)"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let image = CaptionRenderer.image(text: text, canvas: canvas) else { return nil }
        lock.lock()
        if cache.count > 12 { cache.removeAll() }
        cache[key] = image
        lock.unlock()
        return image
    }

    // MARK: - Cached static layers

    /// Wallpaper plus the screen's drop shadow. Identical for every frame, so
    /// it is rasterised once and reused.
    private func backdrop(layout: RenderLayout, edit: EditState) -> CIImage {
        let key = "bg|\(layout.canvas)|\(layout.screenRect)|\(layout.radius)|\(edit.shadow)|\(edit.background)"
        return cached(key) {
            let canvasRect = CGRect(origin: .zero, size: layout.canvas)
            var image: CIImage
            if let cg = Backgrounds.image(for: edit.background, size: layout.canvas) {
                image = CIImage(cgImage: cg)
            } else {
                image = CIImage(color: .black).cropped(to: canvasRect)
            }
            let framed = layout.screenRect.width < layout.canvas.width - 2 || layout.screenRect.height < layout.canvas.height - 2
            if edit.shadow > 0.01, framed, edit.background.kind != .none {
                let short = min(layout.canvas.width, layout.canvas.height)
                let strength = CGFloat(edit.shadow)
                let shadow = Self.roundedRect(layout.screenRect, radius: layout.radius,
                                              color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.55 * strength))
                    .transformed(by: CGAffineTransform(translationX: 0, y: -short * 0.014 * strength))
                    .applyingGaussianBlur(sigma: Double(short * 0.022 * strength))
                image = shadow.composited(over: image)
            }
            return self.rasterise(image.cropped(to: canvasRect), region: canvasRect)
        }
    }

    /// Soft shadow and a thin light ring that sit under the camera overlay.
    private func cameraUnderlay(layout: RenderLayout) -> CIImage {
        guard let rect = layout.cameraRect else { return CIImage.empty() }
        let key = "cam|\(layout.canvas)|\(rect)|\(layout.cameraRadius)"
        return cached(key) {
            let ring = max(2, rect.height * 0.014)
            let blur = rect.height * 0.05
            let shadow = Self.roundedRect(rect, radius: layout.cameraRadius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5))
                .transformed(by: CGAffineTransform(translationX: 0, y: -rect.height * 0.03))
                .applyingGaussianBlur(sigma: Double(blur))
            let border = Self.roundedRect(rect.insetBy(dx: -ring, dy: -ring), radius: layout.cameraRadius + ring,
                                          color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92))
            let region = rect.insetBy(dx: -blur * 4, dy: -blur * 4).integral
            return self.rasterise(border.composited(over: shadow).cropped(to: region), region: region)
        }
    }

    private func cached(_ key: String, make: () -> CIImage) -> CIImage {
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let image = make()
        lock.lock()
        if cache.count > 12 { cache.removeAll() }
        cache[key] = image
        lock.unlock()
        return image
    }

    private func rasterise(_ image: CIImage, region: CGRect) -> CIImage {
        guard let cg = context.createCGImage(image, from: region) else { return image }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
    }

    /// Resizes a picture whose origin is at zero. Text is the whole point of a
    /// screen recording, and the plain resize Core Image does by default
    /// leaves it soft, so this uses a Lanczos filter, which keeps edges crisp
    /// both when shrinking a Retina recording and when zooming into it.
    static func resampled(_ image: CIImage, scale: CGSize) -> CIImage {
        guard scale.width > 0, scale.height > 0 else { return image }
        if abs(scale.width - 1) < 0.0005, abs(scale.height - 1) < 0.0005 { return image }
        let extent = image.extent
        let filter = CIFilter.lanczosScaleTransform()
        // Repeating the edge pixels outwards keeps the border from fading.
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scale.height)
        filter.aspectRatio = Float(scale.width / scale.height)
        guard let output = filter.outputImage else {
            return image.transformed(by: CGAffineTransform(scaleX: scale.width, y: scale.height))
        }
        return output.cropped(to: CGRect(x: 0, y: 0, width: extent.width * scale.width, height: extent.height * scale.height))
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        filter.radius = Float(min(radius, min(rect.width, rect.height) / 2))
        filter.color = color
        return filter.outputImage ?? CIImage.empty()
    }
}
