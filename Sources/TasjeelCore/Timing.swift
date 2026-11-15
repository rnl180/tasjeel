import Foundation

/// Maps between source time (the raw recording) and composition time (after
/// cuts). Cutting never moves anything in the source, so the editor timeline
/// can stay in source time while playback runs in composition time.
public struct TimeMap: Equatable, Sendable {
    public let segments: [TimeSpan]

    public init(segments: [TimeSpan]) {
        self.segments = segments.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
    }

    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    public func source(fromComposition t: Double) -> Double {
        var cursor = 0.0
        for s in segments {
            if t < cursor + s.duration { return s.start + max(0, t - cursor) }
            cursor += s.duration
        }
        return segments.last?.end ?? 0
    }

    /// Source times inside a cut snap forward to the next kept frame.
    public func composition(fromSource t: Double) -> Double {
        var cursor = 0.0
        for s in segments {
            if t < s.start { return cursor }
            if t < s.end { return cursor + (t - s.start) }
            cursor += s.duration
        }
        return cursor
    }

    /// The removed ranges between `0` and `total`.
    public func gaps(total: Double) -> [TimeSpan] {
        var result: [TimeSpan] = []
        var cursor = 0.0
        for s in segments {
            if s.start - cursor > 0.001 { result.append(TimeSpan(start: cursor, end: s.start)) }
            cursor = max(cursor, s.end)
        }
        if total - cursor > 0.001 { result.append(TimeSpan(start: cursor, end: total)) }
        return result
    }
}

// MARK: - Zoom

public struct ZoomState: Equatable, Sendable {
    public var scale: Double
    public var x: Double
    public var y: Double
    /// 0 when not zoomed, 1 when a zoom is fully in.
    public var progress: Double

    public static let identity = ZoomState(scale: 1, x: 0.5, y: 0.5, progress: 0)
}

public enum ZoomMath {
    /// Seconds a zoom takes to ease in or out.
    public static let ramp = 0.45

    static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func weight(_ z: ZoomSegment, at t: Double) -> Double {
        guard t > z.start, t < z.end else { return 0 }
        let r = min(ramp, max(0.05, (z.end - z.start) / 2))
        return min(smooth((t - z.start) / r), smooth((z.end - t) / r))
    }

    /// Blends every zoom active at `t`. Two zooms that overlap by exactly one
    /// ramp cross-fade, which reads as a pan from one focus point to the next.
    public static func state(at t: Double, zooms: [ZoomSegment]) -> ZoomState {
        var total = 0.0, scale = 0.0, x = 0.0, y = 0.0
        for z in zooms {
            let w = weight(z, at: t)
            guard w > 0 else { continue }
            total += w
            scale += w * (z.scale - 1)
            x += w * z.x
            y += w * z.y
        }
        guard total > 0.0001 else { return .identity }
        let norm = max(total, 1)
        return ZoomState(scale: 1 + scale / norm, x: x / total, y: y / total, progress: min(total, 1))
    }
}

public enum AutoZoom {
    /// Turns recorded clicks into zoom segments: zoom in just before a click,
    /// hold while clicks keep landing nearby, pan when they move elsewhere.
    public static func generate(clicks: [ClickEvent], duration: Double, scale: Double = 1.8,
                                lead: Double = 0.35, hold: Double = 1.8) -> [ZoomSegment] {
        let ramp = ZoomMath.ramp
        var result: [ZoomSegment] = []
        var current: ZoomSegment?

        func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

        for click in clicks.sorted(by: { $0.t < $1.t }) where click.t >= 0 && click.t <= duration {
            let start = max(0, click.t - lead)
            let end = min(duration, click.t + hold)
            guard var cur = current else {
                current = ZoomSegment(start: start, end: end, scale: scale, x: clamp01(click.x), y: clamp01(click.y))
                continue
            }
            if start <= cur.end {
                let distance = hypot(click.x - cur.x, click.y - cur.y)
                if distance < 0.18 {
                    cur.end = end
                    current = cur
                } else {
                    // Chain: overlap by one ramp so the two cross-fade into a pan.
                    cur.end = max(start + ramp, cur.start + 2 * ramp)
                    result.append(cur)
                    current = ZoomSegment(start: cur.end - ramp, end: max(end, cur.end + ramp), scale: scale,
                                          x: clamp01(click.x), y: clamp01(click.y))
                }
            } else {
                result.append(cur)
                current = ZoomSegment(start: start, end: end, scale: scale, x: clamp01(click.x), y: clamp01(click.y))
            }
        }
        if let cur = current { result.append(cur) }
        return result.filter { $0.end - $0.start > 0.2 }
    }
}
