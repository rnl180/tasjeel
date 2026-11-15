@preconcurrency import AVFoundation
import Foundation

public struct CameraRecordingResult: Sendable {
    public let firstPTS: CMTime
    public let width: Int
    public let height: Int
}

/// Runs the webcam. The same capture session feeds the on-screen bubble (via
/// `session`) and, while recording, a separate movie file, so the editor can
/// move, resize or hide the camera afterwards.
public final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "tasjeel.camera.session")
    private let sampleQueue = DispatchQueue(label: "tasjeel.camera.samples", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?

    // Touched only on `sampleQueue`.
    private var recording = false
    private var clock: RecordingClock?
    private var url: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS = CMTime.invalid
    private var size = (width: 0, height: 0)

    override public init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    /// Switches to `device` and starts the camera, or stops it when nil.
    public func setDevice(_ device: AVCaptureDevice?) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            if let input {
                session.removeInput(input)
                self.input = nil
            }
            if let device, let newInput = try? AVCaptureDeviceInput(device: device), session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
                if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
                if session.canSetSessionPreset(.hd1920x1080) {
                    session.sessionPreset = .hd1920x1080
                } else if session.canSetSessionPreset(.hd1280x720) {
                    session.sessionPreset = .hd1280x720
                } else {
                    session.sessionPreset = .high
                }
            }
            session.commitConfiguration()
            if input != nil {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    public var isRunning: Bool { session.isRunning }

    public func startRecording(to url: URL, clock: RecordingClock) {
        sampleQueue.sync {
            try? FileManager.default.removeItem(at: url)
            self.url = url
            self.clock = clock
            writer = nil
            writerInput = nil
            firstPTS = nil
            lastPTS = .invalid
            recording = true
        }
    }

    /// Returns nil when the camera never delivered a frame.
    public func stopRecording() async -> CameraRecordingResult? {
        let (writer, input, first, last, size): (AVAssetWriter?, AVAssetWriterInput?, CMTime?, CMTime, (width: Int, height: Int)) = sampleQueue.sync {
            recording = false
            return (self.writer, writerInput, firstPTS, lastPTS, self.size)
        }
        guard let writer, let input, let first, last.isValid else { return nil }
        input.markAsFinished()
        writer.endSession(atSourceTime: last + CMTime(value: 1, timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return CameraRecordingResult(firstPTS: first, width: size.width, height: size.height)
    }

    public func cancelRecording() {
        sampleQueue.sync {
            recording = false
            if let writer, writer.status == .writing { writer.cancelWriting() }
            if let url { try? FileManager.default.removeItem(at: url) }
            writer = nil
        }
    }

    // MARK: - Samples

    public func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, let clock, let url, let offset = clock.offsetIfRunning(),
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }

        // Camera timestamps are on the session's clock; move them onto the
        // host clock that ScreenCaptureKit uses so the two files line up.
        var stamp = buffer.presentationTimeStamp
        if let sessionClock = session.synchronizationClock {
            stamp = CMSyncConvertTime(stamp, from: sessionClock, to: CMClockGetHostTimeClock())
        }
        let shift = (buffer.presentationTimeStamp - stamp) + offset
        let pts = stamp - offset

        if writer == nil {
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            let bitrate = Int(min(max(Double(width * height) * 30 * 0.1, 2_000_000), 12_000_000))
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: pts)
            self.writer = writer
            writerInput = input
            firstPTS = pts
            size = (width, height)
        }

        guard let writerInput, !lastPTS.isValid || pts > lastPTS, writerInput.isReadyForMoreMediaData,
              let sample = retimed(buffer, subtracting: shift) else { return }
        if writerInput.append(sample) { lastPTS = pts }
    }
}
