import Foundation

/// Device-name fragments matched against both the Bluetooth device and the
/// CoreAudio input device, so the Bluetooth link and the microphone controls
/// agree on what counts as "the headphones".
enum SupportedDevices {
    static let nameHints = [
        "WH-1000XM5",
        "WH-1000XM4",
        "WH-1000XM3",
        "WF-1000XM5",
    ]

    static func matches(_ name: String?) -> Bool {
        guard let name else { return false }
        return nameHints.contains { name.contains($0) }
    }
}
