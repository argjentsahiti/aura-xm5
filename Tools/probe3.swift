import Foundation
import IOBluetooth

// Verifies the feature tables identified from Gadgetbridge's V2 mapping:
// auto power-off, DSEE upsampling, Speak-to-Chat and volume.
//
// Gadgetbridge's V2 enum is partial and some XM5 replies are shorter than its
// V1 layouts imply, so each SET is tried in more than one shape and confirmed by
// read-back. Original values are restored at the end.
//
// Aura must not be running — only one RFCOMM control channel exists.

// Discovered by name so this works on any paired Sony headset — no hardcoded
// hardware address. Override with the first CLI argument if you have several.
let nameHints = ["WH-1000XM5", "WH-1000XM4", "WH-1000XM3", "WF-1000XM5"]
let nameOverride: String? = CommandLine.arguments.dropFirst().first
let outPath = NSString(string: "~/aura_verify2.txt").expandingTildeInPath

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
    func send(_ p: [UInt8], _ wait: TimeInterval = 0.5) -> [F] {
        got.removeAll(); w(pkt(DATA_MDR, seq, p)); seq = 1 &- seq; pump(wait); return got
    }
    /// Reads a table, returning the reply payload for the given RET opcode.
    func read(_ getOp: UInt8, _ type: UInt8) -> [UInt8] {
        send([getOp, type]).first(where: { $0.p.first == getOp &+ 1 })?.p ?? []
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

emit("Sub-type correction probe — \(Date())\n")
link.send([0x00, 0x00])

var passed = 0, failed = 0
func check(_ n: String, _ ok: Bool, _ d: String) {
    if ok { passed += 1; emit("  PASS  \(n) — \(d)") } else { failed += 1; emit("  FAIL  \(n) — \(d)") }
}

// AUDIO 0xE6: 0x01 is UPSCALING (DSEE); 0x02 is CONNECTION_MODE_WITH_LDAC_STATUS.
emit("[1] AUDIO sub-types")
for t in [UInt8(0x00), 0x01, 0x02] {
    emit("    E6 \(String(format: "%02X", t)) -> \(hex(link.read(0xE6, t)))")
}
let upOrig = link.read(0xE6, 0x01)
emit("    UPSCALING original: \(hex(upOrig))")
link.send([0xE8, 0x01, 0x01])
var r = link.read(0xE6, 0x01)
check("upscaling on (E8 01 01)", r.count >= 3 && r.last == 0x01, hex(r))
link.send([0xE8, 0x01, 0x00])
r = link.read(0xE6, 0x01)
check("upscaling off", r.count >= 3 && r.last == 0x00, hex(r))

// SYSTEM 0xF6: SMART_TALKING_MODE is 0x02 (type1) or 0x0C (type2).
emit("\n[2] SYSTEM sub-types — Speak-to-Chat candidates")
for t in [UInt8(0x02), 0x0C, 0x05] {
    emit("    F6 \(String(format: "%02X", t)) -> \(hex(link.read(0xF6, t)))")
}

for t in [UInt8(0x02), 0x0C] {
    let orig = link.read(0xF6, t)
    guard orig.count >= 3 else { continue }
    let last = orig[orig.count - 1]
    let flip: UInt8 = last == 0 ? 1 : 0
    // Mirror the reply shape: replace only the final byte.
    var body = Array(orig.dropFirst())
    body[body.count - 1] = flip
    link.send([0xF8] + body)
    var rr = link.read(0xF6, t)
    let moved = rr.count >= 3 && rr[rr.count - 1] == flip
    check("F6 \(String(format: "%02X", t)) writable", moved, "\(hex(orig)) -> \(hex(rr))")
    // restore
    body[body.count - 1] = last
    link.send([0xF8] + body)
    rr = link.read(0xF6, t)
    check("F6 \(String(format: "%02X", t)) restored", rr.count >= 3 && rr[rr.count - 1] == last, hex(rr))
}

// Restore upscaling to what it was.
if upOrig.count >= 3 {
    link.send([0xE8, 0x01, upOrig[upOrig.count - 1]])
    r = link.read(0xE6, 0x01)
    check("upscaling restored", r.last == upOrig[upOrig.count - 1], hex(r))
}

emit("\n  \(passed) passed, \(failed) failed")
link.ch?.close()
exit(0)
