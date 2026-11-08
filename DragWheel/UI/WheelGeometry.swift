import SwiftUI

enum WheelRing: Hashable { case primary, secondary }

struct SliceRef: Hashable {
    let ring: WheelRing
    let index: Int
}

/// Pure geometry for the wheel (top-left origin, angles clockwise from 12 o'clock). Unit-tested.
struct WheelGeometry {
    var scale: CGFloat = 1

    var hubRadius: CGFloat { 50 * scale }
    var innerRadius: CGFloat { 58 * scale }
    var outerRadius: CGFloat { 150 * scale }
    var secondaryInner: CGFloat { outerRadius + 8 * scale }
    var secondaryOuter: CGFloat { secondaryInner + 64 * scale }
    private var padding: CGFloat { 26 * scale }
    private let gap: Double = 3 * .pi / 180

    /// Side of the (square) panel hosting the wheel.
    func panelSide(expanded: Bool) -> CGFloat {
        2 * ((expanded ? secondaryOuter : outerRadius) + padding)
    }

    /// Radius of the outermost visible ring.
    func reach(expanded: Bool) -> CGFloat { expanded ? secondaryOuter : outerRadius }

    func radii(of ring: WheelRing) -> (inner: CGFloat, outer: CGFloat) {
        ring == .primary ? (innerRadius, outerRadius) : (secondaryInner, secondaryOuter)
    }

    /// Slice angular range; slice 0 is centred at 12 o'clock.
    func angles(index: Int, count: Int) -> (start: Double, end: Double) {
        let span = 2 * Double.pi / Double(max(count, 1))
        let g = count > 1 ? gap : 0
        let start = Double(index) * span - span / 2 + g / 2
        let end = Double(index + 1) * span - span / 2 - g / 2
        return (start, end)
    }

    static func point(radius: CGFloat, angle: Double, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }

    func slicePath(ring: WheelRing, index: Int, count: Int, center: CGPoint) -> Path {
        let (inner, outer) = radii(of: ring)
        let (start, end) = angles(index: index, count: count)
        let steps = max(2, Int(((end - start) * 180 / .pi).rounded(.up)))
        var path = Path()
        for step in 0...steps {
            let angle = start + (end - start) * Double(step) / Double(steps)
            let p = Self.point(radius: outer, angle: angle, center: center)
            step == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        for step in stride(from: steps, through: 0, by: -1) {
            let angle = start + (end - start) * Double(step) / Double(steps)
            path.addLine(to: Self.point(radius: inner, angle: angle, center: center))
        }
        path.closeSubpath()
        return path
    }

    func labelCenter(ring: WheelRing, index: Int, count: Int, center: CGPoint) -> CGPoint {
        let (inner, outer) = radii(of: ring)
        let (start, end) = angles(index: index, count: count)
        return Self.point(radius: (inner + outer) / 2, angle: (start + end) / 2, center: center)
    }

    /// Which slice is under `point`? Gaps between slices count as the nearest slice (forgiving drops).
    func hit(point: CGPoint, center: CGPoint, primaryCount: Int, secondaryCount: Int, expanded: Bool) -> SliceRef? {
        let dx = point.x - center.x, dy = point.y - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        var theta = atan2(Double(dx), Double(-dy))
        if theta < 0 { theta += 2 * .pi }

        func index(count: Int) -> Int {
            let span = 2 * Double.pi / Double(count)
            return Int(floor((theta + span / 2) / span)) % count
        }
        if primaryCount > 0, r >= innerRadius, r <= outerRadius {
            return SliceRef(ring: .primary, index: index(count: primaryCount))
        }
        if expanded, secondaryCount > 0, r >= secondaryInner, r <= secondaryOuter {
            return SliceRef(ring: .secondary, index: index(count: secondaryCount))
        }
        return nil
    }

    func zone(distance: CGFloat, expanded: Bool) -> WheelZone {
        if distance > reach(expanded: expanded) + 6 * scale { return .outside }
        return distance < innerRadius ? .hub : .ring
    }
}
