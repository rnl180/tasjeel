@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// Tells the compositor how to draw the frames in its time range.
public final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let edit: EditState
    let timeMap: TimeMap
    let screenSize: CGSize
    /// Transcript lines to draw as captions, sorted by start; empty for none.
    let captions: [TranscriptSegment]

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?,
         edit: EditState, timeMap: TimeMap, screenSize: CGSize, captions: [TranscriptSegment]) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.edit = edit
        self.timeMap = timeMap
        self.screenSize = screenSize
        self.captions = captions
        var ids: [NSValue] = [NSNumber(value: screenTrackID)]
        if let cameraTrackID { ids.append(NSNumber(value: cameraTrackID)) }
        requiredSourceTrackIDs = ids
    }
}

/// AVFoundation calls this for every frame, during both playback and export.
public final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "tasjeel.compositor", qos: .userInteractive)
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    public var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelAttributes }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelAttributes }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Tasjeel", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Could not prepare a frame for rendering.",
                ]))
                return
            }
            let canvas = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
            let sourceTime = instruction.timeMap.source(fromComposition: request.compositionTime.seconds)
            let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
            let camera = instruction.cameraTrackID
                .flatMap { request.sourceFrame(byTrackID: $0) }
                .map { CIImage(cvPixelBuffer: $0) }

            let caption = instruction.captions.first { sourceTime >= $0.start && sourceTime < $0.end }?.text

            let renderer = FrameRenderer.shared
            let image = renderer.render(screen: screen, camera: camera, sourceTime: sourceTime, canvas: canvas,
                                        screenSize: instruction.screenSize, edit: instruction.edit, caption: caption)
            renderer.context.render(image, to: output, bounds: CGRect(origin: .zero, size: canvas), colorSpace: self.colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {}
}
