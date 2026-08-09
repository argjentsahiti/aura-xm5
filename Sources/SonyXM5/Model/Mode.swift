import Foundation

/// A Mode is a named pairing of an ambient-sound state with an equalizer curve —
/// one tap reconfigures the headphones for a situation.
///
/// EQ bands are in wire order (400 Hz, 1 kHz, 2.5 kHz, 6.3 kHz, 16 kHz, Clear
/// Bass) on Sony's 0…20 scale where 10 is flat.
struct Mode: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var symbol: String
    var anc: ANCState
    var eq: EQState
    /// Built-ins can be reset but not deleted.
    var isBuiltIn: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, symbol, ancMode, ambientLevel, voiceFocus, bands, isBuiltIn
    }

    init(id: UUID = UUID(), name: String, symbol: String,
         anc: ANCState, eq: EQState, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.anc = anc
        self.eq = eq
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        let modeRaw = try c.decode(Int.self, forKey: .ancMode)
        anc = ANCState(
            mode: ANCMode(rawValue: modeRaw) ?? .noiseCancelling,
            ambientLevel: try c.decode(Int.self, forKey: .ambientLevel),
            voiceFocus: try c.decode(Bool.self, forKey: .voiceFocus)
        )
        eq = EQState(preset: 0xA0, bands: try c.decode([Int].self, forKey: .bands))
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(anc.mode.rawValue, forKey: .ancMode)
        try c.encode(anc.ambientLevel, forKey: .ambientLevel)
        try c.encode(anc.voiceFocus, forKey: .voiceFocus)
        try c.encode(eq.bands, forKey: .bands)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
    }
}

extension Mode {
    private static func eq(_ b: [Int]) -> EQState { EQState(preset: 0xA0, bands: b) }

    /// Curves are deliberately gentle. Sony's steps are ~1 dB each and the XM5 is
    /// already close to neutral, so large moves sound wrong.
    ///
    /// Band order is [Clear Bass, 400, 1k, 2.5k, 6.3k, 16k] — see
    /// `EQState.bandLabels`.
    static let builtIns: [Mode] = [
        // Speech intelligibility lives in 1–3 kHz. Lift there, pull the low shelf
        // well down so voices aren't masked, and let ambient + voice focus
        // through so you can hear the room and your own voice.
        //                Bass 400  1k 2.5k 6.3k 16k
        // Focus on Voice is left off: it suppresses everything but speech, which
        // reads as "ambient isn't working". Ambient wide open lets you hear the
        // room and your own voice naturally. The toggle is there if you want it.
        Mode(name: "Meeting", symbol: "person.wave.2.fill",
             anc: ANCState(mode: .ambient, ambientLevel: 18, voiceFocus: false),
             eq: eq([6, 8, 13, 13, 11, 9]), isBuiltIn: true),

        // Full isolation, near-neutral response — nothing pulling attention.
        Mode(name: "Focus", symbol: "brain.head.profile",
             anc: ANCState(mode: .noiseCancelling, ambientLevel: 1, voiceFocus: false),
             eq: eq([9, 9, 10, 11, 10, 9]), isBuiltIn: true),

        // Engine and cabin rumble sits low; cancellation removes some perceived
        // weight, so the Clear Bass shelf puts it back.
        Mode(name: "Commute", symbol: "tram.fill",
             anc: ANCState(mode: .noiseCancelling, ambientLevel: 1, voiceFocus: false),
             eq: eq([15, 12, 10, 9, 10, 12]), isBuiltIn: true),

        // Gentle V: weight underneath, air on top, midrange left alone.
        Mode(name: "Music", symbol: "music.note",
             anc: ANCState(mode: .noiseCancelling, ambientLevel: 1, voiceFocus: false),
             eq: eq([13, 12, 9, 9, 11, 13]), isBuiltIn: true),

        // Stay aware of traffic and people: ambient wide open, top end eased back
        // so wind and road noise aren't harsh.
        Mode(name: "Outdoors", symbol: "figure.walk",
             anc: ANCState(mode: .ambient, ambientLevel: 20, voiceFocus: false),
             eq: eq([11, 11, 10, 10, 9, 8]), isBuiltIn: true),
    ]
}

// MARK: - Persistence

@MainActor
final class ModeStore: ObservableObject {
    @Published private(set) var modes: [Mode] = []
    @Published var activeModeID: UUID?

    // v2: band order corrected to [Clear Bass, 400, 1k, 2.5k, 6.3k, 16k]. The
    // key is bumped so anything saved against the old mirrored order is dropped
    // rather than silently loaded with inverted curves.
    private let key = "modes.v3"
    private let activeKey = "activeMode.v3"
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Mode].self, from: data),
           !decoded.isEmpty {
            modes = decoded
        } else {
            modes = Mode.builtIns
        }
        if let raw = defaults.string(forKey: activeKey) {
            activeModeID = UUID(uuidString: raw)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(modes) {
            defaults.set(data, forKey: key)
        }
        defaults.set(activeModeID?.uuidString, forKey: activeKey)
    }

    func setActive(_ id: UUID?) {
        activeModeID = id
        persist()
    }

    func update(_ mode: Mode) {
        guard let idx = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[idx] = mode
        persist()
    }

    func add(_ mode: Mode) {
        modes.append(mode)
        persist()
    }

    func delete(_ id: UUID) {
        modes.removeAll { $0.id == id && !$0.isBuiltIn }
        if activeModeID == id { activeModeID = nil }
        persist()
    }

    func resetToDefaults() {
        modes = Mode.builtIns
        activeModeID = nil
        persist()
    }

    func mode(for id: UUID?) -> Mode? {
        guard let id else { return nil }
        return modes.first { $0.id == id }
    }
}
