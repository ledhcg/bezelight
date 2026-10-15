import Foundation
import BezelightCore

// bezelight-probe: stream test patterns to a controller without the GUI.
//
//   bezelight-probe <port> [baud] [ledCount]      stream a test pattern
//   bezelight-probe <port> identify               ask the controller which model it is
//   bezelight-probe <port> zones <l1,l2,..> [sec]  light each wired segment in its own colour
//
// Phase 1 shows dim red, phase 2 full white, both at 30 fps. If the LEDs die in phase 1 the
// problem is the stream or the port; if only phase 2 dies, the power supply is browning out.

let args = Array(CommandLine.arguments.dropFirst())
if args.count >= 2, args[1] == "identify" {
    let port = SerialPort(path: args[0])
    do { try port.open() } catch { print("open failed: \(error.localizedDescription)"); exit(1) }
    try? port.write(WireProtocol.handshake())
    var rx = Data()
    for _ in 0..<12 { usleep(60_000); rx.append(port.read(maxLen: 64)); if rx.contains(10) || rx.contains(13) { break } }
    print("raw reply: \(FrameLog.hex(rx, maxBytes: 64))")
    print("ascii    : \(String(decoding: rx.filter { $0 >= 32 && $0 < 127 }, as: UTF8.self))")
    port.close()
    exit(0)
}
if args.count >= 3, args[1] == "zones" {
    // each wired segment gets a colour; brightness ramps up along the wiring inside the segment
    let sizes = args[2].split(separator: ",").compactMap { Int($0) }
    let seconds = args.count > 3 ? Int(args[3]) ?? 60 : 60
    let palette: [LEDColor] = [.init(r: 255, g: 0, b: 0), .init(r: 0, g: 255, b: 0), .init(r: 0, g: 0, b: 255), .init(r: 255, g: 220, b: 0)]
    var colors: [LEDColor] = []
    for (z, n) in sizes.enumerated() {
        for i in 0..<n {
            let k = 0.12 + 0.88 * Double(i) / Double(max(1, n - 1))   // first LED dim, last LED bright
            let c = palette[z % palette.count]
            colors.append(LEDColor(r: UInt8(Double(c.r) * k), g: UInt8(Double(c.g) * k), b: UInt8(Double(c.b) * k)))
        }
    }
    let port = SerialPort(path: args[0])
    do { try port.open() } catch { print("open failed: \(error.localizedDescription)"); exit(1) }
    try? port.write(WireProtocol.handshake()); usleep(300_000)
    let frame = WireProtocol.encode(colors: colors)
    print("showing \(colors.count) LEDs, segments \(sizes) for \(seconds)s")
    let end = Date().addingTimeInterval(Double(seconds))
    while Date() < end { try? port.write(frame); _ = port.read(maxLen: 64); usleep(40_000) }
    try? port.write(WireProtocol.encode(colors: Array(repeating: .black, count: colors.count)))
    port.close(); print("done"); exit(0)
}
guard let portPath = args.first else {
    print("usage: bezelight-probe <port> [baud] [ledCount]")
    let found = SerialPort.listPorts()
    print(found.isEmpty ? "no USB serial ports found" : "found:\n  " + found.joined(separator: "\n  "))
    exit(64)
}
let baud = args.count > 1 ? Int(args[1]) ?? 115_200 : 115_200
let count = args.count > 2 ? Int(args[2]) ?? 96 : 96

let port = SerialPort(path: portPath, baudRate: baud)
do { try port.open() } catch {
    print("open failed: \(error.localizedDescription)")
    exit(1)
}
print("opened \(portPath) @ \(baud), \(count) LEDs")
try? port.write(WireProtocol.handshake())

func run(_ name: String, color: LEDColor, seconds: Int) {
    print("[\(name)] \(seconds)s: watch the LEDs")
    let frame = WireProtocol.encode(colors: Array(repeating: color, count: count))
    let end = Date().addingTimeInterval(Double(seconds))
    var sent = 0, errors = 0, lastReport = Date()
    while Date() < end {
        do { try port.write(frame); sent += 1 } catch { errors += 1 }
        _ = port.read(maxLen: 64) // drain ACKs
        if Date().timeIntervalSince(lastReport) >= 1 {
            print("  frames=\(sent) errors=\(errors)")
            lastReport = Date()
        }
        usleep(33_000)
    }
    print("[\(name)] done: frames=\(sent) errors=\(errors)")
}

run("dim red", color: LEDColor(r: 10, g: 0, b: 0), seconds: 8)
run("white", color: LEDColor(r: 255, g: 255, b: 255), seconds: 5)
try? port.write(WireProtocol.encode(colors: Array(repeating: .black, count: count)))
port.close()
print("finished")
