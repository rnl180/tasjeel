import AVFoundation
import XCTest
@testable import TasjeelCore

/// Feeds the writer the same kind of samples ScreenCaptureKit delivers (host
/// clock timestamps, in real time) and checks the file that comes out.
final class CaptureWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tasjeel-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPauseIsRemovedAndTracksAreSeparate() async throws {
        let url = directory.appendingPathComponent("screen.mov")
        let clock = RecordingClock()
        let writer = CaptureWriter(
            config: .init(width: 320, height: 200, fps: 30, systemAudio: true, microphone: true, outputURL: url),
            clock: clock
        )

        // As in the app: the microphone is heard before recording starts, so
        // the writer learns it is a 24 kHz mono device (AirPods-style).
        writer.appendMicrophone(try audio(rate: 24000, channels: 1, frames: 480))
        try writer.begin()

        // 0.6 s recording, 0.5 s paused (samples keep arriving and must be
        // dropped), 0.6 s recording.
        // Sleeps overshoot, so measure how long was really spent recording.
        var recorded = 0.0
        var mark = Date()
        try await feed(writer, seconds: 0.6)
        recorded += Date().timeIntervalSince(mark)
        clock.pause()
        try await feed(writer, seconds: 0.5)
        clock.resume()
        mark = Date()
        try await feed(writer, seconds: 0.6)
        recorded += Date().timeIntervalSince(mark)

        let result = try await writer.finish()
        XCTAssertEqual(result.audioTracks, [.system, .mic])
        XCTAssertEqual(result.duration, recorded, accuracy: 0.1, "the pause is not part of the recording")

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, recorded, accuracy: 0.1)

        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 200))

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 2, "system sound and microphone stay on separate tracks")
        var rates: [Double] = []
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            let asbd = try XCTUnwrap(descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
            rates.append(asbd.mSampleRate)
            let length = try await track.load(.timeRange).duration.seconds
            // The sound fed while recording: 36 ticks of a thirtieth of a
            // second. Not compared with the clock, because on a busy Mac the
            // sleeps between ticks run long while the sound stays the same.
            XCTAssertEqual(length, 1.2, accuracy: 0.2, "the sound fed during the pause is not in the file")
        }
        XCTAssertEqual(rates, [48000, 24000], "microphone keeps its own sample rate")

        // The file must also open in the editor pipeline.
        let recording = Recording(title: "Writer", duration: duration, sourceName: "Test",
                                  screen: MediaInfo(file: "screen.mov", width: 320, height: 200), audioTracks: result.audioTracks)
        let media = try await CompositionBuilder.load(recording: recording, directory: directory)
        let built = try CompositionBuilder.build(media: media, recording: recording, edit: recording.edit,
                                                 renderSize: CGSize(width: 320, height: 200))
        XCTAssertEqual(built.composition.duration.seconds, duration, accuracy: 0.05)
        XCTAssertEqual(built.audioMix.inputParameters.count, 2)
    }

    func testNoFramesIsAnError() async throws {
        let url = directory.appendingPathComponent("empty.mov")
        let writer = CaptureWriter(config: .init(width: 320, height: 200, fps: 30, systemAudio: false, microphone: false, outputURL: url),
                                   clock: RecordingClock())
        try writer.begin()
        do {
            _ = try await writer.finish()
            XCTFail("expected an error")
        } catch RecorderError.noFrames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no empty file left behind")
        }
    }

    func testStillScreenKeepsItsFullLength() async throws {
        // A screen that does not change delivers one frame and then nothing.
        let url = directory.appendingPathComponent("still.mov")
        let writer = CaptureWriter(config: .init(width: 320, height: 200, fps: 30, systemAudio: false, microphone: false, outputURL: url),
                                   clock: RecordingClock())
        try writer.begin()
        writer.appendVideo(try frame())
        try await Task.sleep(nanoseconds: 800_000_000)
        let result = try await writer.finish()
        XCTAssertEqual(result.duration, 0.8, accuracy: 0.15)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 0.8, accuracy: 0.15, "the last frame is held until stop")
    }

    // MARK: - Synthetic samples

    private func feed(_ writer: CaptureWriter, seconds: Double) async throws {
        let ticks = Int(seconds * 30)
        for _ in 0 ..< ticks {
            writer.appendVideo(try frame())
            writer.appendSystemAudio(try audio(rate: 48000, channels: 2, frames: 1600))
            writer.appendMicrophone(try audio(rate: 24000, channels: 1, frames: 800))
            try await Task.sleep(nanoseconds: 33_333_333)
        }
    }

    private func frame() throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0x80, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: RecordingClock.hostNow(),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try XCTUnwrap(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    private func audio(rate: Double, channels: UInt32, frames: Int) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0 ..< Int(channels) {
            let samples = pcm.floatChannelData![channel]
            for i in 0 ..< frames { samples[i] = Float(sin(Double(i) * 2 * .pi * 330 / rate)) * 0.1 }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: RecordingClock.hostNow(), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                             refcon: nil, formatDescription: format.formatDescription, sampleCount: CMItemCount(frames),
                             sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &sample)
        let buffer = try XCTUnwrap(sample)
        CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
                                                       blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                       bufferList: pcm.audioBufferList)
        return buffer
    }
}
