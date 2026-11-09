import Foundation

enum Brand {
    case oneplus, oppo, realme
}

/// Settings that only some models have. The popover shows one only when nothing rules it out:
/// the catalog lists it (when the catalog knows the model), the buds' capability reply has its bit
/// set (when they send one), and the buds have answered a query for it.
enum DeviceFeature: CaseIterable {
    case noiseControl, equalizer, customEQ, lowLatency, findBuds, gestures

    /// Bit in the buds' capability bitmap (reply to 0x0100) for the commands this feature uses,
    /// per HeyMelody's capability map (via RawS-Music).
    var capabilityBit: Int {
        switch self {
        case .gestures: 3        // 0x0108 / 0x0401
        case .findBuds: 5        // 0x0400
        case .lowLatency: 7      // 0x0403
        case .noiseControl: 8    // 0x010C / 0x0404
        case .equalizer: 10      // 0x010F / 0x0406
        case .customEQ: 34       // 0x0122 / 0x0418
        }
    }
}

/// What one earbuds model supports. Generated entries live in DeviceCatalog.swift.
struct DeviceModel {
    let name: String
    let brand: Brand
    /// Noise modes the model offers, as HeyMelody modeTypes.
    let modeTypes: [Int]
    /// bit -> modeType layout used to *set* a mode (proven on real buds by oppo-pods).
    let setBits: [Int: Int]
    /// Every bit -> modeType the buds may *report*; a superset of setBits on some models.
    let reportedBits: [Int: Int]
    /// Built-in EQ presets: (preset ID, EQ modeType).
    let eqPresets: [(UInt8, Int)]
    /// nil when the source data doesn't say; the buds' replies decide then.
    let features: Set<DeviceFeature>?

    /// The bit to send for a mode type: the proven set layout first, then the reported layout.
    func bit(forType type: Int) -> Int? {
        setBits.filter { $0.value == type }.keys.min() ?? reportedBits.filter { $0.value == type }.keys.min()
    }
}

enum DeviceCatalog {
    /// Buds the catalog doesn't know: the layout most HeyMelody models share, limited to
    /// Off / Transparency / ANC because unknown models' ANC levels can't be trusted.
    static let generic = DeviceModel(
        name: "", brand: .oppo, modeTypes: [1, 2, 5],
        setBits: [0: 1, 1: 5, 2: 2, 3: 1, 8: 2],
        reportedBits: [0: 1, 1: 5, 2: 2, 3: 1, 4: 4, 5: 8, 6: 3, 7: 7, 8: 2],
        eqPresets: [], features: nil)

    /// realme Link uses one layout for all its earbuds: off, transparency, mild, max, moderate, smart
    /// (oppo-pods; matches Gadgetbridge's realme codes).
    static let genericRealme = DeviceModel(
        name: "", brand: .realme, modeTypes: [1, 2, 3, 4, 7, 8],
        setBits: [0: 1, 1: 2, 2: 3, 3: 4, 4: 8, 5: 7],
        reportedBits: [0: 1, 1: 2, 2: 3, 3: 4, 4: 8, 5: 7],
        eqPresets: [], features: nil)

    static func model(productID: String?, deviceName: String?) -> DeviceModel {
        if let productID, let model = models[productID] { return model }
        // realme product IDs end in 12 or 52 (OnePlus 14/54, OPPO 10/50).
        let realme = deviceName?.lowercased().contains("realme") == true
            || productID.map { $0.hasSuffix("12") || $0.hasSuffix("52") } == true
        return realme ? genericRealme : generic
    }
}
