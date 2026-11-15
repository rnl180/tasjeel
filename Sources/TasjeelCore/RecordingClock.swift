import CoreMedia
import Foundation

/// Shared by the screen and camera writers so they agree on time, and so a
/// pause removes exactly the same stretch from both files.
///
/// Every sample arrives stamped with the host clock. While running, a sample's
/// file time is `stamp - offset`; each pause grows `offset` by its length.
public final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset = CMTime.zero
    private var pausedAt: CMTime?

    public init() {}

    public static func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pausedAt != nil
    }

    public func pause() {
        lock.lock()
        defer { lock.unlock() }
        if pausedAt == nil { pausedAt = Self.hostNow() }
    }

    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        if let p = pausedAt {
            offset = offset + (Self.hostNow() - p)
            pausedAt = nil
        }
    }

    /// The amount to subtract from a sample's timestamp, or nil while paused
    /// (samples that arrive during a pause are dropped).
    public func offsetIfRunning() -> CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return pausedAt == nil ? offset : nil
    }

    /// "Now" on the recording's own timeline. Stands still during a pause.
    public func adjustedNow() -> CMTime {
        lock.lock()
        defer { lock.unlock() }
        return (pausedAt ?? Self.hostNow()) - offset
    }
}

/// Returns a copy of the sample buffer with every timestamp moved earlier by `offset`.
func retimed(_ buffer: CMSampleBuffer, subtracting offset: CMTime) -> CMSampleBuffer? {
    if offset == .zero { return buffer }
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    guard count > 0 else { return nil }
    var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
    for i in 0 ..< count {
        timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
        if timing[i].decodeTimeStamp.isValid {
            timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset
        }
    }
    var out: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                          sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out)
    return out
}
