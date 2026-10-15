import Foundation

/// Per-LED colours produced from one screen frame (`zones.count == ledCount`).
public struct ScreenSample: Sendable {
    public var zones: [LEDColor]
    public init(zones: [LEDColor]) { self.zones = zones }
}

/// Turns the tiny captured grid (BGRA, e.g. 64x36) into one colour per LED.
///
/// - Averages in **linear light**, not gamma-encoded values: a region that is half white and
///   half black really emits ~50% *light*, which encodes to sRGB 188, not 128. Averaging the
///   encoded bytes (the common shortcut) makes mixed regions look too dark.
/// - Work per frame is ~96 LEDs x <60 cells; the heavy downscale already happened on the GPU.
public enum GridSampler {
    private static let toLinear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    private static let lutSize = 4096
    private static let toSRGB: [UInt8] = (0..<lutSize).map { i in
        let l = Float(i) / Float(lutSize - 1)
        let c = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (c * 255).rounded())))
    }

    /// `grid` is BGRA (`.byteOrder32Little`, as delivered by ScreenCaptureKit).
    public static func average(grid: UnsafePointer<UInt8>, rowBytes: Int, rects: [CellRect]) -> [LEDColor] {
        var out = [LEDColor]()
        out.reserveCapacity(rects.count)
        toLinear.withUnsafeBufferPointer { lin in
            toSRGB.withUnsafeBufferPointer { enc in
                for r in rects {
                    var sr: Float = 0, sg: Float = 0, sb: Float = 0
                    for y in r.y0..<r.y1 {
                        let row = grid + y * rowBytes
                        for x in r.x0..<r.x1 {
                            let p = row + x * 4
                            sb += lin[Int(p[0])]; sg += lin[Int(p[1])]; sr += lin[Int(p[2])]
                        }
                    }
                    let inv = 1 / Float(max(1, r.area))
                    func e(_ s: Float) -> UInt8 { enc[Int(min(1, s * inv) * Float(lutSize - 1) + 0.5)] }
                    out.append(LEDColor(r: e(sr), g: e(sg), b: e(sb)))
                }
            }
        }
        return out
    }

    /// Detects black bars (letterbox top/bottom, pillarbox left/right) on the grid.
    /// A line counts as black when at most ~3% of its cells exceed `threshold`
    /// (tolerates a stray logo/subtitle pixel). Never reports more than 1/3 of an axis.
    public static func blackBars(grid: UnsafePointer<UInt8>, rowBytes: Int, width: Int, height: Int,
                                 threshold: UInt8 = 14) -> CellInsets {
        func cellIsDark(_ x: Int, _ y: Int) -> Bool {
            let p = grid + y * rowBytes + x * 4
            return max(p[0], max(p[1], p[2])) <= threshold
        }
        func rowIsBlack(_ y: Int) -> Bool {
            var bright = 0
            for x in 0..<width where !cellIsDark(x, y) { bright += 1 }
            return bright <= max(1, width / 32)
        }
        func colIsBlack(_ x: Int) -> Bool {
            var bright = 0
            for y in 0..<height where !cellIsDark(x, y) { bright += 1 }
            return bright <= max(1, height / 32)
        }
        var ins = CellInsets()
        let maxY = height / 3, maxX = width / 3
        while ins.top < maxY, rowIsBlack(ins.top) { ins.top += 1 }
        while ins.bottom < maxY, rowIsBlack(height - 1 - ins.bottom) { ins.bottom += 1 }
        while ins.left < maxX, colIsBlack(ins.left) { ins.left += 1 }
        while ins.right < maxX, colIsBlack(width - 1 - ins.right) { ins.right += 1 }
        // An all-black screen is not a letterbox.
        if ins.top >= maxY && ins.bottom >= maxY { ins.top = 0; ins.bottom = 0 }
        if ins.left >= maxX && ins.right >= maxX { ins.left = 0; ins.right = 0 }
        return ins
    }
}
