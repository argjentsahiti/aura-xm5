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

emit("Aura feature verification — \(Date())\n")
link.send([0x00, 0x00])

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    if ok { passed += 1; emit("  PASS  \(name) — \(detail)") }
    else  { failed += 1; emit("  FAIL  \(name) — \(detail)") }
}

// ---------------------------------------------------------------- 1. probe 0xFA
// Never swept before; Gadgetbridge maps this to Speak-to-Chat config on V1 and
// ambient-button-mode on V2.
emit("[1] 0xFA family (previously unprobed)")
for t in UInt8(0x00)...UInt8(0x08) {
    let r = link.read(0xFA, t)
    if !r.isEmpty { emit("    FA \(String(format: "%02X", t)) -> \(hex(r))") }
}

// ------------------------------------------------------- 2. auto power-off
emit("\n[2] Auto power-off (26/27/28 type 05)")
let apoOriginal = link.read(0x26, 0x05)
emit("    original: \(hex(apoOriginal))")

let apoNames: [String: String] = [
    "11 00": "Off", "00 00": "After 5 min", "01 01": "After 30 min",
    "02 02": "After 1 hour", "03 03": "After 3 hours", "10 00": "When taken off",
]
if apoOriginal.count >= 4 {
    let code = hex(Array(apoOriginal[2..<4]))
    emit("    decoded: \(apoNames[code] ?? "unknown(\(code))")")
}

for (code, name) in [([UInt8(0x01), 0x01], "After 30 min"), ([UInt8(0x11), 0x00], "Off")] {
    link.send([0x28, 0x05] + code)
    let r = link.read(0x26, 0x05)
    check("set \(name)", r.count >= 4 && Array(r[2..<4]) == code, hex(r))
}

// ---------------------------------------------------------- 3. DSEE upsampling
emit("\n[3] DSEE / audio upsampling (E6/E7/E8 type 02)")
let dseeOriginal = link.read(0xE6, 0x02)
emit("    original: \(hex(dseeOriginal))")

// Try the V1 4-byte form, then the shorter form the XM5's reply suggests.
var dseeForm = 0
link.send([0xE8, 0x02, 0x00, 0x01])
var r = link.read(0xE6, 0x02)
if r.count >= 3, r.last == 0x01 { dseeForm = 4 }
if dseeForm == 0 {
    link.send([0xE8, 0x02, 0x01])
    r = link.read(0xE6, 0x02)
    if r.count >= 3, r.last == 0x01 { dseeForm = 3 }
}
check("enable DSEE", dseeForm != 0, dseeForm != 0 ? "\(dseeForm)-byte SET works -> \(hex(r))" : "no form worked -> \(hex(r))")

if dseeForm == 4 { link.send([0xE8, 0x02, 0x00, 0x00]) } else if dseeForm == 3 { link.send([0xE8, 0x02, 0x00]) }
r = link.read(0xE6, 0x02)
check("disable DSEE", r.count >= 3 && r.last == 0x00, hex(r))

// ------------------------------------------------------------ 4. Speak-to-Chat
emit("\n[4] Speak-to-Chat (F6/F7/F8 type 05)")
let s2cOriginal = link.read(0xF6, 0x05)
emit("    original: \(hex(s2cOriginal))")

var s2cForm = 0
link.send([0xF8, 0x05, 0x01, 0x00])          // V1 shape
r = link.read(0xF6, 0x05)
if r.count >= 3, r.last == 0x00 { s2cForm = 4 }
if s2cForm == 0 {
    link.send([0xF8, 0x05, 0x00])
    r = link.read(0xF6, 0x05)
    if r.count >= 3, r.last == 0x00 { s2cForm = 3 }
}
check("disable Speak-to-Chat", s2cForm != 0,
      s2cForm != 0 ? "\(s2cForm)-byte SET works -> \(hex(r))" : "no form worked -> \(hex(r))")

if s2cForm == 4 { link.send([0xF8, 0x05, 0x01, 0x01]) } else if s2cForm == 3 { link.send([0xF8, 0x05, 0x01]) }
r = link.read(0xF6, 0x05)
check("enable Speak-to-Chat", r.count >= 3 && r.last == 0x01, hex(r))

// ------------------------------------------------------------------ 5. volume
emit("\n[5] Volume (A6/A7/A8 type 20)")
let volOriginal = link.read(0xA6, 0x20)
emit("    original: \(hex(volOriginal))")
if volOriginal.count >= 3 {
    let start = Int(volOriginal[2])
    let target: UInt8 = start > 10 ? UInt8(start - 4) : UInt8(start + 4)
    link.send([0xA8, 0x20, target])
    r = link.read(0xA6, 0x20)
    check("set volume \(target)", r.count >= 3 && r[2] == target, hex(r))
    link.send([0xA8, 0x20, volOriginal[2]])
    r = link.read(0xA6, 0x20)
    check("restore volume \(volOriginal[2])", r.count >= 3 && r[2] == volOriginal[2], hex(r))
}

// ----------------------------------------------------------------- 6. restore
emit("\n[6] Restore")
if apoOriginal.count >= 4 {
    link.send([0x28, 0x05] + Array(apoOriginal[2..<4]))
    r = link.read(0x26, 0x05)
    check("auto power-off restored", Array(r.suffix(2)) == Array(apoOriginal.suffix(2)), hex(r))
}
if dseeOriginal.count >= 3 {
    let want = dseeOriginal[dseeOriginal.count - 1]
    if dseeForm == 4 { link.send([0xE8, 0x02, 0x00, want]) } else if dseeForm == 3 { link.send([0xE8, 0x02, want]) }
    r = link.read(0xE6, 0x02)
    check("DSEE restored", r.last == want, hex(r))
}
if s2cOriginal.count >= 3 {
    let want = s2cOriginal[s2cOriginal.count - 1]
    if s2cForm == 4 { link.send([0xF8, 0x05, 0x01, want]) } else if s2cForm == 3 { link.send([0xF8, 0x05, want]) }
    r = link.read(0xF6, 0x05)
    check("Speak-to-Chat restored", r.last == want, hex(r))
}

emit("\n========================================")
emit("  \(passed) passed, \(failed) failed")
emit("========================================")

link.ch?.close()
exit(0)
