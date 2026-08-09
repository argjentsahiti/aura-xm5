import Foundation
import IOBluetooth

// End-to-end hardware verification for Aura's protocol layer.
//
// Exercises every command the app can send and asserts the device reports the
// expected state back. Also probes Sony's EQ presets to establish which band
// index is Clear Bass. Restores the original state on exit.
//
// Aura must not be running — only one RFCOMM control channel is available.

// Discovered by name so this works on any paired Sony headset — no hardcoded
// hardware address. Override with the first CLI argument if you have several.
let nameHints = ["WH-1000XM5", "WH-1000XM4", "WH-1000XM3", "WF-1000XM5"]
let nameOverride: String? = CommandLine.arguments.dropFirst().first
let outPath = NSString(string: "~/aura_verify.txt").expandingTildeInPath

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

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    if ok { passed += 1; emit("  PASS  \(name)  — \(detail)") }
    else  { failed += 1; emit("  FAIL  \(name)  — \(detail)") }
}

// MARK: Framing (mirrors Sources/SonyXM5/Protocol)

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
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03)) }
    }
    @discardableResult
    func send(_ p: [UInt8], _ wait: TimeInterval = 0.6) -> [F] {
        got.removeAll(); w(pkt(DATA_MDR, seq, p)); seq = 1 &- seq; pump(wait); return got
    }
}

// MARK: Commands under test (must match SonyCommand)

func setANC(enabled: Bool, ambient: Bool, voiceFocus: Bool, level: Int) -> [UInt8] {
    [0x68, 0x17, 0x01, enabled ? 1 : 0, ambient ? 1 : 0, voiceFocus ? 1 : 0, UInt8(level)]
}
func setEQ(preset: UInt8, bands: [Int]) -> [UInt8] {
    [0x58, 0x00, preset, 0x06] + bands.map { UInt8($0) }
}

// MARK: Run

guard let ds = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
      let dev = ds.first(where: { matches($0.name) }) else {
    emit("FATAL: WH-1000XM5 not paired"); exit(1)
}

let link = Link()
var c: IOBluetoothRFCOMMChannel?
guard dev.openRFCOMMChannelAsync(&c, withChannelID: 9, delegate: link) == kIOReturnSuccess else {
    emit("FATAL: could not open RFCOMM channel 9 (is Aura still running?)"); exit(1)
}
link.ch = c
link.pump(3)
guard link.open else { emit("FATAL: channel did not open"); exit(1) }

emit("Aura hardware verification — \(Date())")
emit("Device: \(dev.name ?? "?")  \(dev.addressString ?? "?")\n")

func readANC() -> [UInt8] { link.send([0x66, 0x17]).first(where: { $0.p.first == 0x67 })?.p ?? [] }
func readEQ()  -> [UInt8] { link.send([0x56, 0x00]).first(where: { $0.p.first == 0x57 })?.p ?? [] }

// 1 — handshake
emit("[1] Connection")
let initResp = link.send([0x00, 0x00])
check("INIT handshake", initResp.contains { $0.p.first == 0x01 }, hex(initResp.first?.p ?? []))

// 2 — battery
emit("\n[2] Battery")
let bat = link.send([0x22, 0x00]).first(where: { $0.p.first == 0x23 })?.p ?? []
check("battery report", bat.count >= 4 && bat[2] <= 100, bat.isEmpty ? "no reply" : "\(bat[2])% charging=\(bat[3] != 0)")

let originalANC = readANC()
let originalEQ = readEQ()
emit("\n  original ANC: \(hex(originalANC))")
emit("  original EQ : \(hex(originalEQ))")

// 3 — ambient modes
emit("\n[3] Ambient sound modes")
link.send(setANC(enabled: false, ambient: false, voiceFocus: false, level: 10))
var r = readANC()
check("mode Off", r.count >= 7 && r[3] == 0, hex(r))

link.send(setANC(enabled: true, ambient: false, voiceFocus: false, level: 10))
r = readANC()
check("mode Noise Cancelling", r.count >= 7 && r[3] == 1 && r[4] == 0, hex(r))

link.send(setANC(enabled: true, ambient: true, voiceFocus: false, level: 10))
r = readANC()
check("mode Ambient", r.count >= 7 && r[3] == 1 && r[4] == 1, hex(r))

