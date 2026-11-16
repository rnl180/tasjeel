import AVFoundation
import CoreImage
import XCTest
@testable import TasjeelCore

/// Exercises the real pipeline on generated footage: build an edit, render
/// frames, export a file and read it back.
final class RenderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tasjeel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Frame renderer

    func testPlainFrameIsJustTheScreen() throws {
        let renderer = FrameRenderer()
        let canvas = CGSize(width: 640, height: 400)
        let screen = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: canvas))
        let image = renderer.render(screen: screen, camera: nil, sourceTime: 0, canvas: canvas, screenSize: canvas,
                                    edit: EditState(duration: 10))
        let centre = try pixel(of: image, at: CGPoint(x: 320, y: 200), renderer: renderer)
        let corner = try pixel(of: image, at: CGPoint(x: 2, y: 2), renderer: renderer)
        XCTAssertGreaterThan(centre.r, 240)
        XCTAssertLessThan(centre.g, 15)
        XCTAssertGreaterThan(corner.r, 240, "with no padding the screen fills the canvas")
    }

    func testStudioLookFramesTheScreenAndPlacesTheCamera() throws {
        let renderer = FrameRenderer()
        let canvas = CGSize(width: 1280, height: 720)
        let screenSize = CGSize(width: 1280, height: 800)
        let screen = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: screenSize))
        let camera = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))

        var edit = EditState(duration: 10)
        edit.background = .color("#0000FF")
        edit.padding = 0.1
        edit.cornerRadius = 0.05
        edit.camera = CameraStyle(visible: true, shape: .circle, size: 0.3, corner: .bottomRight, mirrored: true)

        let layout = RenderLayout(canvas: canvas, screenSize: screenSize, edit: edit, hasCamera: true)
        XCTAssertEqual(layout.screenRect.width / layout.screenRect.height, 1.6, accuracy: 0.01, "screen keeps its shape")
        XCTAssertGreaterThanOrEqual(layout.screenRect.minY, 71)

        let image = renderer.render(screen: screen, camera: camera, sourceTime: 0, canvas: canvas, screenSize: screenSize, edit: edit)
        let centre = try pixel(of: image, at: CGPoint(x: 640, y: 360), renderer: renderer)
        XCTAssertGreaterThan(centre.r, 240, "screen in the middle")

        let edge = try pixel(of: image, at: CGPoint(x: 6, y: 714), renderer: renderer)
        XCTAssertGreaterThan(edge.b, 240, "wallpaper around it")
        XCTAssertLessThan(edge.r, 15)

        // The screen's own corner is rounded away, so the wallpaper (darkened
        // a little by the drop shadow) shows through instead of red.
        let rounded = try pixel(of: image, at: CGPoint(x: layout.screenRect.minX + 2, y: layout.screenRect.maxY - 2), renderer: renderer)
        XCTAssertLessThan(rounded.r, 60)

        let cam = try XCTUnwrap(layout.cameraRect)
        let face = try pixel(of: image, at: CGPoint(x: cam.midX, y: cam.midY), renderer: renderer)
        XCTAssertGreaterThan(face.g, 240, "camera overlay bottom-right")
        XCTAssertGreaterThan(cam.midX, 900)
        XCTAssertLessThan(cam.midY, 300, "Core Image y runs upwards, so bottom means small y")
    }

    func testZoomMagnifiesAroundTheFocusPoint() throws {
        let renderer = FrameRenderer()
        let canvas = CGSize(width: 800, height: 600)
        // Left half red, right half green.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 600))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 400, y: 0, width: 400, height: 600))
        let screen = green.composited(over: red)

        var edit = EditState(duration: 10)
        // Focus far right: once zoomed 2x, the right (green) half fills the frame.
        edit.zooms = [ZoomSegment(start: 0, end: 10, scale: 2, x: 1, y: 0.5)]

        let before = renderer.render(screen: screen, camera: nil, sourceTime: 0, canvas: canvas, screenSize: canvas, edit: edit)
        XCTAssertGreaterThan(try pixel(of: before, at: CGPoint(x: 100, y: 300), renderer: renderer).r, 240)

        let zoomed = renderer.render(screen: screen, camera: nil, sourceTime: 5, canvas: canvas, screenSize: canvas, edit: edit)
        let left = try pixel(of: zoomed, at: CGPoint(x: 100, y: 300), renderer: renderer)
        XCTAssertGreaterThan(left.g, 240, "left side now shows what was on the right")
        XCTAssertLessThan(left.r, 15)
    }

    // MARK: - Composition and export

    func testCutsCameraAndExportProduceAPlayableFile() async throws {
        // 4 s screen recording with an audio track, plus a camera that started 0.5 s late.
        try await makeMovie(at: directory.appendingPathComponent(ProjectStore.screenName), size: CGSize(width: 640, height: 400),
                            seconds: 4, color: (220, 40, 40), audio: true)
        try await makeMovie(at: directory.appendingPathComponent(ProjectStore.cameraName), size: CGSize(width: 320, height: 240),
                            seconds: 3, color: (40, 220, 40), audio: false)

        var recording = Recording(
            // A whole-second date: project files store dates to the second.
            title: "Test", createdAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 4, sourceName: "Test",
            screen: MediaInfo(file: ProjectStore.screenName, width: 640, height: 400),
            camera: CameraInfo(file: ProjectStore.cameraName, width: 320, height: 240, offset: 0.5),
            audioTracks: [.mic]
        )
        // Cut out the middle: keep 0-1 and 2.5-4, i.e. 2.5 s.
        recording.edit.segments = [TimeSpan(start: 0, end: 1), TimeSpan(start: 2.5, end: 4)]
        recording.edit.applyStudioLook()
        recording.edit.aspect = .wide
        recording.edit.zooms = [ZoomSegment(start: 2.6, end: 3.8, scale: 2, x: 0.3, y: 0.3)]
        recording.edit.micVolume = 0.5

        let store = ProjectStore(root: directory.deletingLastPathComponent())
        try store.save(recording, in: directory)
        let reloaded = try XCTUnwrap(store.loadAll().first { $0.id == recording.id })
        XCTAssertEqual(reloaded.recording, recording, "project file round-trips")

        let media = try await CompositionBuilder.load(recording: recording, directory: directory)
        XCTAssertEqual(media.screenSize, CGSize(width: 640, height: 400))
        XCTAssertNotNil(media.cameraVideo)

        let size = CompositionBuilder.canvasSize(aspect: recording.edit.aspect, source: media.screenSize, longSide: 640)
        XCTAssertEqual(size, CGSize(width: 640, height: 360))
        let built = try CompositionBuilder.build(media: media, recording: recording, edit: recording.edit, renderSize: size)
        XCTAssertEqual(built.composition.duration.seconds, 2.5, accuracy: 0.05)
        XCTAssertEqual(built.timeMap.source(fromComposition: 1.5), 3.0, accuracy: 1e-6)

        let output = directory.appendingPathComponent("export.mp4")
        let progress = ProgressBox()
        try await Exporter.export(built, to: output, codec: .h264) { progress.set($0) }
        XCTAssertEqual(progress.value, 1, accuracy: 1e-9)

        let exported = AVURLAsset(url: output)
        let duration = try await exported.load(.duration).seconds
        XCTAssertEqual(duration, 2.5, accuracy: 0.15)
        let videoTracks = try await exported.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let exportedSize = try await video.load(.naturalSize)
        XCTAssertEqual(exportedSize, CGSize(width: 640, height: 360))
        let audioTracks = try await exported.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)

        // Look at real exported frames. At 0.2 s the camera has not started
        // yet (it began 0.5 s in); at 0.8 s it is there, bottom-right.
        let generator = AVAssetImageGenerator(asset: exported)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let later = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image

        // CGImage rows run top-down, so "bottom-right" is a large y here.
        let layout = RenderLayout(canvas: size, screenSize: media.screenSize, edit: recording.edit, hasCamera: true)
        let cam = try XCTUnwrap(layout.cameraRect)
        let camPoint = CGPoint(x: cam.midX, y: size.height - cam.midY)

        let centre = rgb(of: later, at: CGPoint(x: 320, y: 180))
        XCTAssertGreaterThan(centre.r, 170, "screen recording in the middle")
        XCTAssertLessThan(centre.g, 90)

        let face = rgb(of: later, at: camPoint)
        XCTAssertGreaterThan(face.g, 170, "camera composited over the screen")
        XCTAssertLessThan(face.r, 90)

        // That spot sits over the wallpaper's warm corner, so without the
        // camera it is clearly not camera-green.
        let noFace = rgb(of: early, at: camPoint)
        XCTAssertGreaterThan(noFace.r, 120, "camera absent before it started recording")

        let wallpaper = rgb(of: later, at: CGPoint(x: 4, y: 4))
        let difference = abs(wallpaper.r - centre.r) + abs(wallpaper.g - centre.g) + abs(wallpaper.b - centre.b)
        XCTAssertGreaterThan(difference, 60, "padding shows the wallpaper, not the screen")
    }

    func testEverythingCutIsRejected() async throws {
        try await makeMovie(at: directory.appendingPathComponent(ProjectStore.screenName), size: CGSize(width: 320, height: 200),
                            seconds: 1, color: (10, 10, 200), audio: false)
        var recording = Recording(title: "Empty", duration: 1, sourceName: "Test",
                                  screen: MediaInfo(file: ProjectStore.screenName, width: 320, height: 200))
        recording.edit.segments = []
        let media = try await CompositionBuilder.load(recording: recording, directory: directory)
        XCTAssertThrowsError(try CompositionBuilder.build(media: media, recording: recording, edit: recording.edit,
                                                          renderSize: CGSize(width: 320, height: 200)))
    }

    /// A dark grey screen must come out of the editor the same dark grey.
    /// (Rendering into the wrong Rec. 709 colour space once brightened every
    /// dark colour by a third, which made exports look washed out.)
    func testExportKeepsTheRecordingsColours() async throws {
        let source = directory.appendingPathComponent(ProjectStore.screenName)
        try await makeMovie(at: source, size: CGSize(width: 640, height: 400), seconds: 1, color: (60, 64, 70), audio: false)
        let recording = Recording(title: "Colour", duration: 1, sourceName: "Test",
                                  screen: MediaInfo(file: ProjectStore.screenName, width: 640, height: 400))
        let media = try await CompositionBuilder.load(recording: recording, directory: directory)
        let size = CompositionBuilder.canvasSize(aspect: .source, source: media.screenSize, longSide: nil)
        XCTAssertEqual(size, CGSize(width: 640, height: 400), "full size by default")
        let built = try CompositionBuilder.build(media: media, recording: recording, edit: recording.edit, renderSize: size)
        let output = directory.appendingPathComponent("colour.mp4")
        try await Exporter.export(built, to: output, codec: .h264) { _ in }

        func middle(of url: URL) async throws -> (r: Int, g: Int, b: Int) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            return rgb(of: image, at: CGPoint(x: 320, y: 200))
        }
        let before = try await middle(of: source)
        let after = try await middle(of: output)
        XCTAssertLessThanOrEqual(abs(before.r - after.r), 3, "red \(before.r) became \(after.r)")
        XCTAssertLessThanOrEqual(abs(before.g - after.g), 3, "green \(before.g) became \(after.g)")
        XCTAssertLessThanOrEqual(abs(before.b - after.b), 3, "blue \(before.b) became \(after.b)")
    }

    /// Fine detail (think small text) has to survive the renderer: untouched
    /// at full size, and still clearly there when the picture is shrunk.
    func testFineDetailStaysSharp() throws {
        // Black and white stripes, 4 px wide.
        let width = 640, height = 400
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width where (x / 4) % 2 == 0 {
                let i = (y * width + x) * 4
                bytes[i] = 0
                bytes[i + 1] = 0
                bytes[i + 2] = 0
            }
        }
        let screen = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let renderer = FrameRenderer()
        var edit = EditState(duration: 1)
        edit.applyPlainLook()

        // Full size: every pixel passes straight through.
        let full = renderer.render(screen: screen, camera: nil, sourceTime: 0, canvas: CGSize(width: width, height: height),
                                   screenSize: CGSize(width: width, height: height), edit: edit)
        XCTAssertLessThan(try pixel(of: full, at: CGPoint(x: 1, y: 200), renderer: renderer).r, 6)
        XCTAssertGreaterThan(try pixel(of: full, at: CGPoint(x: 5, y: 200), renderer: renderer).r, 249)
        XCTAssertLessThan(try pixel(of: full, at: CGPoint(x: 3, y: 200), renderer: renderer).r, 6, "no bleed at a stripe's edge")

        // Half size: the stripes are 2 px wide and must still be black and white.
        let half = renderer.render(screen: screen, camera: nil, sourceTime: 0, canvas: CGSize(width: width / 2, height: height / 2),
                                   screenSize: CGSize(width: width, height: height), edit: edit)
        let dark = try pixel(of: half, at: CGPoint(x: 0, y: 100), renderer: renderer).r
        let light = try pixel(of: half, at: CGPoint(x: 2, y: 100), renderer: renderer).r
        XCTAssertGreaterThan(light - dark, 200, "stripes keep their contrast when shrunk (\(dark) vs \(light))")
    }

    // MARK: - Helpers

    private func pixel(of image: CIImage, at point: CGPoint, renderer: FrameRenderer) throws -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        renderer.context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func rgb(of image: CGImage, at point: CGPoint) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so that the wanted pixel lands on the 1x1 context.
        ctx.draw(image, in: CGRect(x: -point.x, y: -(CGFloat(image.height) - 1 - point.y),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// Writes a solid-colour H.264 movie, optionally with a quiet tone.
    private func makeMovie(at url: URL, size: CGSize, seconds: Double, color: (UInt8, UInt8, UInt8), audio: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        // Real-time mode stops the writer holding one track back while it
        // waits for the other, since the tracks are written one after another.
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        var audioInput: AVAssetWriterInput?
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        for frame in 0 ..< Int(seconds * Double(fps)) {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for x in 0 ..< Int(size.width) {
                let p = base + x * 4
                p[0] = color.2
                p[1] = color.1
                p[2] = color.0
                p[3] = 255
            }
            for y in 1 ..< Int(size.height) { memcpy(base + y * rowBytes, base, Int(size.width) * 4) }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !video.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        video.markAsFinished()

        if let audioInput {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let chunk = 4800
            for index in 0 ..< Int(seconds * 10) {
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
                pcm.frameLength = AVAudioFrameCount(chunk)
                let samples = pcm.floatChannelData![0]
                for i in 0 ..< chunk { samples[i] = Float(sin(Double(index * chunk + i) * 2 * .pi * 440 / 48000)) * 0.1 }
                let sample = try sampleBuffer(from: pcm, at: CMTime(value: CMTimeValue(index * chunk), timescale: 48000))
                var waited = 0
                while !audioInput.isReadyForMoreMediaData, waited < 500 {
                    try await Task.sleep(nanoseconds: 2_000_000)
                    waited += 1
                }
                XCTAssertTrue(audioInput.append(sample), writer.error?.localizedDescription ?? "audio append failed")
            }
            audioInput.markAsFinished()
        }

        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private func sampleBuffer(from pcm: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                             refcon: nil, formatDescription: pcm.format.formatDescription, sampleCount: CMItemCount(pcm.frameLength),
                             sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &sample)
        let buffer = try XCTUnwrap(sample)
        CMSampleBufferSetDataReady(buffer)
        CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
                                                       blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                       bufferList: pcm.audioBufferList)
        return buffer
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0

    var value: Double {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ v: Double) {
        lock.lock()
        stored = v
        lock.unlock()
    }
}
