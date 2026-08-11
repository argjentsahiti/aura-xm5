import Foundation

/// A named equalizer curve.
///
/// ## Why these are approximations
///
/// The XM5 exposes six values on a fixed grid — Clear Bass (a low shelf) plus
/// graphic bands at 400 Hz, 1 kHz, 2.5 kHz, 6.3 kHz and 16 kHz — each ±10 steps
/// of roughly 1 dB. Three limits follow:
///
/// - **No sub-bass band.** 400 Hz is low-midrange. Everything below it is
///   reachable only through Clear Bass, so the "boost 30–60 Hz" advice in genre
///   guides collapses onto that one control.
/// - **Five bands, widely spaced.** Published audiophile corrections (AutoEq,
///   oratory1990) are 10-band parametric with Q values; they cannot be
///   reproduced here, only approximated in shape.
/// - **A hole between 6.3 k and 16 k.** Presence around 8–12 kHz has to be
///   split across the two neighbours.
///
/// So these are deliberate translations onto Sony's grid, not measured curves.
/// Moves are kept modest — the XM5's stock tuning is already close to the Harman
/// preference curve with elevated bass, so large boosts mostly add mud.
///
/// Values are the wire encoding: 0…20 with 10 flat.
struct EQPreset: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let bands: [Int]
    let group: Group

    enum Group: String, CaseIterable, Sendable {
        case reference = "Reference"
        case genre = "Genre"
        case character = "Character"
    }

    /// Offsets in dB from flat, in band order, for readability at the call site.
    private static func curve(_ id: String, _ name: String, _ detail: String,
                             _ group: Group,
                             bass: Int, _ b400: Int, _ b1k: Int,
                             _ b2k5: Int, _ b6k3: Int, _ b16k: Int) -> EQPreset {
        EQPreset(
            id: id, name: name, detail: detail,
            bands: [10 + bass, 10 + b400, 10 + b1k, 10 + b2k5, 10 + b6k3, 10 + b16k]
                .map { max(0, min(20, $0)) },
            group: group
        )
    }

    static let all: [EQPreset] = [
        // ---- Reference ---------------------------------------------------
        curve("flat", "Flat", "No correction — the headphones' own tuning",
              .reference, bass: 0, 0, 0, 0, 0, 0),

        // The XM5 ships bass-forward with a slightly hot upper treble. Easing
        // both and lifting presence is the closest this grid gets to neutral.
        curve("reference", "Reference", "Neutral-leaning, for critical listening",
              .reference, bass: -2, -3, 1, 3, -2, 2),

        // ---- Genre -------------------------------------------------------
        // Orchestral balance is fragile; almost nothing but a little air.
        curve("classical", "Classical", "Flat with gentle air, dynamics intact",
              .genre, bass: -1, -1, 0, 1, 1, 2),

        // Body for upright bass and brass, cymbals eased so they don't splash.
        curve("jazz", "Jazz", "Warm body, smooth cymbals",
              .genre, bass: 2, 1, 1, 1, -1, 1),

        // Guitars live in the upper mids; presence without letting 16 k glare.
        curve("rock", "Rock", "Mid-forward guitars, present but not harsh",
              .genre, bass: 3, -1, 2, 3, 1, 0),

        // Less Clear Bass than rock — double-kick turns to mush if it booms.
        curve("metal", "Metal", "Tight low end, aggressive attack",
              .genre, bass: 2, -2, 1, 4, 2, -1),

        // The one genre where a big shelf and scooped mids is the point.
        curve("electronic", "Electronic", "Deep sub-bass, scooped mids, crisp top",
              .genre, bass: 7, -2, -1, 1, 3, 4),

        // Sub weight plus 400 Hz for the body that gives bass its thump.
        curve("hiphop", "Hip-Hop", "Heavy sub-bass with body, crisp hats",
              .genre, bass: 8, 1, -1, 0, 2, 2),

        // Voices and strings sit in the mids — a V-curve would bury them.
        curve("acoustic", "Acoustic", "Natural mids, light warmth, airy",
              .genre, bass: 1, 0, 1, 2, 1, 2),

        curve("pop", "Pop", "Vocal presence with a little lift underneath",
              .genre, bass: 2, -2, 3, 3, 1, -1),

        // ---- Character ---------------------------------------------------
        curve("bass", "Bass Boost", "Low shelf only, everything else untouched",
              .character, bass: 9, 0, 0, 0, 0, 0),

        curve("treble", "Air", "Opens the top end for detail and space",
              .character, bass: 0, 0, 0, 2, 4, 6),

        // Loudness compensation: quiet listening loses perceived extremes.
        curve("latenight", "Late Night", "Compensates for listening quietly",
              .character, bass: 4, -1, 1, 2, 1, 3),

        curve("warm", "Warm", "Rolled-off top, easy for long sessions",
              .character, bass: 3, 2, 0, -1, -3, -4),

        // Speech intelligibility lives at 1–3 kHz; trim everything else away.
        curve("voice", "Voice", "Podcasts and audiobooks",
              .character, bass: -4, -2, 3, 4, 1, -2),
    ]

    static func preset(matching bands: [Int]) -> EQPreset? {
        all.first { $0.bands == bands }
    }

    static func named(_ id: String) -> EQPreset? {
        all.first { $0.id == id }
    }

    static func grouped(_ group: Group) -> [EQPreset] {
        all.filter { $0.group == group }
    }
}
