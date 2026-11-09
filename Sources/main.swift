import SwiftUI
import IOBluetooth

struct BudsControlApp: App {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var buds = AppModel.shared.buds

    init() {
        AppModel.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(buds: buds)
        } label: {
            // Earbuds glyph inside a ring showing the earbuds' battery; dimmed while disconnected.
            Image(nsImage: MenuBarIcon.image(level: buds.budsBattery, connected: buds.link == .connected))
        }
        .menuBarExtraStyle(.window)

        Window("Buds Control Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
    }
}

let args = CommandLine.arguments
if args.contains("--sdp") {
    // Lists the RFCOMM services the buds advertise, to debug channel selection.
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    guard let d = paired.first(where: { $0.isConnected() && ($0.name ?? "").lowercased().contains("buds") }) else {
        print("no connected buds"); exit(1)
    }
    print("performSDPQuery:", d.performSDPQuery(nil))
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        for case let r as IOBluetoothSDPServiceRecord in d.services ?? [] {
            var ch: BluetoothRFCOMMChannelID = 0
            let hasRFCOMM = r.getRFCOMMChannelID(&ch) == kIOReturnSuccess
            print("\(r.getServiceName() ?? "?")  rfcomm=\(hasRFCOMM ? String(ch) : "-")")
        }
        exit(0)
    }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--watch") {
    // Logs everything the buds send, for N seconds.
    let seconds = Double(args.count > i + 1 ? args[i + 1] : "60") ?? 60
    let started = Date()
    func stamp() -> String { String(format: "[%6.2fs] ", Date().timeIntervalSince(started)) }
    let buds = BudsController()
    buds.log = { dir, text in
        let arrow = switch dir { case .sent: "-> "; case .received: "<- "; case .info: "" }
        print(stamp() + arrow + text); fflush(stdout)
    }
    buds.onHostsChange = { hosts in
        print(stamp() + "HOSTS " + hosts.map { "\($0.name) connected=\($0.connected) self=\($0.isThisMac)" }
            .joined(separator: " | ")); fflush(stdout)
    }
    buds.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--scan") {
    // Sends every query once and prints the last reply to each, for diffing between states.
    let label = args.count > i + 1 ? args[i + 1] : "scan"
    let buds = BudsController()
    var replies: [UInt16: [UInt8]] = [:]
    buds.onFrame = { f in replies[f.command] = f.payload }
    buds.start()
    var queries: [(UInt16, [UInt8])] = (UInt16(0x0101)...UInt16(0x0120)).map { ($0, []) }
    queries.append((0x010C, [0x01, 0x01]))
    queries.append((0x010D, [0x2F] + Array(UInt8(1)...UInt8(0x2F))))
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        for (n, q) in queries.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.09) { buds.sendRaw(command: q.0, payload: q.1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(queries.count) * 0.09 + 2) {
            for cmd in replies.keys.sorted() {
                print(label, String(format: "0x%04X", cmd), replies[cmd]!.map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            exit(buds.link == .connected ? 0 : 1)
        }
    }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--raw") {
    // Sends each "CMD:PAYLOAD" (hex) argument 2.5 s apart and logs every packet.
    let started = Date()
    let buds = BudsController()
    buds.log = { dir, text in
        let arrow = switch dir { case .sent: "-> "; case .received: "<- "; case .info: "" }
        print(String(format: "[%6.2fs] ", Date().timeIntervalSince(started)) + arrow + text); fflush(stdout)
    }
    buds.start()
    let commands = args[(i + 1)...].map { $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
    for (n, parts) in commands.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(n) * 2.5) {
            let digits = Array(parts.count > 1 ? parts[1] : "")
            let payload = stride(from: 0, to: digits.count - 1, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
            buds.sendRaw(command: UInt16(parts[0], radix: 16) ?? 0, payload: payload)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(commands.count) * 2.5) { exit(0) }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--cli") {
    // Command-line mode for debugging and scripting, e.g.:
    //   BudsControl.app/Contents/MacOS/BudsControl --cli status
    //   BudsControl.app/Contents/MacOS/BudsControl --cli anc|transparency|off|smart|max|moderate|mild
    //   ... --cli eq=0 | custom=5,0,3,1,4,3 | lowlatency=on | find=on | gesture=left,doubleTap,next
    let action = args.count > i + 1 ? args[i + 1] : "status"
    let buds = BudsController()
    let started = Date()
    buds.log = { dir, text in
        let arrow = switch dir { case .sent: "-> "; case .received: "<- "; case .info: "" }
        print(String(format: "[%5.0fms] ", Date().timeIntervalSince(started) * 1000) + arrow + text)
    }

    // Like a shortcut press: request the mode right away, before the link is even up.
    if let mode = NoiseMode(rawValue: action) {
        buds.setMode(mode)
    } else if let level = ANCLevel(rawValue: action) {
        buds.setMode(.anc, level: level)
    }
    buds.start()

    // Settings beyond noise control need the buds' current state first, so wait for it.
    let parts = action.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 {
        var done = false
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            guard !done, buds.link == .connected, buds.eqID != nil, !buds.gestures.isEmpty else { return }
            done = true
            let value = parts[1]
            switch parts[0] {
            case "eq": UInt8(value).map(buds.setEQ)
            case "custom": buds.setCustomEQ(gains: value.split(separator: ",").compactMap { Int($0) })
            case "lowlatency": buds.setGameMode(value == "on")
            case "find": buds.findBuds(value == "on")
            case "gesture":
                let g = value.split(separator: ",").map(String.init)
                if g.count == 3, let side = EarSide.allCases.first(where: { "\($0)" == g[0] }),
                   let gesture = Gesture.allCases.first(where: { "\($0)" == g[1] }),
                   let act = GestureAction.allCases.first(where: { "\($0)" == g[2] }) {
                    buds.setGesture(act, for: gesture, side: side)
                }
            default: print("unknown action \(parts[0])")
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        print("device:  \(buds.deviceName) [\(buds.productID ?? "?")] \(buds.link)")
        print("mode:    \(buds.mode?.rawValue ?? "unknown")\(buds.level.map { " (\($0.rawValue))" } ?? "")"
              + (buds.noiseBit.map { " [bit \($0)]" } ?? ""))
        print("battery: L \(buds.left?.level ?? -1)%  R \(buds.right?.level ?? -1)%  case \(buds.caseBattery?.level ?? -1)%")
        print("eq:      \(buds.eqID.map(String.init) ?? "?") \(buds.eqChoices.first { $0.id == buds.eqID }?.name ?? "")"
              + (buds.activeCustomEQ.map { " " + $0.bands.map { "\($0.hz)Hz:\($0.gain)" }.joined(separator: " ") } ?? ""))
        print("lowlat:  \(buds.gameMode.map { $0 ? "on" : "off" } ?? "?")")
        print("model:   \(buds.model.name.isEmpty ? "not in catalog" : buds.model.name), capability bits: "
              + (buds.capabilities.map { "\($0.count)" } ?? "none"))
        print("modes:   \(buds.availableModes.map(\.rawValue)) levels: \(buds.availableLevels.map(\.rawValue))")
        print("shows:   " + DeviceFeature.allCases.filter(buds.supports).map { "\($0)" }.joined(separator: " "))
        for side in EarSide.allCases {
            print("gesture: \(side) " + Gesture.allCases.map { "\($0)=\(buds.gestures[side]?[$0].map { "\($0)" } ?? "?")" }
                .joined(separator: " "))
        }
        exit(buds.link == .connected ? 0 : 1)
    }
    RunLoop.main.run()
} else {
    BudsControlApp.main()
}
