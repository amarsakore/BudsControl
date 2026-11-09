import Foundation

// HeyMelody earbuds protocol (OPPO / OnePlus / realme), spoken over classic Bluetooth RFCOMM.
//
// Frame layout:
//   AA  <len = payload + 7>  00 00  <cmd lo> <cmd hi>  <seq>  <payload len lo> <payload len hi>  <payload...>
// Responses use the request command with the high bit set (0x0106 -> 0x8106).

enum Command {
    static let hello: UInt16 = 0x0100
    static let productID: UInt16 = 0x0103
    static let battery: UInt16 = 0x0106
    static let noiseQuery: UInt16 = 0x010C
    static let setNoise: UInt16 = 0x0404
    static let setSwitch: UInt16 = 0x0403
    static let subscribe: UInt16 = 0x0205
    static let wearStatus: UInt16 = 0x0109
    static let multipointQuery: UInt16 = 0x0112
    static let multipointSet: UInt16 = 0x040B
    static let statusPush: UInt16 = 0x0204
    // Command numbers below are from Gadgetbridge's OPPO support and RawS-Music's HeyMelody port.
    static let findBuds: UInt16 = 0x0400
    static let gestureQuery: UInt16 = 0x0108
    static let setGesture: UInt16 = 0x0401
    static let switchQuery: UInt16 = 0x010D
    static let eqQuery: UInt16 = 0x010F
    static let eqListQuery: UInt16 = 0x0122
    static let setEQ: UInt16 = 0x0406
    static let setCustomEQ: UInt16 = 0x0418
}

/// On/off features set with 0x0403 [id, on] and read with 0x010D [count, ids...].
enum Feature {
    static let lowLatency: UInt8 = 6  // HeyMelody "game mode"
}

struct Frame {
    let command: UInt16
    let seq: UInt8
    let payload: [UInt8]

    func encoded() -> Data {
        var bytes: [UInt8] = [
            0xAA,
            UInt8((payload.count + 7) & 0xFF),
            0x00, 0x00,
            UInt8(command & 0xFF), UInt8(command >> 8),
            seq,
            UInt8(payload.count & 0xFF), UInt8(payload.count >> 8),
        ]
        bytes += payload
        return Data(bytes)
    }
}

/// Accumulates bytes from the RFCOMM channel and splits them into frames.
struct FrameParser {
    private var buffer: [UInt8] = []

    mutating func feed(_ data: [UInt8]) -> [Frame] {
        buffer += data
        var frames: [Frame] = []
        var i = 0
        while i < buffer.count {
            guard buffer[i] == 0xAA else { i += 1; continue }
            guard i + 9 <= buffer.count else { break }
            let cmd = UInt16(buffer[i + 4]) | UInt16(buffer[i + 5]) << 8
            let payloadLen = Int(buffer[i + 7]) | Int(buffer[i + 8]) << 8
            let end = i + 9 + payloadLen
            guard end <= buffer.count else { break }
            frames.append(Frame(command: cmd, seq: buffer[i + 6], payload: Array(buffer[(i + 9)..<end])))
            i = end
        }
        buffer.removeFirst(min(i, buffer.count))
        return frames
    }
}

// MARK: - Noise control modes

enum NoiseMode: String, CaseIterable, Identifiable {
    case off, transparency, anc
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .transparency: "Transparency"
        case .anc: "Noise Cancellation"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: "Off"
        case .transparency: "Transparency"
        case .anc: "ANC"
        }
    }

    var symbol: String {
        switch self {
        case .off: "circle.slash"
        case .transparency: "ear.and.waveform"
        case .anc: "waveform.slash"
        }
    }
}

enum ANCLevel: String, CaseIterable, Identifiable {
    case smart, max, moderate, mild
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// HeyMelody "modeType" for this level.
    var modeType: Int {
        switch self {
        case .mild: 3
        case .max: 4
        case .smart: 7
        case .moderate: 8
        }
    }
}

/// The mode byte on the wire is a bitmask; what each bit means depends on the model.
/// Layouts map bit index -> modeType (1 off, 2/6 transparency, anything else an ANC flavour).
/// Taken from HeyMelody's bundled model whitelist.
enum NoiseLayouts {
    static let onePlusBuds4 = "065414"

