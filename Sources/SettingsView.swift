import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("developerMode") private var developerMode = false
    @StateObject private var ui = SettingsUIState()

    var body: some View {
        TabView(selection: $ui.tab) {
            GeneralSettings(model: model, buds: model.buds)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag("general")

            ShortcutSettings(model: model)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag("shortcuts")

            if developerMode {
                DeveloperSettings(buds: model.buds, log: model.packets)
                    .tabItem {
                        Label("Developer", systemImage: "hammer")
                    }
                    .tag("developer")
            }
        }
        .frame(width: 560)
        .frame(minHeight: 420)
        .onChange(of: developerMode) { _, on in if !on && ui.tab == "developer" { ui.tab = "general" } }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var buds: BudsController
    @AppStorage("showHUD") private var showHUD = true
    @AppStorage("developerMode") private var developerMode = false
    @AppStorage("autoConnect") private var autoConnect = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "airpodspro")
                        .font(.system(size: 26))
                        .frame(width: 52, height: 52)
                        .circleGlass()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(buds.deviceName).font(.headline)
                        Text(status).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reconnect") { buds.reconnect() }
                        .buttonStyle(.glass)
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                         set: { model.launchAtLogin = $0 }))
                Toggle(isOn: $autoConnect) {
                    Text("Reconnect buds to this Mac automatically")
                    Text("When the buds come out of the case and only join your phone, bring them back here too.")
                }
                Toggle("Show HUD when a shortcut changes mode", isOn: $showHUD)
            }

            Section {
                Toggle(isOn: $developerMode) {
                    Text("Show developer options")
                    Text("Packet log, raw commands and undocumented modes.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var status: String {
        switch buds.link {
        case .connected: "Connected" + (buds.productID.map { " · model \($0)" } ?? "")
        case .connecting: "Connecting…"
        case .searching: "Not connected"
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(shortcut: binding(for: action),
                                         onRecordingChange: model.setRecording)
                    } label: {
                        Label {
                            Text(action.title)
                            if model.conflicts.contains(action) {
                                Text("Used by another app — pick a different combination.")
                                    .foregroundStyle(.red)
                            }
                        } icon: {
                            Image(systemName: action.symbol)
                        }
                    }
                }
            } footer: {
                Text("Shortcuts work everywhere, even when Buds Control isn't in front. Include ⌘, ⌥, ⌃ or ⇧ (or use an F-key).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for action: ShortcutAction) -> Binding<Shortcut?> {
        Binding(get: { model.shortcuts[action] }, set: { model.shortcuts[action] = $0 })
    }
}

// MARK: - Developer

private struct DeveloperSettings: View {
    @ObservedObject var buds: BudsController
    @ObservedObject var log: PacketLog
    @StateObject private var raw = SettingsUIState()

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Name", value: buds.deviceName)
                LabeledContent("Address", value: buds.address ?? "—")
                LabeledContent("RFCOMM channel", value: buds.channelID.map(String.init) ?? "—")
                LabeledContent("Product ID", value: buds.productID ?? "—")
                LabeledContent("Active noise bit", value: buds.noiseBit.map { "bit \($0)" } ?? "—")
            }

            Section {
                ForEach(buds.layout.keys.sorted(), id: \.self) { bit in
                    HStack {
                        Text("bit \(bit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                        Text(NoiseLayouts.typeName(buds.layout[bit]!))
                        Spacer()
                        if buds.noiseBit == bit {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        } else {
                            Button("Apply") { buds.setNoiseBit(bit) }.buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Noise modes")
            } footer: {
                Text("Every mode bit HeyMelody lists for this model, including ones the main menu doesn't show.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(get: { buds.gameMode ?? false }, set: { buds.setGameMode($0) })) {
                    Text("Game mode (low latency)")
                    Text(buds.gameMode == nil ? "The buds don't report this until it changes." : "Reported by the buds.")
                }
            } header: {
                Text("Experimental")
            }

            if !buds.hosts.isEmpty {
                Section("Paired devices (multipoint)") {
                    ForEach(buds.hosts) { host in
                        LabeledContent {
                            Text(host.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                        } label: {
                            Text(host.name + (host.isThisMac ? " (this Mac)" : ""))
                            Text(host.connected ? "Connected" : "Not connected")
                        }
                    }
                }
            }

            Section {
                HStack {
                    TextField("Command", text: $raw.commandHex, prompt: Text("0106"))
                        .font(.body.monospaced())
                        .frame(width: 90)
                    TextField("Payload", text: $raw.payloadHex, prompt: Text("payload hex, e.g. 01 01"))
                        .font(.body.monospaced())
                    Button("Send", action: sendRaw)
                        .buttonStyle(.glassProminent)
                        .disabled(UInt16(raw.commandHex.filter(\.isHexDigit), radix: 16) == nil)
                }
                .labelsHidden()
                HStack {
                    Button("Product ID") { buds.sendRaw(command: Command.productID, payload: []) }
                    Button("Battery") { buds.sendRaw(command: Command.battery, payload: []) }
                    Button("Noise mode") { buds.sendRaw(command: Command.noiseQuery, payload: [1, 1]) }
                    Spacer()
                    Button("Scan 0x0101–0x0120") { buds.scanQueries() }
                        .help("Sends every query command once; answers show up in the packet log.")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            } header: {
                Text("Raw command")
            } footer: {
                Text("Frames are wrapped automatically (AA, length, sequence). Commands outside 0x01xx can change settings on the buds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                PacketList(log: log)
                    .frame(height: 220)
                HStack {
                    Toggle("Pause", isOn: $log.paused).toggleStyle(.checkbox)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.exportText, forType: .string)
                    }
                    Button("Clear") { log.clear() }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            } header: {
                Text("Packet log")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 620)
    }

    private func sendRaw() {
        guard let cmd = UInt16(raw.commandHex.filter(\.isHexDigit), radix: 16) else { return }
        let digits = Array(raw.payloadHex.filter(\.isHexDigit))
        let payload = stride(from: 0, to: digits.count - 1, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
        buds.sendRaw(command: cmd, payload: payload)
    }
}

private struct PacketList: View {
    @ObservedObject var log: PacketLog
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(log.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.time.string(from: entry.date)).foregroundStyle(.tertiary)
                            Image(systemName: icon(entry.direction))
                                .foregroundStyle(color(entry.direction))
                                .frame(width: 12)
                            Text(entry.text)
                                .foregroundStyle(entry.direction == .info ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            .onChange(of: log.entries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func icon(_ d: BudsController.LogDirection) -> String {
        switch d { case .sent: "arrow.up"; case .received: "arrow.down"; case .info: "info.circle" }
    }

    private func color(_ d: BudsController.LogDirection) -> Color {
        switch d { case .sent: .blue; case .received: .green; case .info: .secondary }
    }
}

private final class SettingsUIState: ObservableObject {
    @Published var tab = "general"
    @Published var commandHex = "0106"
    @Published var payloadHex = ""
}
