import XCTest
@testable import TasjeelCore

final class TimingTests: XCTestCase {
    func testTimeMapRoundTrip() {
        // Keep 0-2 and 5-8 of a 10 second recording.
        let map = TimeMap(segments: [TimeSpan(start: 5, end: 8), TimeSpan(start: 0, end: 2)])
        XCTAssertEqual(map.duration, 5, accuracy: 1e-9)
        XCTAssertEqual(map.source(fromComposition: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(map.source(fromComposition: 2.5), 5.5, accuracy: 1e-9)
        XCTAssertEqual(map.composition(fromSource: 6), 3, accuracy: 1e-9)
        // Inside the cut: snaps to the start of the next kept part.
        XCTAssertEqual(map.composition(fromSource: 3.5), 2, accuracy: 1e-9)
        XCTAssertEqual(map.composition(fromSource: 9.5), 5, accuracy: 1e-9)
    }

    func testGaps() {
        let map = TimeMap(segments: [TimeSpan(start: 1, end: 2), TimeSpan(start: 5, end: 8)])
        XCTAssertEqual(map.gaps(total: 10), [TimeSpan(start: 0, end: 1), TimeSpan(start: 2, end: 5), TimeSpan(start: 8, end: 10)])
        XCTAssertEqual(TimeMap(segments: [TimeSpan(start: 0, end: 10)]).gaps(total: 10), [])
    }

    func testZoomEasesInHoldsAndEasesOut() {
        let zoom = ZoomSegment(start: 2, end: 6, scale: 2, x: 0.25, y: 0.75)
        XCTAssertEqual(ZoomMath.state(at: 1, zooms: [zoom]), .identity)
        XCTAssertEqual(ZoomMath.state(at: 7, zooms: [zoom]), .identity)

        let held = ZoomMath.state(at: 4, zooms: [zoom])
        XCTAssertEqual(held.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(held.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(held.progress, 1, accuracy: 1e-9)

        let easing = ZoomMath.state(at: 2 + ZoomMath.ramp / 2, zooms: [zoom])
        XCTAssertEqual(easing.scale, 1.5, accuracy: 1e-6)
    }

    func testChainedZoomsPanWithoutZoomingOut() {
        let a = ZoomSegment(start: 0, end: 3, scale: 2, x: 0.2, y: 0.2)
        let b = ZoomSegment(start: 3 - ZoomMath.ramp, end: 6, scale: 2, x: 0.8, y: 0.8)
        for step in 0 ... 10 {
            let t = (3 - ZoomMath.ramp) + ZoomMath.ramp * Double(step) / 10
            let s = ZoomMath.state(at: t, zooms: [a, b])
            if step > 0, step < 10 {
                XCTAssertEqual(s.scale, 2, accuracy: 1e-6, "scale dipped while panning at \(t)")
                XCTAssertGreaterThan(s.x, 0.2 - 1e-9)
                XCTAssertLessThan(s.x, 0.8 + 1e-9)
            }
        }
    }

    func testAutoZoomGroupsNearbyClicksAndChainsDistantOnes() {
        let clicks = [
            ClickEvent(t: 1.0, x: 0.2, y: 0.2),
            ClickEvent(t: 1.8, x: 0.22, y: 0.21), // same spot, soon after: extends
            ClickEvent(t: 2.6, x: 0.8, y: 0.7), // elsewhere, soon after: chains
            ClickEvent(t: 20, x: 0.5, y: 0.5), // much later: separate
        ]
        let zooms = AutoZoom.generate(clicks: clicks, duration: 30)
        XCTAssertEqual(zooms.count, 3)
        XCTAssertEqual(zooms[1].start, zooms[0].end - ZoomMath.ramp, accuracy: 1e-9)
        XCTAssertEqual(zooms[1].x, 0.8, accuracy: 1e-9)
        XCTAssertGreaterThan(zooms[2].start, zooms[1].end)
        XCTAssertTrue(zooms.allSatisfy { $0.start >= 0 && $0.end <= 30 && $0.end > $0.start })
    }

    func testEditStateDecodesOlderFiles() throws {
        let json = #"{"segments":[{"start":0,"end":4}]}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        XCTAssertEqual(edit.keptDuration, 4, accuracy: 1e-9)
        XCTAssertEqual(edit.camera.shape, .circle)
        XCTAssertEqual(edit.micVolume, 1)
    }

    func testCanvasSize() {
        let source = CGSize(width: 3024, height: 1964)
        XCTAssertEqual(CompositionBuilder.canvasSize(aspect: .source, source: source, longSide: nil), source)
        XCTAssertEqual(CompositionBuilder.canvasSize(aspect: .wide, source: source, longSide: 1920), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(CompositionBuilder.canvasSize(aspect: .vertical, source: source, longSide: 1920), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(CompositionBuilder.canvasSize(aspect: .square, source: source, longSide: 1080), CGSize(width: 1080, height: 1080))
    }
}
