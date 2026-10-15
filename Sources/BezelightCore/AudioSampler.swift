import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Audio energy 0...1 per band, already auto-gain-normalised.
public struct AudioLevel: Sendable {
    public var bass: Double   // music mode 1
    public var mid: Double    // music mode 2
    public var treble: Double // music mode 3
    public var peak: Double   // music mode 4
    /// Log-spaced bands from ~40 Hz to ~14 kHz, each 0...1 (empty when there is no audio).
    public var spectrum: [Float]
    public init(bass: Double, mid: Double, treble: Double, peak: Double, spectrum: [Float] = []) {
        self.bass = bass; self.mid = mid; self.treble = treble; self.peak = peak; self.spectrum = spectrum
    }
    public static let silence = AudioLevel(bass: 0, mid: 0, treble: 0, peak: 0)
    public static let bandCount = 16
}

/// Streaming spectrum analyser for system audio (fed by ScreenCaptureKit, so no microphone
/// permission is involved). 1024-point real FFT with a Hann window, 50% hop (~10 ms at 48 kHz),
/// three bands, per-band automatic gain control and a fast-attack / quick-release envelope.
public final class AudioAnalyzer: @unchecked Sendable {
    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private var window: [Float]
    private var pending: [Float] = []
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var mags: [Float]
    private var scaledMags: [Float]
    private var raw: [Float] = [0, 0, 0, 0]
    private var outv: [Double] = [0, 0, 0, 0]
    private var bandAGC = [Float](repeating: 0.002, count: AudioLevel.bandCount)
    private var bandEnv = [Float](repeating: 0, count: AudioLevel.bandCount)
    private var agc: [Float] = [0.01, 0.01, 0.01, 0.01] // bass, mid, treble, peak
    private var env: [Float] = [0, 0, 0, 0]
    private let lock = NSLock()
    private var current = AudioLevel.silence
    private var lastFed = Date.distantPast

    public init() {
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
        scaledMags = [Float](repeating: 0, count: n / 2)
        pending.reserveCapacity(n * 4)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Latest levels. Decays to silence if no audio arrives (e.g. nothing is playing).
    public var level: AudioLevel {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastFed) > 0.5 ? .silence : current
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(keepingCapacity: true)
        env = [0, 0, 0, 0]
        bandEnv = [Float](repeating: 0, count: AudioLevel.bandCount)
        current = .silence
    }

    /// Feed mono Float32 samples.
    public func feed(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        lastFed = Date()
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        let binHz = Float(sampleRate) / Float(n)
        while pending.count >= n {
            process(binHz: binHz)
            pending.removeFirst(n / 2)
        }
    }

    private func bandRMS(_ lo: Float, _ hi: Float, binHz: Float) -> Float {
        let a = max(1, Int(lo / binHz)), b = min(n / 2 - 1, max(a + 1, Int(hi / binHz)))
        var sum: Float = 0
        for i in a..<b { sum += mags[i] }
        return sqrtf(sum / Float(b - a))
    }

    private func process(binHz: Float) {
        // window
        pending.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }
        var rms: Float = 0
        windowed.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length(n)) }

        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }
        // squared magnitude -> normalised power (full-scale sine ~ 1)
        var scale = 1 / Float(n * n)
        vDSP_vsmul(mags, 1, &scale, &scaledMags, 1, vDSP_Length(n / 2))
        swap(&mags, &scaledMags)

        raw[0] = bandRMS(30, 250, binHz: binHz)
        raw[1] = bandRMS(250, 2000, binHz: binHz)
        raw[2] = bandRMS(2000, 12000, binHz: binHz)
        raw[3] = rms
        for i in 0..<4 {
            // AGC: follow the loudest recent level (~6 s decay), never amplify silence.
            agc[i] = max(raw[i], agc[i] * 0.9985, i == 3 ? 0.01 : 0.002)
            let norm = min(1, raw[i] / agc[i])
            let shaped = powf(norm, 1.6)               // make hits pop out of the average
            env[i] = max(shaped, env[i] * 0.82)        // instant attack, ~50 ms release
            outv[i] = Double(env[i])
        }
        // 16 log-spaced bands for the equalizer, each with its own gain control.
        let lo: Float = 40, hi: Float = min(14_000, binHz * Float(n / 2 - 2))
        let ratio = powf(hi / lo, 1 / Float(AudioLevel.bandCount))
        var edge = lo
        for b in 0..<AudioLevel.bandCount {
            let next = edge * ratio
            let r = bandRMS(edge, next, binHz: binHz)
            bandAGC[b] = max(r, bandAGC[b] * 0.9985, 0.002)
            let shaped = powf(min(1, r / bandAGC[b]), 1.5)
            bandEnv[b] = max(shaped, bandEnv[b] * 0.80)
            edge = next
        }
        current = AudioLevel(bass: outv[0], mid: outv[1], treble: outv[2], peak: outv[3], spectrum: bandEnv)
    }
}

/// Deterministic signal for tests / demos.
public final class MockAudioSampler: @unchecked Sendable {
    private var phase = 0.0
    public init() {}
    public func level() -> AudioLevel {
        phase += 0.2
        let v = (sin(phase) + 1) / 2
        return AudioLevel(bass: v, mid: 1 - v, treble: v * v, peak: min(1, v * 1.5))
    }
}