// 4 — ambient level round-trip
emit("\n[4] Ambient level (1–20, device clamps 0 up to 1)")
for lvl in [1, 5, 12, 20] {
    link.send(setANC(enabled: true, ambient: true, voiceFocus: false, level: lvl))
    let rr = readANC()
    check("level \(lvl)", rr.count >= 7 && Int(rr[6]) == lvl, "reported \(rr.count >= 7 ? String(rr[6]) : "—")")
}

// 5 — voice focus
emit("\n[5] Focus on Voice")
link.send(setANC(enabled: true, ambient: true, voiceFocus: true, level: 15))
r = readANC()
check("voice focus on", r.count >= 7 && r[5] == 1, hex(r))
link.send(setANC(enabled: true, ambient: true, voiceFocus: false, level: 15))
r = readANC()
check("voice focus off", r.count >= 7 && r[5] == 0, hex(r))

// 6 — equalizer round-trip
emit("\n[6] Equalizer bands")
let pattern = [0, 4, 8, 12, 16, 20]
link.send(setEQ(preset: 0xA0, bands: pattern))
var e = readEQ()
check("distinct pattern round-trip",
      e.count >= 10 && Array(e[4..<10]).map(Int.init) == pattern,
      e.count >= 10 ? hex(Array(e[4..<10])) : "no reply")

link.send(setEQ(preset: 0xA0, bands: Array(repeating: 10, count: 6)))
e = readEQ()
check("reset to flat",
      e.count >= 10 && Array(e[4..<10]).allSatisfy { $0 == 10 },
      e.count >= 10 ? hex(Array(e[4..<10])) : "no reply")

// 7 — each band independently
emit("\n[7] Individual band isolation")
for idx in 0..<6 {
    var bands = Array(repeating: 10, count: 6)
    bands[idx] = 18
    link.send(setEQ(preset: 0xA0, bands: bands))
    let rr = readEQ()
    let got = rr.count >= 10 ? Array(rr[4..<10]).map(Int.init) : []
    check("band \(idx) isolated", got == bands, got.isEmpty ? "no reply" : "\(got)")
}

// 8 — Sony presets, to identify which index is Clear Bass
emit("\n[8] Sony EQ presets (identifies Clear Bass index)")
for preset: UInt8 in [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                      0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17] {
    link.send([0x58, 0x00, preset, 0x00], 0.35)
    let rr = readEQ()
    if rr.count >= 10 {
        let bands = Array(rr[4..<10]).map(Int.init)
        let flat = bands.allSatisfy { $0 == 10 }
        emit("  preset 0x\(String(format: "%02X", preset)) -> reported 0x\(String(format: "%02X", rr[2])) bands \(bands)\(flat ? "" : "  <-- shaped")")
    }
}

// 9 — mode application, exactly as the app sends it
emit("\n[9] Mode application (Meeting)")
let meetingBands = [6, 8, 13, 13, 11, 9]
link.send(setANC(enabled: true, ambient: true, voiceFocus: true, level: 17))
link.send(setEQ(preset: 0xA0, bands: meetingBands))
let mANC = readANC(), mEQ = readEQ()
check("Meeting ambient state",
      mANC.count >= 7 && mANC[3] == 1 && mANC[4] == 1 && mANC[5] == 1 && mANC[6] == 17, hex(mANC))
check("Meeting EQ curve",
      mEQ.count >= 10 && Array(mEQ[4..<10]).map(Int.init) == meetingBands,
      mEQ.count >= 10 ? hex(Array(mEQ[4..<10])) : "no reply")

// 10 — restore
emit("\n[10] Restore original state")
if originalEQ.count >= 10 {
    link.send([0x58, 0x00] + Array(originalEQ[2..<10]))
}
if originalANC.count >= 7 {
    link.send([0x68, 0x17, 0x01, originalANC[3], originalANC[4], originalANC[5], originalANC[6]])
}
let finalANC = readANC(), finalEQ = readEQ()
check("ANC restored", finalANC.count >= 7 && originalANC.count >= 7
      && finalANC[3] == originalANC[3] && finalANC[4] == originalANC[4], hex(finalANC))
check("EQ restored", finalEQ.count >= 10 && originalEQ.count >= 10
      && Array(finalEQ[4..<10]) == Array(originalEQ[4..<10]), hex(finalEQ))

emit("\n========================================")
emit("  \(passed) passed, \(failed) failed")
emit("========================================")

link.ch?.close()
exit(failed == 0 ? 0 : 1)
