import UIKit
import PencilKit

/// Recognizes a hand-drawn stroke as a simple shape and rebuilds it as a clean stroke with the
/// same ink (tool, color, width). Used for "hold to snap": draw a shape and keep the pencil still
/// for two seconds — it snaps while the pencil is still down.
///
/// Recognized shapes: straight line (snapping to horizontal / vertical / 45°), open polylines of
/// 2–3 segments (angles, zigzags), circles and ellipses (including rotated ones), triangles,
/// rectangles (including rotated ones), pentagons and hexagons.
public enum ShapeSnapper {

    public enum Shape: Equatable {
        case line
        case polyline(segments: Int)
        case circle
        case ellipse
        case triangle
        case rectangle
        case polygon(sides: Int)
    }

    /// Strokes smaller than this (in drawing points) are left alone — they're probably handwriting.
    static let minimumShapeSize: CGFloat = 20

    /// Returns a cleaned-up replacement for a finished `stroke`, or nil if it doesn't look like a shape.
    public static func snappedStroke(from stroke: PKStroke) -> (stroke: PKStroke, shape: Shape)? {
        let samples = Array(stroke.path.interpolatedPoints(by: .distance(3)))
        let points = samples.map { $0.location.applying(stroke.transform) }
        guard points.count >= 6, let (outline, shape) = recognize(points) else { return nil }
        // Reuse the pen's typical width/pressure so the shape matches the original line weight.
        let reference = samples.sorted { $0.size.width < $1.size.width }[samples.count / 2]
        return (makeStroke(outline: outline, ink: stroke.ink, reference: reference, creationDate: stroke.path.creationDate), shape)
    }
    
