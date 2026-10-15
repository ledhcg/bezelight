import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import AppKit

public enum CaptureError: Error, LocalizedError {
    case noDisplay
    /// The user has not granted (or has revoked) Screen & System Audio Recording.
    case permissionDenied
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found"
        case .permissionDenied: return "Screen & System Audio Recording permission is required"
        case .other(let m): return m
        }
    }

    /// ScreenCaptureKit reports a declined permission as SCStreamError.userDeclined (-3801).
    static func wrap(_ error: Error) -> CaptureError {
        if let e = error as? CaptureError { return e }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue { return .permissionDenied }
        return .other(ns.localizedDescription)
    }
}

public struct DisplayInfo: Identifiable, Sendable, Equatable {
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
}

/// One ScreenCaptureKit stream for both ambient colour (video) and music (system audio).
///
/// Why this is the cheap way to do it:
/// - The compositor/GPU downscales the display to a tiny 64x36 BGRA grid *before* we see it,
///   so the app never touches a full-resolution frame (the old CGDisplayCreateImage path
///   copied tens of MB per sample).
/// - SCK only delivers a frame when screen content changed; a static desktop costs ~0 CPU.
/// - System audio comes from the same stream, so Music modes need no microphone permission.
/// - The handler only copies 9 KB; all colour maths runs later on the pipeline's own cadence.
public final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public static let gridW = 64
    public static let gridH = 36
    public static let rowBytes = gridW * 4

    private let lock = NSLock()
    private var grid = [UInt8](repeating: 0, count: gridW * gridH * 4)
    private var generation: UInt64 = 0
    private var hasFrame = false
    private var running = false
    private var wantsVideo = false
    private var _lastError: String?
    /// Bumped by `stop()`; a `start()` that finds it changed after its awaits was cancelled.
    private var epoch = 0
    private var stream: SCStream?
    private let audioAnalyzer = AudioAnalyzer()
    private let videoQueue = DispatchQueue(label: "bezelight.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "bezelight.capture.audio", qos: .userInteractive)

    /// Whether this run has already let ScreenCaptureKit show its permission prompt.
    private static let promptState = LockedValue(false)

    public override init() { super.init() }

    /// Connected displays, from AppKit. Unlike `SCShareableContent` this never asks for the screen
    /// recording permission, so it is safe to call at launch.
    @MainActor
    public static func availableDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return DisplayInfo(id: id, name: screen.localizedName, width: Int(screen.frame.width), height: Int(screen.frame.height))
        }
    }

    public var isRunning: Bool { lock.withLock { running } }
    public var lastError: String? { lock.withLock { _lastError } }
    public var audioLevel: AudioLevel { audioAnalyzer.level }

    /// `displayID` 0 (or a display that is no longer connected) means the main display.
    public func start(video: Bool, audio: Bool, displayID: UInt32 = 0) async throws {
        await stop()
        let ticket = lock.withLock { epoch }
        // Without the permission, ScreenCaptureKit shows the system prompt *every time it is asked*.
        // The pipeline retries every couple of seconds, so ask the system once per run and, after
        // that, only look (preflight never prompts). Granting takes effect after a relaunch anyway.
        if !CGPreflightScreenCaptureAccess() {
            let alreadyAsked = Self.promptState.withLock { asked -> Bool in let was = asked; asked = true; return was }
            if alreadyAsked { throw CaptureError.permissionDenied }
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw CaptureError.wrap(error) }
        let wanted = displayID == 0 ? CGMainDisplayID() : displayID
        guard let display = content.displays.first(where: { $0.displayID == wanted })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let cfg = SCStreamConfiguration()
        // Audio-only needs a stream anyway; make its video as small and rare as possible.
        cfg.width = video ? Self.gridW : 2
        cfg.height = video ? Self.gridH : 2
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = false
        cfg.queueDepth = 3
        cfg.captureResolution = .nominal
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: video ? 60 : 1)
        if audio {
            cfg.capturesAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 1
            cfg.excludesCurrentProcessAudio = true
        }
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                         configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if audio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
            lock.withLock { wantsVideo = video; _lastError = nil; hasFrame = false }
            audioAnalyzer.reset()
            try await s.startCapture()
        } catch { throw CaptureError.wrap(error) }
        // stop() ran while we were starting: it could not see this stream yet, so shut it down here.
        let cancelled = lock.withLock { () -> Bool in
            if epoch != ticket { return true }
            stream = s; running = true
            return false
        }
        if cancelled { try? await s.stopCapture() }
    }

    public func stop() async {
        let s = lock.withLock { () -> SCStream? in
            epoch &+= 1
            let s = stream; stream = nil; running = false; hasFrame = false; return s
        }
        if let s { try? await s.stopCapture() }
    }

    /// Copies the newest grid into `dst` (BGRA, `rowBytes` per row).
    /// Returns a counter that changes whenever a new frame arrived, or nil before the first one.
    public func copyGrid(into dst: inout [UInt8]) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard hasFrame else { return nil }
        dst.withUnsafeMutableBytes { d in grid.withUnsafeBytes { s in d.copyMemory(from: s) } }
        return generation
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen: handleVideo(sb)
        case .audio: handleAudio(sb)
        default: break
        }
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard lock.withLock({ wantsVideo }) else { return }
        // Skip idle/blank frames: only `.complete` frames carry fresh pixels.
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              CVPixelBufferGetWidth(pb) == Self.gridW, CVPixelBufferGetHeight(pb) == Self.gridH else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        lock.lock()
        grid.withUnsafeMutableBytes { d in
            for y in 0..<Self.gridH {
                memcpy(d.baseAddress! + y * Self.rowBytes, base + y * bpr, Self.rowBytes)
            }
        }
        generation &+= 1
        hasFrame = true
        lock.unlock()
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sb),
              let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return }
        var length = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &length,
                                          totalLengthOut: &total, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let ptr, length == total, asbd.mBitsPerChannel == 32 else { return }
        let floats = total / MemoryLayout<Float>.size
        ptr.withMemoryRebound(to: Float.self, capacity: floats) {
            audioAnalyzer.feed($0, count: floats, sampleRate: asbd.mSampleRate)
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { running = false; _lastError = error.localizedDescription }
    }
}


/// A value readable and writable from any thread.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}
