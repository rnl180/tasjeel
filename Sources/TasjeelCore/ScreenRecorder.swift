@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

/// Captures the screen, system audio and microphone with ScreenCaptureKit and
/// hands the samples to a `CaptureWriter`.
///
/// Life cycle: `arm()` starts the stream (nothing is written yet, but the
/// microphone's format is learned), `begin()` starts the file, `finish()` ends it.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Config {
        public var filter: SCContentFilter
        public var width: Int
        public var height: Int
        public var fps: Int
        public var systemAudio: Bool
        public var microphone: Bool
        /// nil uses the system default input.
        public var microphoneID: String?
        public var outputURL: URL

        public init(filter: SCContentFilter, width: Int, height: Int, fps: Int, systemAudio: Bool,
                    microphone: Bool, microphoneID: String?, outputURL: URL) {
            self.filter = filter
            self.width = width
            self.height = height
            self.fps = fps
            self.systemAudio = systemAudio
            self.microphone = microphone
            self.microphoneID = microphoneID
            self.outputURL = outputURL
        }
    }

    private let config: Config
    private let writer: CaptureWriter
    private let queue = DispatchQueue(label: "tasjeel.screen.samples", qos: .userInitiated)
    private var stream: SCStream?

    /// Called (on an arbitrary queue) if the system ends the capture, e.g. the
    /// display is unplugged or sharing is stopped from the menu bar.
    public var onStreamStopped: (@Sendable (Error?) -> Void)?

    public init(config: Config, clock: RecordingClock) {
        self.config = config
        writer = CaptureWriter(
            config: .init(width: config.width, height: config.height, fps: config.fps, systemAudio: config.systemAudio,
                          microphone: config.microphone, outputURL: config.outputURL),
            clock: clock
        )
    }

    public func arm() async throws {
        let c = SCStreamConfiguration()
        c.width = config.width
        c.height = config.height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        c.queueDepth = 6
        c.showsCursor = true
        c.scalesToFit = true
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.capturesAudio = config.systemAudio || config.microphone
        c.sampleRate = 48000
        c.channelCount = 2
        c.excludesCurrentProcessAudio = true
        if config.microphone {
            c.captureMicrophone = true
            if let id = config.microphoneID { c.microphoneCaptureDeviceID = id }
        }

        let stream = SCStream(filter: config.filter, configuration: c, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if c.capturesAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if config.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream
    }

    /// Starts writing. The file's first frame is the next one the screen delivers.
    public func begin() throws {
        guard stream != nil else { throw RecorderError.notArmed }
        try writer.begin()
    }

    public func finish() async throws -> ScreenRecordingResult {
        try? await stream?.stopCapture()
        return try await writer.finish()
    }

    /// Stops and deletes whatever was written.
    public func cancel() async {
        try? await stream?.stopCapture()
        writer.cancel()
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .screen:
            // ScreenCaptureKit also sends idle and blank notifications; only
            // "complete" buffers carry a picture.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
                let raw = attachments.first?[.status] as? Int,
                SCFrameStatus(rawValue: raw) == .complete else { return }
            writer.appendVideo(buffer)
        case .audio:
            if config.systemAudio { writer.appendSystemAudio(buffer) }
        case .microphone:
            writer.appendMicrophone(buffer)
        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped?(error)
    }
}
