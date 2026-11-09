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
/// Handles LEB128 multi-byte frame lengths for bulk packets (e.g. multipoint device lists).
struct FrameParser {
    private var buffer: [UInt8] = []

    mutating func feed(_ data: [UInt8]) -> [Frame] {
        buffer += data
        var frames: [Frame] = []
        var i = 0
        while i < buffer.count {
            guard buffer[i] == 0xAA else { i += 1; continue }
            var pos = i + 1
            var totalLen = 0
            var shift = 0
            var complete = false
            while pos < buffer.count {
                let byte = buffer[pos]
                totalLen |= Int(byte & 0x7F) << shift
                pos += 1
                if byte & 0x80 == 0 {
                    complete = true
                    break
                }
                shift += 7
                if shift > 21 { break }
            }
            guard complete else { break }
            let frameEnd = pos + totalLen
            guard frameEnd <= buffer.count else { break }

            let headerOffset = pos + 2
            if headerOffset + 5 <= frameEnd {
                let cmd = UInt16(buffer[headerOffset]) | (UInt16(buffer[headerOffset + 1]) << 8)
                let seq = buffer[headerOffset + 2]
                let payloadLen = Int(buffer[headerOffset + 3]) | (Int(buffer[headerOffset + 4]) << 8)
                let payloadStart = headerOffset + 5
                let payloadEnd = min(payloadStart + payloadLen, frameEnd)
                frames.append(Frame(command: cmd, seq: seq, payload: Array(buffer[payloadStart..<payloadEnd])))
            }
            i = frameEnd
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
    case smart, max, moderate, mild, adaptive
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// HeyMelody "modeType" for this level.
    var modeType: Int {
        switch self {
        case .mild: 3
        case .max: 4
        case .smart: 7
        case .moderate: 8
        case .adaptive: 10
        }
    }

    init?(modeType: Int) {
        guard let level = Self.allCases.first(where: { $0.modeType == modeType }) else { return nil }
        self = level
    }
}

/// HeyMelody "modeType": what a noise-mode bit means. Which bit carries which type is per model
/// (see DeviceModel).
enum ModeType {
    static let off = 1
    static let transparency = 2
    static let anc = 5  // ANC without a level, on models that have no levels

    static func mode(_ type: Int) -> NoiseMode {
        switch type {
        case 1: .off
        case 2, 6: .transparency
        default: .anc
        }
    }

    /// Human-readable name, for the developer view.
    static func name(_ type: Int) -> String {
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
    /// English names for HeyMelody's EQ "modeType"s (translated from the app's Chinese titles, via
    /// RawS-Music). Built-in presets aren't reported by the buds, so the catalog lists each model's.
    static func name(forModeType type: Int) -> String {
        switch type {
        case 1: "Classic"
        case 2: "Bass boost"
        case 3: "Clear vocals"
        case 4: "Bright"
        case 5, 35: "Default"
        case 6, 36: "Dynaudio Natural"
        case 7, 37: "Dynaudio Warm"
        case 8, 38: "Dynaudio Bold"
        case 9, 39: "Dynaudio Pure"
        case 10: "Joe Hisaishi"
        case 11, 17: "Balanced"
        case 12: "Bass"
        case 13: "Bright"
        case 14: "Vocal"
        case 15: "Mellow"
        case 16: "Classic"
        case 18: "Reno Dawn"
        case 19: "Hans Zimmer"
        case 20: "Natural"
        case 21: "Reno Sunrise"
        case 22: "Pure"
        case 23: "Bold"
        case 24: "Spacious"
        case 25: "Reno Galaxy"
        case 26: "Ultimate"
        case 27: "Detailed"
        case 28: "Pure vocals"
        case 29: "Big bass"
        case 30: "Dynaudio"
        case 31: "Punchy bass"
        case 32: "Warm vocals"
        case 33: "Galaxy"
        case 34: "Vibrant"
        case 40: "Dynaudio Vocal"
        case 41: "Clear"
        default: "Preset \(type)"
        }
    }
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
    case none = 0x00, playPause = 0x01, assistant = 0x03, assistantRealme = 0x04, previous = 0x05, next = 0x06
    case noiseControl = 0x08, volumeUp = 0x0B, volumeDown = 0x0C, lowLatency = 0x11
    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .playPause: "Play / Pause"
        case .assistant, .assistantRealme: "Voice assistant"
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
        case .assistant, .assistantRealme: "mic.fill"
        case .previous: "backward.fill"
        case .next: "forward.fill"
        case .noiseControl: "waveform"
        case .volumeUp: "speaker.plus.fill"
        case .volumeDown: "speaker.minus.fill"
        case .lowLatency: "gamecontroller.fill"
        }
    }
}