    /// Builds a shape from raw points of a stroke that's still being drawn (in drawing coordinates),
    /// using the current pen. Returns nil if the points don't look like a shape.
    public static func snappedStroke(fromPoints points: [CGPoint], tool: PKInkingTool) -> (stroke: PKStroke, shape: Shape)? {
        guard points.count >= 6, let (outline, shape) = recognize(points) else { return nil }
        let reference = PKStrokePoint(
            location: .zero,
            timeOffset: 0,
            size: CGSize(width: tool.width, height: tool.width),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
        let ink = PKInk(tool.inkType, color: tool.color)
        return (makeStroke(outline: outline, ink: ink, reference: reference, creationDate: Date()), shape)
    }
    
    // MARK: - Recognition

    /// Returns the ideal outline (a list of points joined by straight segments) and its shape.
    static func recognize(_ points: [CGPoint]) -> ([CGPoint], Shape)? {
        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard max(box.width, box.height) >= minimumShapeSize else { return nil }

        let length = pathLength(points)
        guard length > 0 else { return nil }
        let endGap = distance(points.first!, points.last!)
        let isClosed = endGap < max(14, 0.2 * diagonal)

        if !isClosed {
            // Straight line: no point strays far from the line joining the two ends.
            let maxDeviation = points.map { perpendicularDistance($0, lineStart: points.first!, lineEnd: points.last!) }.max() ?? 0
            if maxDeviation <= max(4, 0.07 * endGap) {
                return (snappedLine(from: points.first!, to: points.last!), .line)
            }
            // Angle / zigzag made of a few straight segments.
            let vertices = rdp(points, epsilon: max(4, 0.05 * diagonal))
            if (3...4).contains(vertices.count) {
                return (vertices, .polyline(segments: vertices.count - 1))
            }
            return nil
        }

        // A rounded polygon can pass for an ellipse and vice versa, so fit both and keep
        // whichever outline the stroke actually hugs more closely.
        let vertices = closedPolygonVertices(points, diagonal: diagonal)
        let polygonFits = (3...6).contains(vertices.count)
        let polygonError = polygonFits ? meanDistance(of: points, toOutline: vertices + [vertices[0]]) : .infinity
        // Many-sided polygons are easily confused with wobbly circles; make them win clearly.
        let polygonBias: CGFloat = vertices.count >= 5 ? 1.6 : 1.0
        if let ellipse = fitEllipse(points),
           meanDistance(of: points, toOutline: ellipse.0) <= polygonError * polygonBias {
            return ellipse
        }

        switch vertices.count {
        case 3:
            return (vertices + [vertices[0]], .triangle)
        case 4:
            if let rect = rectangle(from: vertices) {
                return (rect + [rect[0]], .rectangle)
            }
            return (vertices + [vertices[0]], .polygon(sides: 4))
        case 5...6:
            return (vertices + [vertices[0]], .polygon(sides: vertices.count))
        default:
            return nil
        }
    }

    /// Straight line, nudged to exactly horizontal / vertical / diagonal when it's close.
    private static func snappedLine(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let nearest = (angle / step).rounded() * step
        let snapTolerance = 6 * CGFloat.pi / 180
        let finalAngle = abs(angle - nearest) < snapTolerance ? nearest : angle
        return [start, CGPoint(x: start.x + cos(finalAngle) * length, y: start.y + sin(finalAngle) * length)]
    }

    /// Fits an ellipse along the stroke's principal axes; accepts it if the points hug the outline.
    private static func fitEllipse(_ points: [CGPoint]) -> ([CGPoint], Shape)? {
        let n = CGFloat(points.count)
        let mean = CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in points {
            let dx = p.x - mean.x, dy = p.y - mean.y
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)

        // Express points in the ellipse's own axes.
        let local = points.map { rotate($0, around: mean, by: -theta) }
        let localBox = boundingBox(local)
        let a = localBox.width / 2, b = localBox.height / 2
        guard a > 4, b > 4 else { return nil }
        let center = CGPoint(x: localBox.midX, y: localBox.midY)

        let deviation = local.map { p -> CGFloat in
            let r = sqrt(pow((p.x - center.x) / a, 2) + pow((p.y - center.y) / b, 2))
            return abs(r - 1)
        }.reduce(0, +) / n
        guard deviation < 0.1 else { return nil }

        let isCircle = min(a, b) / max(a, b) > 0.85
        let rx = isCircle ? (a + b) / 2 : a
        let ry = isCircle ? (a + b) / 2 : b
        let worldCenter = rotate(center, around: mean, by: theta)

        let count = 96
        var outline: [CGPoint] = []
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count) * 2 * .pi
            let p = CGPoint(x: worldCenter.x + rx * cos(t), y: worldCenter.y + ry * sin(t))
            outline.append(isCircle ? p : rotate(p, around: worldCenter, by: theta))
        }
        return (outline, isCircle ? .circle : .ellipse)
    }

    /// Corner points of a closed stroke, with near-straight "corners" removed.
    private static func closedPolygonVertices(_ points: [CGPoint], diagonal: CGFloat) -> [CGPoint] {
        // Split the loop at the point farthest from the start so both halves simplify well.
        let start = points[0]
        let farIndex = points.indices.max { distance(points[$0], start) < distance(points[$1], start) } ?? 0
        guard farIndex > 0, farIndex < points.count - 1 else { return [] }
        let epsilon = max(4, 0.07 * diagonal)
        let firstHalf = rdp(Array(points[0...farIndex]), epsilon: epsilon)
        let secondHalf = rdp(Array(points[farIndex...]) + [start], epsilon: epsilon)
        var vertices = Array(firstHalf.dropLast()) + Array(secondHalf.dropLast())

        // Merge vertices that sit almost on top of each other.
        let mergeDistance = 0.12 * diagonal
        var merged: [CGPoint] = []
        for v in vertices where merged.last.map({ distance($0, v) > mergeDistance }) ?? true {
            merged.append(v)
        }
        if merged.count > 2, distance(merged.first!, merged.last!) <= mergeDistance {
            merged.removeLast()
        }
        vertices = merged

        // Drop vertices where the outline barely turns (e.g. the stroke's start point mid-edge).
        var changed = true
        while changed && vertices.count > 3 {
            changed = false
            for i in vertices.indices {
                let prev = vertices[(i - 1 + vertices.count) % vertices.count]
                let next = vertices[(i + 1) % vertices.count]
                if turnAngle(prev, vertices[i], next) < 25 * CGFloat.pi / 180 {
                    vertices.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return vertices
    }

    /// If four corners are roughly right angles, returns a true rectangle (axis-aligned when close).
    private static func rectangle(from v: [CGPoint]) -> [CGPoint]? {
        for i in 0..<4 {
            let interior = CGFloat.pi - turnAngle(v[(i + 3) % 4], v[i], v[(i + 1) % 4])
            if abs(interior - .pi / 2) > 20 * CGFloat.pi / 180 { return nil }
        }
        // Orientation from the longest edge, folded into (-45°, 45°].
        var bestEdge = 0
        for i in 1..<4 where distance(v[i], v[(i + 1) % 4]) > distance(v[bestEdge], v[(bestEdge + 1) % 4]) {
            bestEdge = i
        }
        let a = v[bestEdge], b = v[(bestEdge + 1) % 4]
        var phi = atan2(b.y - a.y, b.x - a.x)
        let quarter = CGFloat.pi / 2
        phi -= (phi / quarter).rounded() * quarter
        if abs(phi) < 8 * CGFloat.pi / 180 { phi = 0 }

        let center = CGPoint(x: v.map(\.x).reduce(0, +) / 4, y: v.map(\.y).reduce(0, +) / 4)
        let local = boundingBox(v.map { rotate($0, around: center, by: -phi) })
        let corners = [
            CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.minY),
            CGPoint(x: local.maxX, y: local.maxY), CGPoint(x: local.minX, y: local.maxY)
        ]
        return corners.map { rotate($0, around: center, by: phi) }
    }

    // MARK: - Stroke Construction

    private static func makeStroke(outline: [CGPoint], ink: PKInk, reference: PKStrokePoint, creationDate: Date) -> PKStroke {
        var controlPoints: [PKStrokePoint] = []
        var time: TimeInterval = 0

        func add(_ location: CGPoint) {
            controlPoints.append(PKStrokePoint(
                location: location,
                timeOffset: time,
                size: reference.size,
                opacity: reference.opacity,
                force: reference.force,
                azimuth: reference.azimuth,
                altitude: reference.altitude
            ))
            time += 0.004
        }

        let isSmoothCurve = outline.count > 20 // circles & ellipses are already densely sampled
        for (i, point) in outline.enumerated() {
            if i > 0 && !isSmoothCurve {
                // Fill straight segments densely so the spline stays straight between corners.
                let prev = outline[i - 1]
                let steps = max(1, Int(distance(prev, point) / 4))
                for s in 1..<steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    add(CGPoint(x: prev.x + (point.x - prev.x) * t, y: prev.y + (point.y - prev.y) * t))
                }
            }
            add(point)
            if !isSmoothCurve {
                // Repeat corners so they stay sharp instead of being rounded off.
                add(point)
                add(point)
            }
        }

        let path = PKStrokePath(controlPoints: controlPoints, creationDate: creationDate)
        return PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
    }

    // MARK: - Geometry Helpers

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func rotate(_ p: CGPoint, around c: CGPoint, by angle: CGFloat) -> CGPoint {
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(angle) - dy * sin(angle), y: c.y + dx * sin(angle) + dy * cos(angle))
    }

    /// How sharply the path turns at `b` (0 = straight on, π = full reversal).
    private static func turnAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let v1 = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)
        let m1 = hypot(v1.dx, v1.dy), m2 = hypot(v2.dx, v2.dy)
        guard m1 > 0, m2 > 0 else { return 0 }
        let cosine = max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / (m1 * m2)))
        return acos(cosine)
    }

    /// Ramer–Douglas–Peucker simplification: keeps only points that matter to the outline.
    private static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(points[i], lineStart: first, lineEnd: last)
            if d > maxDistance {
                maxDistance = d
                index = i
            }
        }
        guard maxDistance > epsilon else { return [first, last] }
        let left = rdp(Array(points[0...index]), epsilon: epsilon)
        let right = rdp(Array(points[index...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    /// Average distance from each point to the nearest segment of an outline.
    private static func meanDistance(of points: [CGPoint], toOutline outline: [CGPoint]) -> CGFloat {
        guard outline.count >= 2, !points.isEmpty else { return .infinity }
        let segments = Array(zip(outline, outline.dropFirst()))
        let total = points.reduce(CGFloat(0)) { sum, p in
            sum + (segments.map { segmentDistance(p, $0.0, $0.1) }.min() ?? 0)
        }
        return total / CGFloat(points.count)
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func perpendicularDistance(_ p: CGPoint, lineStart a: CGPoint, lineEnd b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return distance(p, a) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
    }
}

/// Watches pencil (or finger) touches on a canvas without interfering with drawing. Records the
/// stroke's points as it's drawn, and once the pencil has been held still for `holdDuration`
/// (while still touching the screen) asks `onHold` to snap it.
final class ShapeHoldGestureRecognizer: UIGestureRecognizer {
    /// Called after the pencil has been still for `holdDuration`, with the stroke's points so far
    /// (in the view's bounds coordinates). Return true if the stroke was snapped.
    var onHold: (([CGPoint]) -> Bool)?
    /// Fired when the stroke ends; `true` if it was held long enough but hasn't been snapped yet
    /// (fallback in case the hold timer couldn't fire).
    var onStrokeEnded: ((Bool) -> Void)?
    var onStrokeBegan: (() -> Void)?

    static let holdDuration: TimeInterval = 2.0
    /// Movement (screen points) that still counts as holding still.
    static let stillTolerance: CGFloat = 6

    private var trackedTouch: UITouch?
    private var points: [CGPoint] = []
    private var anchor: CGPoint = .zero
    private var anchorTimestamp: TimeInterval = 0
    private var holdTimer: Timer?
    private var didSnap = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        didSnap = false
        points = [touch.location(in: view)]
        onStrokeBegan?()
        resetAnchor(to: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch), !didSnap else { return }
        // Coalesced touches give the full-resolution path between frames.
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            points.append(sample.location(in: view))
        }
        let location = touch.location(in: view)
        if hypot(location.x - anchor.x, location.y - anchor.y) > Self.stillTolerance {
            resetAnchor(to: touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let heldButNotSnapped = !didSnap && touch.timestamp - anchorTimestamp >= Self.holdDuration
        finishTracking()
        onStrokeEnded?(heldButNotSnapped)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        finishTracking()
        onStrokeEnded?(false)
        state = .failed
    }

    override func reset() {
        super.reset()
        finishTracking()
    }

    private func resetAnchor(to touch: UITouch) {
        anchor = touch.location(in: view)
        anchorTimestamp = touch.timestamp
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            guard let self = self, self.trackedTouch != nil, !self.didSnap else { return }
            self.didSnap = self.onHold?(self.points) ?? false
        }
        // .common so it fires while UIKit is in touch-tracking run loop mode (pencil still down).
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func finishTracking() {
        holdTimer?.invalidate()
        holdTimer = nil
        trackedTouch = nil
        points = []
    }
}
