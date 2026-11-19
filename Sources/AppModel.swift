import Foundation
import ServiceManagement
import SwiftUI

/// Shared app state: the buds connection, global shortcuts and the developer packet log.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let buds = BudsController()
    let packets = PacketLog()

    @Published var shortcuts: [ShortcutAction: Shortcut] = [:] {
        didSet { saveShortcuts(); registerShortcuts() }
    }
    /// Actions whose combination another app already owns.
    @Published private(set) var conflicts: Set<ShortcutAction> = []

    @AppStorage("showHUD") var showHUD = true
    @Published var developerMode = UserDefaults.standard.bool(forKey: "developerMode") {
        didSet {
            UserDefaults.standard.set(developerMode, forKey: "developerMode")
            updatePacketLogging()
        }
    }

    private init() {
        updatePacketLogging()
        if let data = UserDefaults.standard.data(forKey: "shortcuts"),
           let saved = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcuts = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                ShortcutAction(rawValue: key).map { ($0, value) }
            })
        }
        registerShortcuts()
    }

    func start() {
        buds.start()
    }

    private func updatePacketLogging() {
        if developerMode {
            buds.log = { [packets] direction, text in packets.append(direction, text) }
        } else {
            buds.log = nil
            packets.clear()
            packets.paused = false
        }
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .cycle: buds.cycleMode()
        case .anc: buds.setMode(.anc)
        case .transparency: buds.setMode(.transparency)
        case .off: buds.setMode(.off)
        }
        if showHUD, let mode = buds.mode { HUD.shared.show(mode: mode, level: buds.level, deviceName: buds.deviceName) }
    }

    /// While a recorder is listening, its keys must reach it instead of firing the old shortcut.
    func setRecording(_ recording: Bool) {
        if recording { HotKeyCenter.shared.unregisterAll() } else { registerShortcuts() }
    }

    private func registerShortcuts() {
        HotKeyCenter.shared.unregisterAll()
        var taken: Set<ShortcutAction> = []
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = shortcuts[action] else { continue }
            let ok = HotKeyCenter.shared.register(id: UInt32(index + 1), shortcut: shortcut) { [weak self] in
                self?.perform(action)
            }
            if !ok { taken.insert(action) }
        }
        if taken != conflicts { conflicts = taken }
    }

    private func saveShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: "shortcuts")
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                buds.log?(.info, "launch at login: \(error.localizedDescription)")
            }
        }
    }
}

/// In-memory packet log for the developer tab, kept apart from BudsController so it doesn't redraw the menu.
final class PacketLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let direction: BudsController.LogDirection
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published var paused = false

    func append(_ direction: BudsController.LogDirection, _ text: String) {
        guard !paused else { return }
        entries.append(Entry(direction: direction, text: text))
        if entries.count > 600 { entries.removeFirst(entries.count - 600) }
    }

    func clear() { entries = [] }

    var exportText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return entries.map { e in
            let tag = switch e.direction { case .sent: "→"; case .received: "←"; case .info: "·" }
            return "\(f.string(from: e.date)) \(tag) \(e.text)"
        }.joined(separator: "\n")
    }
}
