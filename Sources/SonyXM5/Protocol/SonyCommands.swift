import Foundation

// Sony V2 (Serial HPC, UUID 956C7B26-…) command set, as verified live against a
// WH-1000XM5 on firmware 2.4.1.
//
// Feature tables discovered by sweeping GET opcodes on the device:
//   0x00  Equalizer          GET 0x56 / SET 0x58 / RET 0x57
//   0x17  AmbientSoundControl2  GET 0x66 / SET 0x68 / RET 0x67
//   battery               GET 0x22 / RET 0x23
//
// Note the XM5 puts the equalizer on table 0x00, unlike the ULT-series which
// uses 0x03 — querying 0x03 on an XM5 returns nothing at all.

enum ANCMode: Int, Codable, CaseIterable, Sendable {
    case off
    case noiseCancelling
    case ambient

    var title: String {
        switch self {
        case .off: return "Off"
        case .noiseCancelling: return "Noise Cancelling"
        case .ambient: return "Ambient"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: return "Off"
        case .noiseCancelling: return "Noise\u{00A0}Cancelling"
        case .ambient: return "Ambient"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "speaker.wave.1"
        case .noiseCancelling: return "waveform.slash"
        case .ambient: return "waveform"
        }
    }
}

/// Live state of the headphones' ambient-sound engine.
struct ANCState: Equatable, Sendable {
    var mode: ANCMode = .noiseCancelling
    /// 1…20. Only meaningful in `.ambient`. The device clamps 0 up to 1, so 1 is
    /// the true minimum rather than 0.
    var ambientLevel: Int = 20
    /// "Focus on Voice" — lets speech through while damping the rest.
    var voiceFocus: Bool = false
}

/// Equalizer state. Six bands, each 0…20 on the wire with 10 = flat (±10 steps).
struct EQState: Equatable, Sendable {
    /// Sony preset id. 0xA0 is "Custom" — the device switches to it automatically
    /// as soon as individual bands are written.
    var preset: UInt8 = 0xA0
    var bands: [Int] = Array(repeating: 10, count: 6)

    static let flat = EQState(preset: 0xA0, bands: Array(repeating: 10, count: 6))

    /// Band labels in wire order: Clear Bass first, then ascending frequency.
    ///
    /// Established from the device's own presets rather than assumed — preset
    /// 0x16 ("Bass") reports [17,10,10,10,10,10] and 0x17 ("Speech") reports
    /// [0,14,13,11,12,0], which only makes sense with the low shelf at index 0
    /// and 16 kHz at index 5.
    static let bandLabels = ["Bass", "400", "1k", "2.5k", "6.3k", "16k"]
}

enum SonyCommand {
    // MARK: Requests

    /// Protocol handshake — must be sent once after the channel opens.
    static let initHandshake: [UInt8] = [0x00, 0x00]

    static let getBattery: [UInt8] = [0x22, 0x00]
    static let getANC: [UInt8] = [0x66, 0x17]
    static let getEQ: [UInt8] = [0x56, 0x00]
    /// Model / firmware / serial block.
    static let getDeviceInfo: [UInt8] = [0x36, 0x01]

    // Tables below were named from Gadgetbridge's V2 mapping, then confirmed on
    // hardware. Note all three SET bodies are 3 bytes — the 4-byte V1 shapes
    // Gadgetbridge uses are silently ignored by the XM5.
    /// AUDIO_GET_PARAM, sub-type 0x01 = UPSCALING (DSEE Extreme).
    /// Sub-type 0x02 is CONNECTION_MODE_WITH_LDAC_STATUS — writing there changes
    /// the Bluetooth quality/stability trade-off, not the upscaler.
    static let getDSEE: [UInt8] = [0xE6, 0x01]
    static let getAutoPowerOff: [UInt8] = [0x26, 0x05]
    static let getVolume: [UInt8] = [0xA6, 0x20]

    static func setDSEE(_ on: Bool) -> [UInt8] { [0xE8, 0x01, on ? 1 : 0] }
    static func setVolume(_ level: Int) -> [UInt8] {
        [0xA8, 0x20, UInt8(clamping: max(0, min(30, level)))]
    }

