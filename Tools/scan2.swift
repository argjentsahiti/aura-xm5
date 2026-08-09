import Foundation
import IOBluetooth

// Broad sweep of Sony V2 GET opcodes to locate the remaining WH-1000XM5 feature
// tables — auto power-off, Speak-to-Chat, touch/mic behaviour, multipoint.
//
// Aura must not be running: only one RFCOMM control channel exists.

// Discovered by name so this works on any paired Sony headset — no hardcoded
// hardware address. Override with the first CLI argument if you have several.
let nameHints = ["WH-1000XM5", "WH-1000XM4", "WH-1000XM3", "WF-1000XM5"]
let nameOverride: String? = CommandLine.arguments.dropFirst().first
let outPath = NSString(string: "~/sony_scan2.txt").expandingTildeInPath

var report = ""
func emit(_ s: String) {
    report += s + "\n"
    try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func matches(_ name: String?) -> Bool {
    guard let name else { return false }
    if let nameOverride { return name.contains(nameOverride) }
    return nameHints.contains { name.contains($0) }
}

let SOF: UInt8 = 0x3E, EOFB: UInt8 = 0x3C, ESC: UInt8 = 0x3D
let DATA_MDR: UInt8 = 0x0C, DATA_ACK: UInt8 = 0x01

func pkt(_ d: UInt8, _ s: UInt8, _ p: [UInt8]) -> Data {
    var inner: [UInt8] = [d, s]
    let n = UInt32(p.count)
    inner += [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    inner += p
    inner.append(inner.reduce(UInt8(0)) { $0 &+ $1 })
    var out: [UInt8] = [SOF]
    for b in inner { if b == SOF || b == EOFB || b == ESC { out += [ESC, b & 0xEF] } else { out.append(b) } }
    out.append(EOFB)
    return Data(out)
}

struct F { let t: UInt8; let p: [UInt8]; let s: UInt8 }

func frames(_ buf: inout [UInt8]) -> [F] {
    var fs: [F] = []
    while let s = buf.firstIndex(of: SOF) {
        guard let e = buf[(s + 1)...].firstIndex(of: EOFB) else { break }
        let raw = Array(buf[(s + 1)..<e]); buf.removeSubrange(0...e)
        var inner: [UInt8] = []; var i = 0
        while i < raw.count {
            if raw[i] == ESC, i + 1 < raw.count { inner.append(raw[i + 1] | 0x10); i += 2 } else { inner.append(raw[i]); i += 1 }
        }
        guard inner.count >= 7 else { continue }
        let l = (Int(inner[2]) << 24) | (Int(inner[3]) << 16) | (Int(inner[4]) << 8) | Int(inner[5])
        guard inner.count >= 7 + l, inner.prefix(6 + l).reduce(UInt8(0), &+) == inner[6 + l] else { continue }
        fs.append(F(t: inner[0], p: Array(inner[6..<(6 + l)]), s: inner[1]))
    }
    return fs
}

final class Link: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var ch: IOBluetoothRFCOMMChannel?
    var rx: [UInt8] = []; var got: [F] = []; var open = false; var seq: UInt8 = 0
    func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status e: IOReturn) { open = (e == kIOReturnSuccess) }
    func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length l: Int) {
        rx += [UInt8](Data(bytes: p, count: l))
        for f in frames(&rx) where f.t != DATA_ACK { got.append(f); w(pkt(DATA_ACK, 1 &- f.s, [])) }
    }
    func w(_ d: Data) {
        guard let c = ch else { return }
        var b = [UInt8](d)
        _ = b.withUnsafeMutableBufferPointer { p in c.writeSync(p.baseAddress!, length: UInt16(p.count)) }
    }
    func pump(_ s: TimeInterval) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func send(_ p: [UInt8], _ wait: TimeInterval = 0.28) -> [F] {
        got.removeAll(); w(pkt(DATA_MDR, seq, p)); seq = 1 &- seq; pump(wait); return got
    }
}

guard let ds = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
      let dev = ds.first(where: { matches($0.name) }) else {
    emit("not paired"); exit(1)
}
let link = Link()
var c: IOBluetoothRFCOMMChannel?
guard dev.openRFCOMMChannelAsync(&c, withChannelID: 9, delegate: link) == kIOReturnSuccess else {
    emit("open failed — is Aura running?"); exit(1)
}
link.ch = c; link.pump(3)
guard link.open else { emit("channel did not open"); exit(1) }

emit("WH-1000XM5 capability sweep — \(Date())\n")
link.send([0x00, 0x00])

// Capability list, decoded into (function, subtype) pairs.
emit("--- supported functions (06 00) ---")
if let cap = link.send([0x06, 0x00], 0.8).first(where: { $0.p.first == 0x07 })?.p, cap.count > 3 {
    let count = Int(cap[2])
    var pairs: [String] = []
    var i = 3
    while i + 1 < cap.count {
        pairs.append("\(String(format: "%02X", cap[i]))/\(String(format: "%02X", cap[i+1]))")
        i += 2
    }
    emit("  count=\(count)")
    emit("  " + pairs.joined(separator: "  "))
}

// Full GET sweep. Sony's pattern is GET = SET-2 = RET-1, with the low nibble 6.
emit("\n--- GET sweep: opcode/type -> reply ---")
let ops: [UInt8] = [0x06, 0x16, 0x26, 0x36, 0x46, 0x56, 0x66, 0x76,
                    0x86, 0x96, 0xA6, 0xB6, 0xC6, 0xD6, 0xE6, 0xF6]
for op in ops {
    var hits: [String] = []
    for t in UInt8(0x00)...UInt8(0x2C) {
        for f in link.send([op, t]) where !f.p.isEmpty {
            // Skip echoes of unrelated notifications.
            guard f.p.count > 1, f.p[0] == op &+ 1 else { continue }
            hits.append("    type \(String(format: "%02X", t)) -> \(hex(f.p))")
        }
    }
    if !hits.isEmpty {
        emit("  op \(String(format: "%02X", op)):")
        hits.forEach { emit($0) }
    }
}

link.ch?.close()
emit("\n=== DONE ===")
exit(0)
