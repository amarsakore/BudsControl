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
    @AppStorage("developerMode") var developerMode = false

    private init() {
        buds.log = { [packets] direction, text in packets.append(direction, text) }
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
                packets.append(.info, "launch at login: \(error.localizedDescription)")
            }
        }
    }
}

/// Packet log for the developer tab. Kept apart from BudsController so logging doesn't redraw the menu.
final class PacketLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let direction: BudsController.LogDirection
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published var paused = false
    var echo: ((String) -> Void)?

    func append(_ direction: BudsController.LogDirection, _ text: String) {
        let arrow = switch direction { case .sent: "→ "; case .received: "← "; case .info: "" }
        echo?(arrow + text)
        Self.writeToFile(arrow + text)
        guard !paused else { return }
        entries.append(Entry(direction: direction, text: text))
        if entries.count > 600 { entries.removeFirst(entries.count - 600) }
    }

    func clear() { entries = [] }

    /// ~/Library/Logs/BudsControl.log, for diagnosing connection problems after the fact.
    /// Started fresh once it passes 2 MB.
    private static let file: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BudsControl.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 2_000_000 || size == 0 { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()
    private static let fileTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func writeToFile(_ line: String) {
        file?.write(Data("\(fileTime.string(from: Date())) \(line)\n".utf8))
    }

    var exportText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return entries.map { e in
            let tag = switch e.direction { case .sent: "→"; case .received: "←"; case .info: "·" }
            return "\(f.string(from: e.date)) \(tag) \(e.text)"
        }.joined(separator: "\n")
    }
}
