@preconcurrency import AVFoundation
import Foundation

public enum RecorderError: LocalizedError {
    case writer(String)
    case noFrames
    case notArmed

    public var errorDescription: String? {
        switch self {
        case .writer(let reason): return "The recording could not be written: \(reason)"
        case .noFrames: return "Nothing was captured. Check that Tasjeel has Screen Recording permission."
        case .notArmed: return "The recorder was not ready."
        }
    }
}

public struct ScreenRecordingResult: Sendable {
    public let firstPTS: CMTime
    public let endPTS: CMTime
    public let width: Int
    public let height: Int
    public let audioTracks: [AudioTrackKind]

    public var duration: Double { (endPTS - firstPTS).seconds }
}

/// Writes captured samples into one QuickTime file: a video track, then one
/// audio track per source (system sound, microphone) so the editor can balance
/// them separately.
///
/// It knows nothing about where samples come from, which keeps the delicate
/// parts (timestamps, pausing, starting and ending the file) testable without
/// a screen.
public final class CaptureWriter: @unchecked Sendable {
    public struct Config: Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var systemAudio: Bool
        public var microphone: Bool
        public var outputURL: URL

        public init(width: Int, height: Int, fps: Int, systemAudio: Bool, microphone: Bool, outputURL: URL) {
            self.width = width
            self.height = height
            self.fps = fps
            self.systemAudio = systemAudio
            self.microphone = microphone
            self.outputURL = outputURL
        }
    }

    private let config: Config
    private let clock: RecordingClock
    private let lock = NSLock()

    // Guarded by `lock`.
    private var writing = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var micFormat: AudioStreamBasicDescription?
    private var firstPTS: CMTime?
    private var lastVideoPTS = CMTime.invalid
    private var lastSystemPTS = CMTime.invalid
    private var lastMicPTS = CMTime.invalid
    private var failure: String?

    public init(config: Config, clock: RecordingClock) {
        self.config = config
        self.clock = clock
    }

    /// Opens the file. The first video frame appended afterwards becomes time zero.
    public func begin() throws {
        lock.lock()
        defer { lock.unlock() }
        // Preferred: encode to a fixed picture quality. If this Mac's encoder
        // cannot do that, fall back to a fixed data rate.
        var attempt = try makeWriter(video: qualityVideoSettings())
        if attempt == nil { attempt = try makeWriter(video: bitrateVideoSettings()) }
        guard let (writer, video, system, mic) = attempt else {
            throw RecorderError.writer("this Mac's video encoder refused the recording settings")
        }
        videoInput = video
        systemInput = system
        micInput = mic
        self.writer = writer
        writing = true
    }

    private typealias Inputs = (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?, AVAssetWriterInput?)

    /// Opens the file with the given video settings. Returns nil when the
    /// encoder does not accept them, so the caller can try others.
    private func makeWriter(video settings: [String: Any]) throws -> Inputs? {
        try? FileManager.default.removeItem(at: config.outputURL)
        let writer = try AVAssetWriter(outputURL: config.outputURL, fileType: .mov)
        // Flush to disk every few seconds: a crash or power cut then costs
        // seconds of the recording, not all of it.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return nil }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return nil }
        writer.add(video)

        var system: AVAssetWriterInput?
        if config.systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            system = input
        }
        var mic: AVAssetWriterInput?
        if config.microphone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: microphoneSettings())
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            mic = input
        }

        guard writer.startWriting() else {
            writer.cancelWriting()
            return nil
        }
        return (writer, video, system, mic)
    }

    // MARK: - Samples

    /// Appends one complete video frame.
    public func appendVideo(_ buffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard writing, let writer, let videoInput, let offset = clock.offsetIfRunning() else { return }
        let pts = buffer.presentationTimeStamp - offset
        if firstPTS == nil {
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
        }
        // A frame captured just before a pause can arrive just after it and
        // would land before the last one written; drop it.
        guard !lastVideoPTS.isValid || pts > lastVideoPTS else { return }
        guard videoInput.isReadyForMoreMediaData, let sample = retimed(buffer, subtracting: offset) else { return }
        if videoInput.append(sample) {
            lastVideoPTS = pts
        } else if failure == nil {
            failure = writer.error?.localizedDescription
        }
    }

    public func appendSystemAudio(_ buffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        appendAudio(buffer, to: systemInput, last: &lastSystemPTS)
    }

    /// Before `begin()`, microphone samples only teach the writer the
    /// microphone's format; after it, they are recorded.
    public func appendMicrophone(_ buffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if micFormat == nil, let description = buffer.formatDescription,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            micFormat = asbd
        }
        appendAudio(buffer, to: micInput, last: &lastMicPTS)
    }

    private func appendAudio(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?, last: inout CMTime) {
        // Audio waits for the first video frame, which defines time zero.
        guard writing, let input, let first = firstPTS, let offset = clock.offsetIfRunning() else { return }
        let pts = buffer.presentationTimeStamp - offset
        guard pts >= first, !last.isValid || pts > last else { return }
        guard input.isReadyForMoreMediaData, let sample = retimed(buffer, subtracting: offset) else { return }
        if input.append(sample) { last = pts }
    }

    // MARK: - Ending

    public func finish() async throws -> ScreenRecordingResult {
        let (writer, first, end): (AVAssetWriter?, CMTime?, CMTime) = lock.withLock {
            writing = false
            var end = clock.adjustedNow()
            if lastVideoPTS.isValid {
                end = max(end, lastVideoPTS + CMTime(value: 1, timescale: CMTimeScale(config.fps)))
            }
            return (self.writer, firstPTS, end)
        }
        guard let writer else { throw RecorderError.notArmed }
        guard let first else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: config.outputURL)
            throw RecorderError.noFrames
        }

        videoInput?.markAsFinished()
        systemInput?.markAsFinished()
        micInput?.markAsFinished()
        // Ending the session at "now" keeps the last frame on screen for as
        // long as the screen stayed still before stop was pressed.
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? failure ?? "unknown error")
        }

        var tracks: [AudioTrackKind] = []
        if systemInput != nil { tracks.append(.system) }
        if micInput != nil { tracks.append(.mic) }
        return ScreenRecordingResult(firstPTS: first, endPTS: end, width: config.width, height: config.height, audioTracks: tracks)
    }

    /// Stops and deletes whatever was written.
    public func cancel() {
        let writer: AVAssetWriter? = lock.withLock {
            writing = false
            return self.writer
        }
        if let writer, writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: config.outputURL)
    }

    // MARK: - Settings

    /// How close to the original each frame is kept, 0 ... 1. Measured on a
    /// Retina screen full of text, 0.8 is indistinguishable from the screen
    /// on every frame, including the first one after the picture changes.
    private static let captureQuality = 0.8

    /// HEVC at a fixed quality. A screen is still most of the time and then
    /// changes all at once; a fixed data rate spreads its budget evenly, so
    /// the first frames after every change come out soft and sharpen over the
    /// next half second. A fixed quality spends what each frame needs: still
    /// screens cost almost nothing and changes are sharp immediately.
    private func qualityVideoSettings() -> [String: Any] {
        settings(codec: .hevc, compression: [AVVideoQualityKey: Self.captureQuality])
    }

    private func bitrateVideoSettings() -> [String: Any] {
        // H.264 tops out around 4K; bigger displays (5K, 6K) need HEVC.
        let hevc = config.width > 4096 || config.height > 2304
        let pixels = Double(config.width * config.height)
        let bitrate = Int(min(max(pixels * Double(config.fps) * 0.2, 6_000_000), 80_000_000))
        var compression: [String: Any] = [AVVideoAverageBitRateKey: hevc ? bitrate * 2 / 3 : bitrate]
        if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return settings(codec: hevc ? .hevc : .h264, compression: compression)
    }

    private func settings(codec: AVVideoCodecType, compression: [String: Any]) -> [String: Any] {
        var compression = compression
        compression[AVVideoExpectedSourceFrameRateKey] = config.fps
        compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2.0
        compression[AVVideoAllowFrameReorderingKey] = false
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// Encodes the microphone at the rate and channel count it actually
    /// delivers (AirPods are 24 kHz mono, a MacBook is 48 kHz), so nothing has
    /// to be resampled on the way to disk.
    private func microphoneSettings() -> [String: Any] {
        let supported: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        var rate = 48000.0
        var channels = 1
        if let format = micFormat {
            if supported.contains(format.mSampleRate) { rate = format.mSampleRate }
            channels = min(max(Int(format.mChannelsPerFrame), 1), 2)
        }
        return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
    }
}