    static let table: [String: [Int: Int]] = [
        "065414": [0: 1, 1: 5, 2: 2, 3: 1, 4: 4, 5: 8, 6: 3, 7: 7, 8: 2, 11: 10],  // OnePlus Buds 4
        "063C14": [0: 1, 1: 5, 2: 2, 3: 1, 4: 4, 5: 8, 6: 3, 7: 7, 8: 2],          // OnePlus Buds 3
        "064014": [0: 1, 1: 5, 2: 2, 3: 1, 4: 4, 5: 8, 6: 3, 7: 7, 8: 2],          // OnePlus Buds Pro 3
        "067814": [0: 1, 1: 5, 2: 2, 3: 1, 4: 4, 5: 8, 6: 3, 7: 7, 8: 2, 11: 10, 12: 11, 13: 12, 14: 13], // Buds Pro 4
        "062014": [0: 1, 1: 5, 2: 2, 3: 1, 4: 4, 5: 8, 6: 3, 7: 7, 8: 2],          // OnePlus Buds Pro 2
        "064414": [0: 1, 1: 5, 2: 2, 3: 1, 4: 4, 5: 8, 6: 3, 7: 7, 8: 2],          // Nord Buds 3 Pro
        "066814": [0: 1, 1: 5, 2: 2, 3: 1, 4: 4, 5: 8, 6: 3, 7: 7, 8: 2],          // Nord Buds 4 Pro
        "067014": [0: 1, 1: 5, 2: 2, 3: 1, 4: 4, 5: 8, 6: 3, 7: 7, 8: 2],          // Nord Buds 4
        "065014": [0: 5, 1: 1, 2: 2],                                              // Nord Buds 3
        "060C14": [0: 1, 1: 2, 2: 3, 3: 4, 4: 7],                                  // OnePlus Buds Pro
    ]

    /// Buds Pro 3 uses one mask layout for writes and a different 16-bit layout
    /// in status replies. The write slots still use the common HeyMelody types.
    static let budsPro3Set: [Int: Int] = [
        0: 1, 1: 5, 2: 2, 4: 4, 5: 8, 6: 3, 7: 7
    ]

    static let modelNames: [String: String] = [
        "065414": "OnePlus Buds 4",
        "063C14": "OnePlus Buds 3",
        "064014": "OnePlus Buds Pro 3",
        "067814": "OnePlus Buds Pro 4",
        "062014": "OnePlus Buds Pro 2",
        "064414": "OnePlus Nord Buds 3 Pro",
        "066814": "OnePlus Nord Buds 4 Pro",
        "067014": "OnePlus Nord Buds 4",
        "065014": "OnePlus Nord Buds 3",
        "060C14": "OnePlus Buds Pro",
    ]

    static func layout(for productID: String?) -> [Int: Int] {
        table[productID ?? onePlusBuds4] ?? table[onePlusBuds4]!
    }

    static func setLayout(for productID: String?, deviceName: String?) -> [Int: Int] {
        if productID == "064014" || deviceName?.lowercased().contains("buds pro 3") == true {
            return budsPro3Set
        }
        return layout(for: productID)
    }

    static func reportedMode(for mask: Int, productID: String?, deviceName: String?)
        -> (mode: NoiseMode, level: ANCLevel?)?
    {
        if productID == "064014" || deviceName?.lowercased().contains("buds pro 3") == true {
            switch mask {
            case 0x0008: return (.off, nil)
            case 0x0100: return (.transparency, nil)
            case 0x1000: return (.anc, .max)
            case 0x2000: return (.anc, .moderate)
            case 0x4000: return (.anc, .mild)
            case 0x8000: return (.anc, .smart)
            default: return nil
            }
        }

        let bit = mask.trailingZeroBitCount
        guard let type = layout(for: productID)[bit] else { return nil }
        return (mode(forType: type), ANCLevel.allCases.first { $0.modeType == type })
    }

