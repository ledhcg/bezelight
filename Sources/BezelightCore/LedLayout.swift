import Foundation

/// Half-open rectangle of grid cells: x0..<x1, y0..<y1.
public struct CellRect: Equatable, Sendable {
    public var x0: Int, y0: Int, x1: Int, y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }
    public var width: Int { max(0, x1 - x0) }
    public var height: Int { max(0, y1 - y0) }
    public var area: Int { width * height }

    public func intersection(_ o: CellRect) -> CellRect {
        CellRect(x0: max(x0, o.x0), y0: max(y0, o.y0), x1: min(x1, o.x1), y1: min(y1, o.y1))
    }
}

/// Number of black cell rows/columns detected on each side (letterbox / pillarbox).
public struct CellInsets: Equatable, Sendable {
    public var left = 0, top = 0, right = 0, bottom = 0
    public static let zero = CellInsets()
    public init(left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    /// True when no side has more bars than `o` (i.e. content grew back).
    public func isNoLargerThan(_ o: CellInsets) -> Bool {
        left <= o.left && top <= o.top && right <= o.right && bottom <= o.bottom
    }
}

/// Physical LED positions around the screen, normalised to 0...1 (v = 0 is the top edge).
///
/// The strip is wired around the display: left (bottom to top), top (left to right),
/// right (top to bottom), bottom (right to left). Each LED samples the screen region it
/// physically sits in, instead of a one-dimensional left-to-right stretch.
public struct LedLayout: Sendable {
    public struct Point: Sendable, Equatable {
        public var u: Double
        public var v: Double
        public init(u: Double, v: Double) { self.u = u; self.v = v }
    }

    public let points: [Point]
    public var count: Int { points.count }
    public init(points: [Point]) { self.points = points }

    /// Positions of every LED for a kit, in wiring order.
    ///
    /// LEDs sit on the edges with the corners left empty (a corner has no LED on these kits), so a
    /// segment of `n` LEDs is spread over the `n + 2` grid cells of its edge. This matches how the
    /// vendor lays the LEDs out on a matrix, but with left and right as seen from the front.
    public static func build(kind: LayoutKind, zones: [Int], stripEdge: ScreenEdge = .bottom,
                             mirrored: Bool = false, reversed: Bool = false) -> LedLayout {
        func z(_ i: Int) -> Int { i < zones.count ? max(0, zones[i]) : 0 }
        var pts: [Point] = []

        // Edge cell k (1...n) of an edge that has n + 2 cells, as a 0...1 coordinate.
        func along(_ cell: Int, of cells: Int) -> Double { Double(cell) / Double(max(1, cells - 1)) }

        switch kind {
        case .perimeter4:
            let h = max(z(0), z(2)) + 2, w = max(z(1), z(3)) + 2
            for k in 0..<z(0) { pts.append(Point(u: 0, v: along(h - 2 - k, of: h))) }       // left, up
            for k in 0..<z(1) { pts.append(Point(u: along(1 + k, of: w), v: 0)) }            // top, right
            for k in 0..<z(2) { pts.append(Point(u: 1, v: along(1 + k, of: h))) }            // right, down
            for k in 0..<z(3) { pts.append(Point(u: along(w - 2 - k, of: w), v: 1)) }        // bottom, left
        case .perimeter3:
            let h = max(z(0), z(2)) + 1, w = z(1) + 2
            for k in 0..<z(0) { pts.append(Point(u: 0, v: along(h - 1 - k, of: h))) }        // left, up from the bottom row
            for k in 0..<z(1) { pts.append(Point(u: along(1 + k, of: w), v: 0)) }            // top, right
            for k in 0..<z(2) { pts.append(Point(u: 1, v: along(1 + k, of: h))) }            // right, down to the bottom row
        case .sides2:
            let h = max(z(0), z(1)) + 2
            for k in 0..<z(0) { pts.append(Point(u: 0, v: along(h - 2 - k, of: h))) }        // left, up
            for k in 0..<z(1) { pts.append(Point(u: 1, v: along(1 + k, of: h))) }            // right, down
        case .strip:
            let n = z(0)
            for k in 0..<n {
                let t = (Double(k) + 0.5) / Double(max(1, n))
                switch stripEdge {
                case .top: pts.append(Point(u: t, v: 0))
                case .bottom: pts.append(Point(u: t, v: 1))
                case .left: pts.append(Point(u: 0, v: 1 - t))
                case .right: pts.append(Point(u: 1, v: t))
                }
            }
        }
        if mirrored { pts = pts.map { Point(u: 1 - $0.u, v: $0.v) } }
        return LedLayout(points: reversed ? pts.reversed() : pts)
    }

    /// Sampling window per LED, in grid cells, inside `active`.
    /// Edge LEDs sample a band `depth` (fraction of the screen) deep from their edge and about
    /// 1.5 LED-pitches wide along it, so neighbouring LEDs overlap and the result is smooth.
    /// Corner LEDs sample the corner square.
    public func cellRects(gridW: Int, gridH: Int, depth: Double, active: CellRect) -> [CellRect] {
        let bounds = active.intersection(CellRect(x0: 0, y0: 0, x1: gridW, y1: gridH))
        guard bounds.area > 0 else { return [] }
        let aw = Double(bounds.width), ah = Double(bounds.height)
        let eps = 1e-6

        var nL = 0, nR = 0, nT = 0, nB = 0
        for p in points {
            if p.u <= eps { nL += 1 }
            if p.u >= 1 - eps { nR += 1 }
            if p.v <= eps { nT += 1 }
            if p.v >= 1 - eps { nB += 1 }
        }
        let pitchV = ah / Double(max(1, max(nL, nR)))
        let pitchH = aw / Double(max(1, max(nT, nB)))
        let halfV = max(1.0, pitchV * 0.75)
        let halfH = max(1.0, pitchH * 0.75)
        let d = max(0.03, min(0.5, depth))
        let bx = max(2, Int((d * aw).rounded()))
        let by = max(2, Int((d * ah).rounded()))

        return points.map { p in
            let onL = p.u <= eps, onR = p.u >= 1 - eps, onT = p.v <= eps, onB = p.v >= 1 - eps
            let cx = Double(bounds.x0) + p.u * aw
            let cy = Double(bounds.y0) + p.v * ah
            var x0: Int, x1: Int, y0: Int, y1: Int
            if onL { x0 = bounds.x0; x1 = bounds.x0 + bx }
            else if onR { x1 = bounds.x1; x0 = bounds.x1 - bx }
            else { x0 = Int((cx - halfH).rounded(.down)); x1 = Int((cx + halfH).rounded(.up)) }
            if onT { y0 = bounds.y0; y1 = bounds.y0 + by }
            else if onB { y1 = bounds.y1; y0 = bounds.y1 - by }
            else { y0 = Int((cy - halfV).rounded(.down)); y1 = Int((cy + halfV).rounded(.up)) }
            x0 = max(bounds.x0, x0); x1 = min(bounds.x1, max(x1, x0 + 1))
            y0 = max(bounds.y0, y0); y1 = min(bounds.y1, max(y1, y0 + 1))
            if x0 >= x1 { x0 = max(bounds.x0, x1 - 1) }
            if y0 >= y1 { y0 = max(bounds.y0, y1 - 1) }
            return CellRect(x0: x0, y0: y0, x1: x1, y1: y1)
        }
    }
}
