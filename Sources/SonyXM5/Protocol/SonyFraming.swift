import Foundation

// Sony MDR wire framing. Identical between the V1 and V2 protocols — only the
// payload opcodes differ, so this layer is shared.
//
//   0x3E | escaped( type, seq, len[4] BE, payload, checksum ) | 0x3C
//
// checksum = sum(type, seq, len, payload) & 0xFF
// Any 0x3C / 0x3D / 0x3E inside the body is escaped as 0x3D followed by
// (byte & 0xEF); decoding restores it by OR-ing the next byte with 0x10.

enum Wire {
    static let sof: UInt8 = 0x3E
    static let eof: UInt8 = 0x3C
    static let esc: UInt8 = 0x3D

    static let dataMDR: UInt8 = 0x0C
    static let dataAck: UInt8 = 0x01
}

struct SonyFrame {
    let type: UInt8
    let seq: UInt8
    let payload: [UInt8]

    /// First payload byte — the response opcode (e.g. 0x57 for an EQ report).
    var opcode: UInt8? { payload.first }
}

enum SonyFraming {
    static func encode(type: UInt8, seq: UInt8, payload: [UInt8]) -> Data {
        var inner: [UInt8] = [type, seq]
        let n = UInt32(payload.count)
        inner += [
            UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
            UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF),
        ]
        inner += payload
        inner.append(inner.reduce(UInt8(0)) { $0 &+ $1 })

        var out: [UInt8] = [Wire.sof]
        out.reserveCapacity(inner.count + 8)
        for b in inner {
            if b == Wire.sof || b == Wire.eof || b == Wire.esc {
                out.append(Wire.esc)
                out.append(b & 0xEF)
            } else {
                out.append(b)
            }
        }
        out.append(Wire.eof)
        return Data(out)
    }
}

/// Incremental parser — RFCOMM delivers arbitrary chunk boundaries.
final class SonyFrameParser {
    private var buffer: [UInt8] = []

    func reset() { buffer.removeAll(keepingCapacity: true) }

    func feed(_ data: Data) -> [SonyFrame] {
        buffer += [UInt8](data)
        var frames: [SonyFrame] = []

        while let start = buffer.firstIndex(of: Wire.sof) {
            guard let end = buffer[(start + 1)...].firstIndex(of: Wire.eof) else {
                // Incomplete frame — drop anything before the start marker and wait.
                if start > 0 { buffer.removeSubrange(0..<start) }
                break
            }

            let raw = Array(buffer[(start + 1)..<end])
            buffer.removeSubrange(0...end)

            var inner: [UInt8] = []
            inner.reserveCapacity(raw.count)
            var i = 0
            while i < raw.count {
                if raw[i] == Wire.esc, i + 1 < raw.count {
                    inner.append(raw[i + 1] | 0x10)
                    i += 2
                } else {
                    inner.append(raw[i])
                    i += 1
                }
            }

            guard inner.count >= 7 else { continue }
            let len = (Int(inner[2]) << 24) | (Int(inner[3]) << 16)
                    | (Int(inner[4]) << 8) | Int(inner[5])
            guard len >= 0, inner.count >= 7 + len else { continue }

            let payload = Array(inner[6..<(6 + len)])
            let checksum = inner[6 + len]
            guard inner.prefix(6 + len).reduce(UInt8(0), &+) == checksum else { continue }

            frames.append(SonyFrame(type: inner[0], seq: inner[1], payload: payload))
        }

        return frames
    }
}