    /// The XM5 supports only these two. Its predecessors' timed options
    /// (5 min / 30 min / 1 h / 3 h) are accepted on the wire but never applied —
    /// wearing detection replaced them.
    static func setAutoPowerOff(whenTakenOff: Bool) -> [UInt8] {
        whenTakenOff ? [0x28, 0x05, 0x10, 0x00] : [0x28, 0x05, 0x11, 0x00]
    }

    static func setANC(_ s: ANCState) -> [UInt8] {
        // [0x68, table, 0x01, enabled, ambientMode, voiceFocus, level]
        //
        // The SET body mirrors the GET reply exactly. Verified on hardware: the
        // 8-byte variant used by some Sony models (with an extra 0x02 before the
        // level) silently pins the XM5's ambient level to 1 — levels only take
        // when the byte sits at index 6.
        let enabled: UInt8 = (s.mode == .off) ? 0x00 : 0x01
        let ambient: UInt8 = (s.mode == .ambient) ? 0x01 : 0x00
        let level = UInt8(clamping: max(1, min(20, s.ambientLevel)))
        return [0x68, 0x17, 0x01, enabled, ambient, s.voiceFocus ? 1 : 0, level]
    }

    static func setEQ(_ eq: EQState) -> [UInt8] {
        // [0x58, table, preset, bandCount, b1…b6]
        var out: [UInt8] = [0x58, 0x00, eq.preset, 0x06]
        for b in eq.bands.prefix(6) {
            out.append(UInt8(clamping: max(0, min(20, b))))
        }
        return out
    }

    // MARK: Response decoding

    /// `23 00 <level> <charging>` in reply to a request, or `25 00 …` when the
    /// headphones report a change on their own.
    static func parseBattery(_ p: [UInt8]) -> (level: Int, charging: Bool)? {
        guard p.count >= 4, p[0] == 0x23 || p[0] == 0x25 else { return nil }
        return (Int(p[2]), p[3] != 0)
    }

    /// `67 17 01 <enabled> <ambient> <voiceFocus> <level>`
    static func parseANC(_ p: [UInt8]) -> ANCState? {
        guard p.count >= 7, p[0] == 0x67 else { return nil }
        let enabled = p[3] != 0
        let ambient = p[4] != 0
        let mode: ANCMode = !enabled ? .off : (ambient ? .ambient : .noiseCancelling)
        return ANCState(mode: mode, ambientLevel: Int(p[6]), voiceFocus: p[5] != 0)
    }

    /// `57 00 <preset> <count> <b1…b6>`
    static func parseEQ(_ p: [UInt8]) -> EQState? {
        guard p.count >= 4, p[0] == 0x57 else { return nil }
        let count = Int(p[3])
        guard count > 0, p.count >= 4 + count else { return nil }
        return EQState(preset: p[2], bands: p[4..<(4 + count)].map(Int.init))
    }

    /// `E7 02 <on>` / `F7 05 <on>` — a trailing boolean.
    static func parseFlag(_ p: [UInt8], opcode: UInt8) -> Bool? {
        guard p.count >= 3, p[0] == opcode else { return nil }
        return p[2] != 0
    }

    /// `27 05 <c0> <c1>` — `10 00` is when-taken-off, `11 00` is off.
    static func parseAutoPowerOff(_ p: [UInt8]) -> Bool? {
        guard p.count >= 4, p[0] == 0x27 else { return nil }
        return p[2] == 0x10
    }

    /// `A7 20 <level>` — 0…30.
    static func parseVolume(_ p: [UInt8]) -> Int? {
        guard p.count >= 3, p[0] == 0xA7, p[1] == 0x20 else { return nil }
        return Int(p[2])
    }

    /// Device info block — model string then firmware, both length-prefixed.
    static func parseDeviceInfo(_ p: [UInt8]) -> (model: String, firmware: String)? {
        guard p.count > 3, p[0] == 0x37 else { return nil }
        var i = 2
        func readString() -> String? {
            guard i < p.count else { return nil }
            let n = Int(p[i]); i += 1
            guard n > 0, i + n <= p.count else { return nil }
            let s = String(bytes: p[i..<(i + n)], encoding: .ascii)
            i += n
            return s
        }
        guard let model = readString(), let fw = readString() else { return nil }
        return (model, fw)
    }
}