    static func mode(forType type: Int) -> NoiseMode {
        switch type {
        case 1: .off
        case 2, 6: .transparency
        default: .anc
        }
    }

    /// Bit to set for a mode (and optional ANC level). For plain ANC we prefer the
    /// model's generic ANC entry (type 5), then fall back to max/smart/moderate/mild.
    static func bit(for mode: NoiseMode, level: ANCLevel?, layout: [Int: Int]) -> Int? {
        let wanted: [Int]
        switch mode {
        case .off: wanted = [1]
        case .transparency: wanted = [2, 6]
        case .anc: wanted = level.map { [$0.modeType] } ?? [5, 4, 7, 8, 3]
        }
        for type in wanted {
            if let bit = layout.filter({ $0.value == type }).keys.min() { return bit }
        }
        return nil
    }

    /// Human-readable name of a HeyMelody modeType, for the developer view.
    static func typeName(_ type: Int) -> String {
        switch type {
        case 1: "Off"
        case 2: "Transparency"
        case 3: "ANC · Mild"
        case 4: "ANC · Max"
        case 5: "ANC"
        case 6: "Voice enhancement"
        case 7: "ANC · Smart"
        case 8: "ANC · Moderate"
        case 10: "ANC · Adaptive"
        default: "Unknown (type \(type))"
        }
    }

    static func levels(in layout: [Int: Int]) -> [ANCLevel] {
        ANCLevel.allCases.filter { layout.values.contains($0.modeType) }
    }
}

// MARK: - Equalizer

struct EQPreset: Identifiable, Hashable {
    let id: UInt8
    let name: String
}

/// A user EQ stored on the buds: bands of (frequency in Hz, gain in dB) within min...max dB.
struct CustomEQ: Equatable {
    var id: UInt8
    var name: String
    var minGain: Int
    var maxGain: Int
    var bands: [(hz: Int, gain: Int)]

    static func == (a: CustomEQ, b: CustomEQ) -> Bool {
        a.id == b.id && a.name == b.name && a.minGain == b.minGain && a.maxGain == b.maxGain
            && a.bands.map(\.hz) == b.bands.map(\.hz) && a.bands.map(\.gain) == b.bands.map(\.gain)
    }
}

enum EQPresets {
    /// Built-in presets are fixed in firmware and not reported by the buds; IDs and names per model
    /// (from HeyMelody's tables via RawS-Music). Custom EQs come from the buds themselves (0x8122).
    static let byProduct: [String: [EQPreset]] = [
        NoiseLayouts.onePlusBuds4: [
            EQPreset(id: 0, name: "Balanced"),
            EQPreset(id: 1, name: "Vocal"),
            EQPreset(id: 2, name: "Bass"),
        ],
    ]
}

// MARK: - Gestures

enum EarSide: UInt8, CaseIterable, Identifiable {
    case left = 1, right = 2
    var id: UInt8 { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
}

/// Touch gestures in the music context. On the wire a gesture is two bytes: context (01 = music,
/// 06 = during a call) then the gesture code.
enum Gesture: UInt8, CaseIterable, Identifiable {
    case doubleTap = 2, tripleTap = 3, hold = 4
    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .doubleTap: "Double tap"
        case .tripleTap: "Triple tap"
        case .hold: "Touch & hold"
        }
    }
}

enum GestureAction: UInt8, CaseIterable, Identifiable {
    case none = 0x00, playPause = 0x01, assistant = 0x03, previous = 0x05, next = 0x06
    case noiseControl = 0x08, volumeUp = 0x0B, volumeDown = 0x0C, lowLatency = 0x11
    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .playPause: "Play / Pause"
        case .assistant: "Voice assistant"
        case .previous: "Previous track"
        case .next: "Next track"
        case .noiseControl: "Noise control"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .lowLatency: "Low latency"
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .playPause: "playpause.fill"
        case .assistant: "mic.fill"
        case .previous: "backward.fill"
        case .next: "forward.fill"
        case .noiseControl: "waveform"
        case .volumeUp: "speaker.plus.fill"
        case .volumeDown: "speaker.minus.fill"
        case .lowLatency: "gamecontroller.fill"
        }
    }
}
