@preconcurrency import AVFoundation
import Foundation

/// The recorded files, opened once and reused for every rebuild.
public struct LoadedMedia: @unchecked Sendable {
    public let screenAsset: AVURLAsset
    public let screenVideo: AVAssetTrack
    public let screenAudio: [AVAssetTrack]
    /// The stretch of the recording each audio track covers.
    public let screenAudioRanges: [CMTimeRange]
    public let screenDuration: CMTime
    public let screenSize: CGSize
    public let cameraAsset: AVURLAsset?
    public let cameraVideo: AVAssetTrack?
    public let cameraDuration: CMTime
}

/// A ready-to-play (or ready-to-export) edit.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let timeMap: TimeMap
    public let renderSize: CGSize

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let audioTrackIDs: [(kind: AudioTrackKind, id: CMPersistentTrackID)]
    let screenSize: CGSize
    let fps: Int32
}

public enum BuildError: LocalizedError {
    case missingVideo
    case nothingToExport

    public var errorDescription: String? {
        switch self {
        case .missingVideo: return "The recording has no video track. The file may be damaged."
        case .nothingToExport: return "Everything has been cut. Restore a part of the recording first."
        }
    }
}

public enum CompositionBuilder {
    private static let timescale: CMTimeScale = 600

    public static func load(recording: Recording, directory: URL) async throws -> LoadedMedia {
        let screenAsset = AVURLAsset(url: directory.appendingPathComponent(recording.screen.file))
        guard let video = try await screenAsset.loadTracks(withMediaType: .video).first else { throw BuildError.missingVideo }
        let audio = try await screenAsset.loadTracks(withMediaType: .audio)
        var audioRanges: [CMTimeRange] = []
        for track in audio { audioRanges.append(try await track.load(.timeRange)) }
        let duration = try await screenAsset.load(.duration)
        let size = try await video.load(.naturalSize)

        var cameraAsset: AVURLAsset?
        var cameraVideo: AVAssetTrack?
        var cameraDuration = CMTime.zero
        if let camera = recording.camera {
            let asset = AVURLAsset(url: directory.appendingPathComponent(camera.file))
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                cameraAsset = asset
                cameraVideo = track
                cameraDuration = (try? await asset.load(.duration)) ?? .zero
            }
        }
        return LoadedMedia(screenAsset: screenAsset, screenVideo: video, screenAudio: audio, screenAudioRanges: audioRanges,
                           screenDuration: duration,
                           screenSize: size, cameraAsset: cameraAsset, cameraVideo: cameraVideo, cameraDuration: cameraDuration)
    }

    /// Canvas size in pixels. `longSide` nil keeps the recording's own resolution.
    public static func canvasSize(aspect: AspectPreset, source: CGSize, longSide: Int?) -> CGSize {
        let ratio = aspect.ratio ?? Double(source.width / max(source.height, 1))
        let sourceLong = Double(max(source.width, source.height))
        let long = min(Double(longSide ?? Int(sourceLong)), 3840)
        var w: Double, h: Double
        if ratio >= 1 {
            w = long
            h = long / ratio
        } else {
            h = long
            w = long * ratio
        }
        func even(_ v: Double) -> CGFloat { CGFloat(max(2, Int((v / 2).rounded()) * 2)) }
        return CGSize(width: even(w), height: even(h))
    }

    public static func build(media: LoadedMedia, recording: Recording, edit: EditState,
                             renderSize: CGSize, fps: Int32 = 30) throws -> BuiltComposition {
        let total = media.screenDuration.seconds
        let kept = edit.segments
            .map { TimeSpan(start: max(0, $0.start), end: min(total, $0.end)) }
            .filter { $0.duration > 0.01 }
        guard !kept.isEmpty else { throw BuildError.nothingToExport }
        let timeMap = TimeMap(segments: kept)

        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.missingVideo
        }
        var audioTracks: [(kind: AudioTrackKind, track: AVMutableCompositionTrack, source: AVAssetTrack, range: CMTimeRange)] = []
        for (index, source) in media.screenAudio.enumerated() {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let kind = index < recording.audioTracks.count ? recording.audioTracks[index] : .system
            audioTracks.append((kind, track, source, media.screenAudioRanges[index]))
        }
        var cameraTrack: AVMutableCompositionTrack?
        if media.cameraVideo != nil {
            cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

        var cursor = 0.0
        let cameraOffset = recording.camera?.offset ?? 0
        let cameraLength = media.cameraDuration.seconds
        for span in timeMap.segments {
            let range = CMTimeRange(start: time(span.start), end: time(span.end))
            try screenTrack.insertTimeRange(range, of: media.screenVideo, at: time(cursor))
            for audio in audioTracks {
                // Audio tracks can be a little shorter than the video.
                let clipped = range.intersection(audio.range)
                if clipped.duration.seconds > 0.01 {
                    let at = cursor + (clipped.start.seconds - span.start)
                    try? audio.track.insertTimeRange(clipped, of: audio.source, at: time(at))
                }
            }
            if let cameraTrack, let source = media.cameraVideo {
                // Camera time = screen time - offset.
                let start = max(span.start - cameraOffset, 0)
                let end = min(span.end - cameraOffset, cameraLength)
                if end - start > 0.02 {
                    let at = cursor + (start + cameraOffset - span.start)
                    try? cameraTrack.insertTimeRange(CMTimeRange(start: time(start), end: time(end)), of: source, at: time(at))
                }
            }
            cursor += span.duration
        }

        let built = BuiltComposition(
            composition: composition,
            videoComposition: AVMutableVideoComposition(),
            audioMix: AVMutableAudioMix(),
            timeMap: timeMap,
            renderSize: renderSize,
            screenTrackID: screenTrack.trackID,
            cameraTrackID: cameraTrack?.trackID,
            audioTrackIDs: audioTracks.map { ($0.kind, $0.track.trackID) },
            screenSize: media.screenSize,
            fps: fps
        )
        return restyled(built, edit: edit)
    }

    /// Re-applies look, zoom, camera and volume changes without touching the
    /// cut list. Cheap enough to run on every slider tick.
    public static func restyled(_ built: BuiltComposition, edit: EditState) -> BuiltComposition {
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = StudioCompositor.self
        video.renderSize = built.renderSize
        video.frameDuration = CMTime(value: 1, timescale: built.fps)
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        video.instructions = [
            StudioInstruction(
                timeRange: CMTimeRange(start: .zero, duration: built.composition.duration),
                screenTrackID: built.screenTrackID,
                cameraTrackID: built.cameraTrackID,
                edit: edit,
                timeMap: built.timeMap,
                screenSize: built.screenSize
            ),
        ]

        let mix = AVMutableAudioMix()
        mix.inputParameters = built.audioTrackIDs.map { entry in
            let params = AVMutableAudioMixInputParameters()
            params.trackID = entry.id
            params.setVolume(Float(entry.kind == .mic ? edit.micVolume : edit.systemVolume), at: .zero)
            return params
        }

        return BuiltComposition(composition: built.composition, videoComposition: video, audioMix: mix,
                                timeMap: built.timeMap, renderSize: built.renderSize, screenTrackID: built.screenTrackID,
                                cameraTrackID: built.cameraTrackID, audioTrackIDs: built.audioTrackIDs,
                                screenSize: built.screenSize, fps: built.fps)
    }
}
