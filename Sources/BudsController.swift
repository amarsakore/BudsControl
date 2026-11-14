import AppKit
import IOBluetooth

/// Owns the RFCOMM link to the earbuds and the state shown in the UI.
/// IOBluetooth delivers its callbacks on the main run loop, so everything here lives on the main thread.
final class BudsController: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
    enum LinkState: Equatable {
        case searching, connecting, connected
    }

    struct Battery: Equatable {
        var level: Int
        var charging: Bool
    }

    /// A device the buds are paired with (multipoint), from command 0x0112 / push type 6.
    struct Host: Identifiable, Equatable {
        var id: String { address }
        var address: String  // AA:BB:CC:DD:EE:FF
        var name: String
        var connected: Bool
        var isThisMac: Bool
    }

    enum Wear: Int { case inCase = 0, outOfEar = 1, inEar = 3 }

    @Published private(set) var link: LinkState = .searching {
        didSet { if link == .connecting && oldValue != .connecting { armConnectingWatchdog() } }
    }
    @Published private(set) var deviceName = "Earbuds"
    @Published private(set) var productID: String?
    @Published private(set) var mode: NoiseMode?
    @Published private(set) var level: ANCLevel? {
        didSet { if let level { UserDefaults.standard.set(level.rawValue, forKey: "lastANCLevel") } }
    }
    @Published private(set) var noiseBit: Int?
    @Published private(set) var left: Battery?
    @Published private(set) var right: Battery?
    @Published private(set) var caseBattery: Battery?
    /// Low-latency ("game") mode.
    @Published private(set) var gameMode: Bool?
    @Published private(set) var eqID: UInt8?
    @Published private(set) var customEQs: [CustomEQ] = []
    @Published private(set) var gestures: [EarSide: [Gesture: GestureAction]] = [:]
    @Published private(set) var findingBuds = false
    @Published private(set) var hosts: [Host] = []
    @Published private(set) var wear: [Int: Wear] = [:]  // 1 left, 2 right
    @Published private(set) var channelID: BluetoothRFCOMMChannelID?
    @Published private(set) var address: String?

    /// Capability bits from the buds' reply to hello (0x8100); nil until (or unless) they send one.
    @Published private(set) var capabilities: Set<Int>?

    /// What this model supports: the catalog entry for its product ID, or a safe generic one.
    var model: DeviceModel { DeviceCatalog.model(productID: productID, deviceName: deviceName) }
    /// Every bit -> modeType the buds may report (the developer view lists these).
    var layout: [Int: Int] { model.reportedBits }
    var availableModes: [NoiseMode] {
        NoiseMode.allCases.filter { mode in model.modeTypes.contains { ModeType.mode($0) == mode } }
    }
    var availableLevels: [ANCLevel] { ANCLevel.allCases.filter { model.modeTypes.contains($0.modeType) } }

    /// Whether to show a setting: nothing may rule it out (catalog, capability bit), and the buds must
    /// have answered for it, so a control never appears for something the model can't do.
    func supports(_ feature: DeviceFeature) -> Bool {
        if let features = model.features, !features.contains(feature) { return false }
        if let capabilities, !capabilities.contains(feature.capabilityBit) { return false }
        switch feature {
        case .noiseControl: return mode != nil && !availableModes.isEmpty
        case .equalizer: return eqID != nil && !eqChoices.isEmpty
        case .customEQ: return !customEQs.isEmpty
        case .lowLatency: return gameMode != nil
        case .gestures: return !gestures.isEmpty
        // No query to confirm it, so it needs positive word from the catalog or the capability bits.
        case .findBuds: return model.features != nil || capabilities != nil
        }
    }

    var hasMoreControls: Bool { [.equalizer, .lowLatency, .findBuds, .gestures].contains(where: supports) }

    /// Built-in presets for this model followed by the custom EQs stored on the buds.
    var eqChoices: [EQPreset] {
        model.eqPresets.map { EQPreset(id: $0.0, name: EQPresets.name(forModeType: $0.1)) }
            + customEQs.map { EQPreset(id: $0.id, name: $0.name) }
    }

    /// Gesture actions for this brand (realme has its own assistant code and no noise-control
    /// gesture), plus noise control / low latency only when the buds have them.
    func gestureActions(current: GestureAction?) -> [GestureAction] {
        var actions: [GestureAction] = model.brand == .realme
            ? [.none, .playPause, .previous, .next, .volumeUp, .volumeDown, .assistantRealme]
            : [.none, .playPause, .assistant, .previous, .next, .volumeUp, .volumeDown]
        if model.brand != .realme, supports(.noiseControl) { actions.append(.noiseControl) }
        if supports(.lowLatency) { actions.append(.lowLatency) }
        if let current, !actions.contains(current) { actions.append(current) }
        return actions
    }
    var activeCustomEQ: CustomEQ? { customEQs.first { $0.id == eqID } }
    /// Lowest earbud level, for the menu bar ring.
    var budsBattery: Int? { [left?.level, right?.level].compactMap { $0 }.min() }

    /// Receives a line for every packet sent/received and every connection event.
    var log: ((LogDirection, String) -> Void)?
    enum LogDirection { case sent, received, info }
    /// Called whenever the multipoint host list changes.
    var onHostsChange: (([Host]) -> Void)?
    /// Every decoded frame from the buds (developer tooling).
    var onFrame: ((Frame) -> Void)?

    // HeyMelody advertises both UUIDs on different generations of buds.
    private static let serviceUUIDs = [
        IOBluetoothSDPUUID(bytes: [
            0x00, 0x00, 0x07, 0x9A, 0xD1, 0x02, 0x11, 0xE1, 0x9B, 0x23, 0x00, 0x02, 0x5B, 0x00, 0xA5, 0xA5,
        ] as [UInt8], length: 16),
        IOBluetoothSDPUUID(bytes: [
        0x00, 0x00, 0x11, 0x07, 0xD1, 0x02, 0x11, 0xE1, 0x9B, 0x23, 0x00, 0x02, 0x5B, 0x00, 0xA5, 0xA5,
        ] as [UInt8], length: 16)
    ]
    /// realme buds take control commands on the standard serial-port service (Gadgetbridge).
    private static let standardSPP = IOBluetoothSDPUUID(uuid16: 0x1101)
    private static let fallbackChannels: [BluetoothRFCOMMChannelID] = [15, 12, 13]
    private static let retryDelays: [TimeInterval] = [1, 2, 3, 5, 8]

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var pendingChannels: [BluetoothRFCOMMChannelID] = []
    private var parser = FrameParser()
    private var seq: UInt8 = 0
    private var retryTimer: Timer?
    private var retryCount = 0
    /// Control-channel opens that failed in a row, and when the next one may start. If the buds
    /// disconnect while the Mac sleeps, IOBluetooth can go on reporting them as connected, and
    /// every open just pages buds that aren't there. So after two failures, wait 6 s, 12 s, …
    /// up to 5 min between tries, until the buds really connect or a reconnect is asked for.
    private var failedOpens = 0
    private var nextOpen = Date.distantPast
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private var lastReceived = Date.distantPast
    private var watchdog: DispatchWorkItem?
    private var pageInFlight = false
    private var openingChannelID: BluetoothRFCOMMChannelID?
    private var connectingWatchdog: DispatchWorkItem?
    private var lastPage = Date.distantPast
    private var findTimer: Timer?
    private var channelOpenNotification: IOBluetoothUserNotification?
    /// RFCOMM channel IDs that carry the control protocol on the current buds.
    private var controlChannelIDs: Set<BluetoothRFCOMMChannelID> = []

    /// Whether to reconnect the buds to this Mac when they're around but connected elsewhere only.
    var autoConnect: () -> Bool = { UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true }
    /// Whether to put back the noise mode and low latency last picked in the app when the buds connect.
    var rememberSettings: () -> Bool = { UserDefaults.standard.bool(forKey: "rememberSettings") }
    /// Set when the link comes up; cleared once the buds' first reading has been checked against
    /// the remembered settings.
    private var restoreNoise = false
    private var restoreLowLatency = false

    /// Noise queries still in flight. Answers to queries sent before the latest mode change describe
    /// the old mode, so they're dropped instead of flipping the UI back for a moment.
    private var outstandingNoiseQueries: Set<UInt8> = []
    private var staleNoiseQueries: Set<UInt8> = []
    /// In-flight EQ changes awaiting confirmation from the buds.
    private var pendingEQID: UInt8?
    private var eqGeneration: Int = 0
    private var eqWatchdog: DispatchWorkItem?
    /// A mode change requested while the link was down; sent as soon as it comes up.
    private var queuedMode: (NoiseMode, ANCLevel?)?

    override init() {
        super.init()
        // Show the buds' Bluetooth name straight away, even before they connect.
        if let name = pairedBuds()?.name { deviceName = name }
        // Reconnect as soon as the buds come back (taken out of the case, back in range).
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceDidConnect(_:device:)))
        // After sleep the link may be dead without a close callback, or still fine. Check it: a
        // refresh that gets no reply reconnects (expectReply), a working link is left alone.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.log?(.info, "woke from sleep, checking the connection")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                if self.link == .connected { self.refresh() } else { self.restart() }
            }
        }
        // IOBluetooth can reopen a control channel by itself when the buds come back (e.g. one from
        // before sleep). The app must take that channel over: asking again only gets "already
        // connected" from bluetoothd, and the open never completes.
        channelOpenNotification = IOBluetoothRFCOMMChannel.register(forChannelOpenNotifications: self,
                                                                    selector: #selector(channelDidOpen(_:channel:)))
    }

    // MARK: - Public API

    func start() {
        connect()
        pollTimer = Self.timer(30, repeats: true) { [weak self] in self?.refresh() }
        // Safety net for every path above: if the buds are connected to this Mac but the app
        // isn't talking to them, connect — no Retry click needed.
        healthTimer = Self.timer(3, repeats: true) { [weak self] in
            guard let self, self.link == .searching, Date() >= self.nextOpen, self.findBuds() != nil else { return }
            self.log?(.info, "buds are connected but the app isn't, connecting")
            self.retryCount = 0
            self.connect()
        }
    }

    /// Timers in the common run-loop modes, so they also fire while a menu or the popover is open.
    private static func timer(_ interval: TimeInterval, repeats: Bool, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Asked for (or the link just broke), so it also skips any wait from earlier failures.
    func reconnect() {
        failedOpens = 0
        restart()
    }

    /// One try straight away; if it fails, the wait from earlier failures carries on growing.
    private func restart() {
        closeChannel()
        retryCount = 0
        nextOpen = .distantPast
        connect()
    }

    func refresh() {
        guard link == .connected else { return }
        // Pick up a rename made in System Settings › Bluetooth while connected.
        if let name = device?.name, name != deviceName { deviceName = name }
        send(Command.battery)
        queryNoise()
        expectReply()
    }

    /// Switches immediately: the UI updates before the buds answer, and their acknowledgement
    /// triggers a single confirming query.
    func setMode(_ mode: NoiseMode, level: ANCLevel? = nil) {
        guard link == .connected else {
            queuedMode = (mode, level)
            if link == .searching { reconnect() }
            return
        }
        // Plain "ANC" uses the last level picked, so the level row always shows a selection;
        // models without levels use their plain ANC mode.
        var level = level
        if mode == .anc, level == nil, !availableLevels.isEmpty {
            level = self.level ?? UserDefaults.standard.string(forKey: "lastANCLevel").flatMap(ANCLevel.init(rawValue:))
            if level.map(availableLevels.contains) != true { level = availableLevels.first }
        }
        let type = switch mode {
        case .off: ModeType.off
        case .transparency: ModeType.transparency
        case .anc: level?.modeType ?? ModeType.anc
        }
        guard let bit = model.bit(forType: type) else {
            log?(.info, "mode \(mode) not supported by \(productID ?? "unknown model")")
            return
        }
        self.mode = mode
        self.level = mode == .anc ? level : nil
        remember { $0.mode = mode.rawValue; $0.level = level?.rawValue }
        setNoiseBit(bit)
    }

    func cycleMode() {
        let order: [NoiseMode] = [.anc, .transparency, .off].filter(availableModes.contains)
        guard !order.isEmpty else { return }
        let next = order[((order.firstIndex(of: mode ?? .off) ?? order.count - 1) + 1) % order.count]
        setMode(next)
    }

    /// Developer: set any bit of the noise-mode mask, including ones the UI doesn't name.
    func setNoiseBit(_ bit: Int) {
        // Payload: 01 01 <little-endian bitmask with the mode's bit set>
        let mask = 1 << bit
        var payload: [UInt8] = [0x01, 0x01]
        for i in 0...(bit / 8) { payload.append(UInt8((mask >> (8 * i)) & 0xFF)) }
        staleNoiseQueries.formUnion(outstandingNoiseQueries)
        noiseBit = bit
        if let type = layout[bit] {
            mode = ModeType.mode(type)
            if let lvl = ANCLevel(modeType: type) { level = lvl }
        }
        send(Command.setNoise, payload)
        expectReply()
    }

    /// Developer: low-latency "game mode" switch (misc config 0x06).
    func setGameMode(_ on: Bool) {
        gameMode = on
        remember { $0.lowLatency = on }
        send(Command.setSwitch, [Feature.lowLatency, on ? 1 : 0])
        expectReply()
    }

    /// Waits for the buds to confirm `id`: a 0x0504 push or a matching read-back clears it;
    /// otherwise re-read after 1.2 s and take whatever the buds report.
    private func expectEQ(_ id: UInt8, list: Bool = false) {
        pendingEQID = id
        eqGeneration &+= 1
        let gen = eqGeneration
        eqWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.eqGeneration == gen else { return }
            self.pendingEQID = nil
            self.send(Command.eqQuery)
            if list { self.send(Command.eqListQuery, [0x01, 0x05]) }
        }
        eqWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func setEQ(_ id: UInt8) {
        eqID = id
        expectEQ(id)
        send(Command.setEQ, [id])
        expectReply()
    }

    /// Rewrites the active custom EQ's band gains (HeyMelody setEqInfo, action 2 = apply existing).
    /// Payload: 02 <min> <max> <id> <name len> <name> <band count> (<Hz lo> <Hz hi> <gain>)*
    func setCustomEQ(gains: [Int]) {
        guard var eq = activeCustomEQ ?? customEQs.first,
              let index = customEQs.firstIndex(where: { $0.id == eq.id }) else { return }
        for i in eq.bands.indices where i < gains.count {
            eq.bands[i].gain = min(max(gains[i], eq.minGain), eq.maxGain)
        }
        customEQs[index] = eq
        eqID = eq.id
        expectEQ(eq.id, list: true)
        let name = Array(eq.name.utf8.prefix(255))
        var payload: [UInt8] = [0x02, UInt8(bitPattern: Int8(eq.minGain)), UInt8(bitPattern: Int8(eq.maxGain)), eq.id,
                                UInt8(name.count)]
        payload += name
        payload.append(UInt8(eq.bands.count))
        for band in eq.bands {
            payload += [UInt8(band.hz & 0xFF), UInt8((band.hz >> 8) & 0xFF), UInt8(bitPattern: Int8(band.gain))]
        }
        send(Command.setCustomEQ, payload)
        expectReply()
    }

    /// Plays the buds' locator sound. It's loud; it stops by itself after 30 s.
    func findBuds(_ start: Bool) {
        findingBuds = start
        send(Command.findBuds, [start ? 1 : 0])
        findTimer?.invalidate()
        if start {
            findTimer = Self.timer(30, repeats: false) { [weak self] in self?.findBuds(false) }
        }
    }

    /// Payload: 01 <side> <context 01 = music> <gesture> <action>
    func setGesture(_ action: GestureAction, for gesture: Gesture, side: EarSide) {
        gestures[side, default: [:]][gesture] = action
        send(Command.setGesture, [0x01, side.rawValue, 0x01, gesture.rawValue, action.rawValue])
        expectReply()
    }

    func queryHosts() { send(Command.multipointQuery) }

    /// Developer: send an arbitrary command.
    func sendRaw(command: UInt16, payload: [UInt8]) {
        send(command, payload)
    }

    /// Developer: fire every 0x01xx query and let the packet log show what answers.
    func scanQueries() {
        for (i, cmd) in (UInt16(0x0101)...UInt16(0x0120)).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) { [weak self] in
                self?.send(cmd)
            }
        }
    }

    // MARK: - Connection

    /// Connected buds, preferring ones that advertise the HeyMelody control service.
    private func findBuds() -> IOBluetoothDevice? {
        let connected = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
            .filter { $0.isConnected() && Self.looksLikeBuds($0) }
        return connected.first(where: Self.hasControlService) ?? connected.first
    }

    /// The buds this Mac last talked to, or any paired buds; connected or not.
    private func pairedBuds() -> IOBluetoothDevice? {
        let paired = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).filter(Self.looksLikeBuds)
        let last = UserDefaults.standard.string(forKey: "lastBudsAddress")
        return paired.first { $0.addressString == last } ?? paired.first
    }

    /// Out of the case, the buds often reconnect only to the phone. Ask them to
    /// connect to this Mac too. At most one attempt every 15 s; each one gives up after ~5 s.
    private func pageBuds() {
        // A request that never reported back (the buds vanished mid-page) doesn't block new ones.
        if pageInFlight, Date().timeIntervalSince(lastPage) > 30 { pageInFlight = false }
        guard autoConnect(), !pageInFlight, Date().timeIntervalSince(lastPage) > 15 else { return }
        guard let target = pairedBuds() else { return }
        pageInFlight = true
        lastPage = Date()
        log?(.info, "asking \(target.name ?? "buds") to connect to this Mac")
        let result = target.openConnection(self, withPageTimeout: 8000, authenticationRequired: false)  // 8000 × 0.625 ms
        if result != kIOReturnSuccess { pageInFlight = false }
    }

    /// IOBluetoothDevice async-open callback.
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.connectionComplete(device, status: status) }
            return
        }
        pageInFlight = false
        if status != kIOReturnSuccess { log?(.info, "buds not reachable (\(String(format: "0x%08x", status)))") }
        // On success the connect notification takes it from here.
    }

    /// OnePlus, OPPO, realme (and DIZO) buds: either they advertise the HeyMelody service, which
    /// also catches renamed buds, or their name carries the brand. A bare "buds" isn't enough, so
    /// other makers' earbuds are left alone.
    private static func looksLikeBuds(_ d: IOBluetoothDevice) -> Bool {
        if hasControlService(d) { return true }
        let name = (d.name ?? "").lowercased()
        return ["oneplus", "oppo", "enco", "realme", "dizo"].contains { name.contains($0) }
    }

    private static func hasControlService(_ d: IOBluetoothDevice) -> Bool {
        let records = (d.services as? [IOBluetoothSDPServiceRecord]) ?? []
        return records.contains { ($0.getServiceName() ?? "").lowercased().contains("enco") }
            || serviceUUIDs.contains { d.getServiceRecord(for: $0) != nil }
    }

    private func connect() {
        retryTimer?.invalidate()
        guard channel == nil, link != .connecting else {
            log?(.info, "connect skipped (\(channel == nil ? "no channel" : "channel open"), \(link))")
            return
        }
        guard let buds = findBuds(), Date() >= nextOpen else {
            link = .searching
            if let name = pairedBuds()?.name, name != deviceName { deviceName = name }
            pageBuds()
            scheduleRetry()
            return
        }
        if let previous = device, previous.addressString != buds.addressString { resetDeviceState() }
        device = buds
        deviceName = buds.name ?? deviceName
        address = buds.addressString?.uppercased().replacingOccurrences(of: "-", with: ":")
        UserDefaults.standard.set(buds.addressString, forKey: "lastBudsAddress")
        link = .connecting

        // Use the channel advertised by the "enco link" SDP record (15 on the Buds 4) or the
        // HeyMelody SPP UUID; only guess the channels other models use if neither is there.
        var channels: [BluetoothRFCOMMChannelID] = []
        let records = (buds.services as? [IOBluetoothSDPServiceRecord]) ?? []
        let named = records.filter { ($0.getServiceName() ?? "").lowercased().contains("enco") }
        var uuidRecords = Self.serviceUUIDs.compactMap { buds.getServiceRecord(for: $0) }
        // realme: the standard serial port, but only when there's no HeyMelody service to use.
        if named.isEmpty, uuidRecords.isEmpty, let spp = buds.getServiceRecord(for: Self.standardSPP) {
            uuidRecords.append(spp)
        }
        for record in named + uuidRecords {
            var id: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&id) == kIOReturnSuccess, !channels.contains(id) { channels.append(id) }
        }
        if channels.isEmpty {
            channels = Self.fallbackChannels
            buds.performSDPQuery(nil)  // refresh the records for the next attempt
        }
        pendingChannels = channels
        controlChannelIDs = Set(channels)
        openNextChannel()
    }

    private func openNextChannel() {
        guard let device, !pendingChannels.isEmpty else {
            link = .searching
            openFailed()
            scheduleRetry()
            return
        }
        let id = pendingChannels.removeFirst()
        log?(.info, "opening RFCOMM channel \(id)")
        var ch: IOBluetoothRFCOMMChannel?
        openingChannelID = id
        let result = device.openRFCOMMChannelAsync(&ch, withChannelID: id, delegate: self)
        if channel != nil {
            return  // the open completed synchronously inside the call above; already handled
        }
        if result == kIOReturnSuccess, let ch {
            channel = ch
            if ch.isOpen() {
                log?(.info, "channel \(id) is already open, using it")
                adopt(ch)
                return
            }
            // Some channels never answer; give up on this one after a few seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.channel === ch, self.link == .connecting else { return }
                if ch.isOpen() {
                    self.log?(.info, "channel \(id) opened without telling us, using it")
                    self.adopt(ch)
                    return
                }
                self.log?(.info, "channel \(id) timed out")
                self.closeChannel()
                self.link = .searching
                self.openNextChannel()
                if self.channel != nil { self.link = .connecting }
            }
        } else {
            log?(.info, "open channel \(id) failed: \(String(format: "0x%08x", result))")
            openNextChannel()
        }
    }

    private func closeChannel() {
        watchdog?.cancel()
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        channelID = nil
        parser = FrameParser()
        outstandingNoiseQueries = []
        staleNoiseQueries = []
        pendingEQID = nil
        eqWatchdog?.cancel()
        if link != .searching { link = .searching }
    }

    /// Last line of defence: no connection attempt may sit in "Connecting…" for more than 8 s.
    private func armConnectingWatchdog() {
        connectingWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.link == .connecting else { return }
            self.log?(.info, "stuck connecting, starting over")
            self.closeChannel()
            self.openFailed()
            self.retryCount = 0
            self.scheduleRetry()
        }
        connectingWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func openFailed() {
        failedOpens += 1
        guard failedOpens >= 2 else { return }
        let wait = min(300, 3 * pow(2, Double(failedOpens - 1)))
        nextOpen = Date() + wait
        log?(.info, "control channel failed \(failedOpens) times in a row, next try in \(Int(wait)) s")
    }

    /// Quick retries first (the buds often need a second after connecting), then every 8 s.
    private func scheduleRetry() {
        retryTimer?.invalidate()
        let delay = Self.retryDelays[min(retryCount, Self.retryDelays.count - 1)]
        retryCount += 1
        retryTimer = Self.timer(delay, repeats: false) { [weak self] in self?.connect() }
    }

    /// If the buds don't answer a request within 3 s the link is dead (sleep, out of range
    /// without a close callback…), so start over.
    private func expectReply() {
        let sent = Date()
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.link == .connected, self.lastReceived < sent else { return }
            self.log?(.info, "no reply from buds, reconnecting")
            self.reconnect()
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    @objc private func deviceDidConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.deviceDidConnect(note, device: device) }
            return
        }
        guard Self.looksLikeBuds(device), channel == nil else { return }
        log?(.info, "\(device.name ?? "buds") connected to Mac")
        retryCount = 0
        failedOpens = 0
        nextOpen = .distantPast
        // Give the buds a moment to finish setting up audio profiles before opening RFCOMM:
        // at 1.5 s the open hangs; by ~3 s it succeeds in under 0.2 s.
        retryTimer?.invalidate()
        retryTimer = Self.timer(3, repeats: false) { [weak self] in self?.connect() }
    }

    @objc private func deviceDidDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.deviceDidDisconnect(note, device: device) }
            return
        }
        log?(.info, "\(device.name ?? "buds") disconnected from Mac")
        closeChannel()
        left = nil; right = nil; caseBattery = nil
        retryCount = 0
        scheduleRetry()
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard Thread.isMainThread else {
            let channel = rfcommChannel
            DispatchQueue.main.async { self.rfcommChannelOpenComplete(channel, status: error) }
            return
        }
        // The completion can arrive before openRFCOMMChannelAsync has handed us the channel
        // (e.g. when it was already open); dropping it left the app stuck on "Connecting…".
        if channel == nil, link == .connecting, rfcommChannel.getID() == openingChannelID {
            channel = rfcommChannel
        }
        guard rfcommChannel === channel else { return }
        guard error == kIOReturnSuccess else {
            log?(.info, "channel \(rfcommChannel.getID()) open failed: \(String(format: "0x%08x", error))")
            channel = nil
            openNextChannel()
            return
        }
        didOpen(rfcommChannel)
    }

    /// The channel is open: start talking to the buds.
    private func didOpen(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
        guard !(link == .connected && channelID == rfcommChannel.getID()) else { return }
        log?(.info, "connected on channel \(rfcommChannel.getID())")
        channelID = rfcommChannel.getID()
        link = .connected
        retryCount = 0
        failedOpens = 0
        nextOpen = .distantPast
        disconnectNotification?.unregister()
        disconnectNotification = device?.register(forDisconnectNotification: self,
                                                  selector: #selector(deviceDidDisconnect(_:device:)))
        // A mode picked while disconnected is newer than the remembered one, so it wins.
        restoreNoise = rememberSettings() && queuedMode == nil
        restoreLowLatency = rememberSettings()
        send(Command.hello)
        send(Command.productID)
        // A mode requested while disconnected waits for the product ID, so it uses the right layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.applyQueuedMode() }
        // Ask for pushes: battery, wear status and noise mode. The first byte is
        // the number of subscription ids, not a byte count.
        send(Command.subscribe, [0x03, 0x01, 0x02, 0x03])
        send(Command.wearStatus)
        send(Command.multipointQuery)
        send(Command.eqQuery)
        send(Command.eqListQuery, [0x01, 0x05])
        send(Command.switchQuery, [0x01, Feature.lowLatency])
        send(Command.gestureQuery)
        refresh()
    }

    /// Takes over an already-open control channel (ours, or one IOBluetooth reopened by itself).
    private func adopt(_ opened: IOBluetoothRFCOMMChannel) {
        if let current = channel, current !== opened { current.setDelegate(nil) }  // same link; don't close it
        opened.setDelegate(self)
        channel = opened
        didOpen(opened)
    }

    @objc private func channelDidOpen(_ note: IOBluetoothUserNotification, channel opened: IOBluetoothRFCOMMChannel) {
        DispatchQueue.main.async { [self] in
            guard link != .connected, opened.isOpen(), controlChannelIDs.contains(opened.getID()),
                  let device, opened.getDevice()?.addressString == device.addressString else { return }
            log?(.info, "channel \(opened.getID()) was opened for us, using it")
            adopt(opened)
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard Thread.isMainThread else {
            let channel = rfcommChannel
            DispatchQueue.main.async { self.rfcommChannelClosed(channel) }
            return
        }
        guard rfcommChannel === channel else { return }
        log?(.info, "channel closed")
        closeChannel()
        scheduleRetry()
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.received(bytes) }
            return
        }
        received(bytes)
    }

    private func received(_ bytes: [UInt8]) {
        lastReceived = Date()
        log?(.received, hex(bytes))
        for frame in parser.feed(bytes) { handle(frame) }
    }

    // MARK: - Frames

    private func send(_ command: UInt16, _ payload: [UInt8] = []) {
        guard let channel else { return }
        seq &+= 1
        var data = [UInt8](Frame(command: command, seq: seq, payload: payload).encoded())
        log?(.sent, hex(data))
        let result = channel.writeSync(&data, length: UInt16(data.count))
        if result != kIOReturnSuccess {
            log?(.info, "write failed: \(String(format: "0x%08x", result)), reconnecting")
            DispatchQueue.main.async { [weak self] in self?.reconnect() }
        }
    }

    private func queryNoise() {
        send(Command.noiseQuery, [0x01, 0x01])
        outstandingNoiseQueries.insert(seq)
    }

    private func handle(_ frame: Frame) {
        onFrame?(frame)
        let p = frame.payload
        switch frame.command {
        case Command.productID | 0x8000:
            if p.count >= 4, p[0] == 0 {
                let pid = String(format: "%02X%02X%02X", p[3], p[2], p[1])
                productID = pid
                if !model.name.isEmpty, device?.name == nil || deviceName == "Earbuds" || deviceName == "OnePlus Buds" { deviceName = model.name }
                applyQueuedMode()
            }
        case Command.hello | 0x8000:
            parseCapabilities(p)
        case Command.battery | 0x8000:
            parseBattery(p)
        case Command.noiseQuery | 0x8000:
            outstandingNoiseQueries.remove(frame.seq)
            if staleNoiseQueries.remove(frame.seq) != nil { return }
            parseNoise(p)
        case Command.setNoise | 0x8000:
            // Acknowledged: read back which level the buds actually picked.
            if p.first != 0 { log?(.info, "mode change rejected: \(hex(p))") }
            queryNoise()
        case Command.setSwitch | 0x8000:
            // An accepted switch is confirmed by a push about half a second later; reading it back
            // straight away still returns the old value and flicks the toggle. Re-read only on refusal.
            if p.first != 0 {
                log?(.info, "switch rejected: \(hex(p))")
                send(Command.switchQuery, [0x01, Feature.lowLatency])
            }
        case Command.switchQuery | 0x8000:
            parseSwitches(p)
        case Command.eqQuery | 0x8000:
            if p.count >= 2, p[0] == 0 {
                let reported = p[1]
                if let pending = pendingEQID {
                    if reported == pending {
                        // Hardware confirmed our requested preset
                        pendingEQID = nil
                        eqWatchdog?.cancel()
                        eqID = reported
                    }
                    // Otherwise: stale response during DSP transition, ignore it
                } else {
                    // No transition pending: accept truth
                    eqID = reported
                }
            }
        case Command.eqListQuery | 0x8000:
            parseEQList(p)
        case Command.setEQ | 0x8000, Command.setCustomEQ | 0x8000:
            let custom = (frame.command & ~0x8000) == Command.setCustomEQ
            if p.first != 0 {
                log?(.info, "\(custom ? "custom " : "")EQ change rejected: \(hex(p))")
                eqWatchdog?.cancel()
                pendingEQID = nil
                send(Command.eqQuery)
                if custom { send(Command.eqListQuery, [0x01, 0x05]) }
            } else {
                let gen = eqGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.link == .connected, self.eqGeneration == gen else { return }
                    if self.pendingEQID != nil { self.send(Command.eqQuery) }
                    if custom { self.send(Command.eqListQuery, [0x01, 0x05]) }
                }
            }
        case Command.gestureQuery | 0x8000:
            parseGestures(p)
        case Command.setGesture | 0x8000:
            if p.first != 0 { log?(.info, "gesture change rejected: \(hex(p))") }
            send(Command.gestureQuery)
        case Command.findBuds | 0x8000:
            // Status 0 accepts a start; the buds answer a stop with 1, so only a start can fail.
            if findingBuds, p.first != 0 {
                log?(.info, "find earbuds rejected: \(hex(p))")
                findingBuds = false
            }
        case Command.multipointQuery | 0x8000:
            parseHosts(p)
        case Command.multipointSet | 0x8000:
            if p.first != 0 { log?(.info, "multipoint action rejected: \(hex(p))") }
        case Command.wearStatus | 0x8000:
            parseWear(p)
        case Command.statusPush:
            handlePush(p)
        case Command.eqPush:
            if let id = p.first {
                log?(.info, "EQ push: preset \(id)")
                if let pending = pendingEQID {
                    // Drop late push events from previous selections
                    if id == pending {
                        eqWatchdog?.cancel()
                        pendingEQID = nil
                        eqID = id
                    }
                } else {
                    // External change (stem gesture or phone app)
                    eqID = id
                }
            }
        default:
            break
        }
    }

    /// 0x0204 pushes start with the subscription type; the rest is laid out like the matching reply.
    private func handlePush(_ p: [UInt8]) {
        switch p.first {
        case 0x01: parseBattery(p)
        case 0x02: parseWear(p)
        case 0x03: parseNoise(p)
        case 0x05 where p.count >= 2: gameMode = p[1] != 0
        case 0x06: parseHosts(p)
        default: refresh()
        }
    }

    /// Payload: <status> <count> (<id> <level | 0x80 if charging>)*  — id 1 left, 2 right, 3 case.
    private func parseBattery(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        let count = Int(p[1])
        var i = 2
        for _ in 0..<count where i + 1 < p.count {
            let battery = Battery(level: Int(p[i + 1] & 0x7F), charging: p[i + 1] & 0x80 != 0)
            switch p[i] {
            case 1: left = battery
            case 2: right = battery
            case 3: caseBattery = (battery.level > 0 || battery.charging) ? battery : nil
            default: break
            }
            i += 2
        }
    }

    /// Payload: <status> <bitmap, LSB first>. Each bit says a group of commands is supported.
    private func parseCapabilities(_ p: [UInt8]) {
        guard p.count >= 2, p[0] == 0 else { return }
        var bits: Set<Int> = []
        for (byteIndex, byte) in p.dropFirst().enumerated() {
            for bit in 0..<8 where byte & (1 << bit) != 0 { bits.insert(byteIndex * 8 + bit) }
        }
        capabilities = bits
    }

    /// Forget everything learned about the previous buds when different ones connect.
    private func resetDeviceState() {
        productID = nil
        capabilities = nil
        mode = nil
        level = nil
        noiseBit = nil
        left = nil; right = nil; caseBattery = nil
        gameMode = nil
        eqID = nil
        pendingEQID = nil
        eqGeneration &+= 1
        eqWatchdog?.cancel()
        customEQs = []
        gestures = [:]
        hosts = []
    }

    private func applyQueuedMode() {
        guard link == .connected, let (mode, level) = queuedMode else { return }
        queuedMode = nil
        setMode(mode, level: level)
    }

    // MARK: - Remembered settings

    /// The noise mode and low latency last picked in the app, per pair of buds. Only picks made here
    /// count: the buds report Off on their way into the case, which mustn't be what comes back.
    private struct Remembered: Codable {
        var mode: String?
        var level: String?
        var lowLatency: Bool?
    }

    private static let rememberedKey = "rememberedSettings"

    private func remember(_ change: (inout Remembered) -> Void) {
        guard let key = device?.addressString else { return }
        var all = Self.loadRemembered()
        change(&all[key, default: Remembered()])
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.rememberedKey)
    }

    private static func loadRemembered() -> [String: Remembered] {
        UserDefaults.standard.data(forKey: rememberedKey)
            .flatMap { try? JSONDecoder().decode([String: Remembered].self, from: $0) } ?? [:]
    }

    /// Once the buds have said what they're set to, changes back only what differs from the
    /// remembered settings, so a link that comes back as it was sends nothing.
    private func restoreSettings() {
        guard restoreNoise || restoreLowLatency else { return }
        guard link == .connected, let key = device?.addressString,
              let saved = Self.loadRemembered()[key] else {
            restoreNoise = false
            restoreLowLatency = false
            return
        }
        if restoreNoise, let current = mode {
            restoreNoise = false
            if let savedMode = saved.mode.flatMap(NoiseMode.init(rawValue:)), availableModes.contains(savedMode) {
                let savedLevel = saved.level.flatMap(ANCLevel.init(rawValue:)).flatMap { availableLevels.contains($0) ? $0 : nil }
                if savedMode != current || (savedMode == .anc && savedLevel != nil && savedLevel != level) {
                    log?(.info, "restoring \(savedMode.rawValue)\(savedLevel.map { " (\($0.rawValue))" } ?? "")")
                    setMode(savedMode, level: savedLevel)
                }
            }
        }
        if restoreLowLatency, let current = gameMode {
            restoreLowLatency = false
            if let on = saved.lowLatency, on != current, supports(.lowLatency) {
                log?(.info, "restoring low latency \(on ? "on" : "off")")
                setGameMode(on)
            }
        }
    }

    /// Payload: <status> <count> (<feature id> <0 off | 1 on>)*
    private func parseSwitches(_ p: [UInt8]) {
        guard p.count >= 2, p[0] == 0 else { return }
        var i = 2
        for _ in 0..<Int(p[1]) where i + 1 < p.count {
            if p[i] == Feature.lowLatency { gameMode = p[i + 1] == 1 }
            i += 2
        }
        restoreSettings()
    }

    /// Payload: <status> <count> (<selected> <min dB> <max dB> <id> <name len> <name> <band count>
    /// (<Hz lo> <Hz hi> <gain dB>)*)*. Only custom EQs are listed; built-in presets aren't.
    private func parseEQList(_ p: [UInt8]) {
        guard p.count >= 2, p[0] == 0 else { return }
        var result: [CustomEQ] = []
        var i = 2
        for _ in 0..<Int(p[1]) {
            guard i + 5 <= p.count else { break }
            let minGain = Int(Int8(bitPattern: p[i + 1])), maxGain = Int(Int8(bitPattern: p[i + 2]))
            let id = p[i + 3], nameLen = Int(p[i + 4])
            i += 5
            guard i + nameLen < p.count else { break }
            let name = String(decoding: p[i..<(i + nameLen)], as: UTF8.self)
            i += nameLen
            let count = Int(p[i])
            i += 1
            guard i + count * 3 <= p.count else { break }
            let bands = (0..<count).map { n in
                (hz: Int(p[i + n * 3]) | Int(p[i + n * 3 + 1]) << 8, gain: Int(Int8(bitPattern: p[i + n * 3 + 2])))
            }
            i += count * 3
            result.append(CustomEQ(id: id, name: name.isEmpty ? "Custom" : name, minGain: minGain, maxGain: maxGain,
                                   bands: bands))
        }
        if result != customEQs { customEQs = result }
    }

    /// Payload: <status> <count> (<side> <context> <gesture> <action>)*. Only music-context
    /// double tap / triple tap / hold are surfaced; calls and the fixed gestures are left alone.
    private func parseGestures(_ p: [UInt8]) {
        guard p.count >= 2, p[0] == 0 else { return }
        var result: [EarSide: [Gesture: GestureAction]] = [:]
        var i = 2
        for _ in 0..<Int(p[1]) where i + 3 < p.count {
            if let side = EarSide(rawValue: p[i]), p[i + 1] == 0x01, let gesture = Gesture(rawValue: p[i + 2]),
               let action = GestureAction(rawValue: p[i + 3]) {
                result[side, default: [:]][gesture] = action
            }
            i += 4
        }
        gestures = result
    }

    /// Payload: <status> <count> (<side> <0 in case | 1 out of ear | 3 in ear>)*
    private func parseWear(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        var result = wear
        var i = 2
        for _ in 0..<Int(p[1]) where i + 1 < p.count {
            result[Int(p[i])] = Wear(rawValue: Int(p[i + 1]))
            i += 2
        }
        wear = result
    }

    /// Payload contains `01 01 <mask lo> [<mask hi>]` where the lowest set bit is the active mode.
    private func parseNoise(_ p: [UInt8]) {
        guard p.count >= 3 else { return }
        for idx in 0..<(p.count - 2) where p[idx] == 0x01 && p[idx + 1] == 0x01 {
            let mask = Int(p[idx + 2]) | (idx + 3 < p.count ? Int(p[idx + 3]) << 8 : 0)
            guard mask != 0 else { continue }
            // Models can report a different bit than the one used to set a mode (Transparency is
            // set with bit 2 but reported as bit 8 on the Buds 4; Buds Pro 3 report levels in bits
            // 12-15), so look the bit up in the model's reported layout.
            let bit = mask.trailingZeroBitCount
            guard let type = model.reportedBits[bit] else {
                log?(.info, "unknown noise bit \(bit) for \(productID ?? "unknown model")")
                return
            }
            noiseBit = bit
            mode = ModeType.mode(type)
            level = ANCLevel(modeType: type) ?? (mode == .anc ? level : nil)
            restoreSettings()
            return
        }
    }

    /// Payload: <status> <count> (<address, reversed> <reserved> <2 = connected> <1 = this host> <name len> <name>)*
    private func parseHosts(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        var result: [Host] = []
        var i = 2
        for _ in 0..<Int(p[1]) {
            guard i + 10 <= p.count else { break }
            let addr = p[i..<(i + 6)].reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
            let nameLen = Int(p[i + 9])
            guard i + 10 + nameLen <= p.count else { break }
            let name = String(decoding: p[(i + 10)..<(i + 10 + nameLen)], as: UTF8.self)
            result.append(Host(address: addr, name: name, connected: p[i + 7] == 2, isThisMac: p[i + 8] == 1))
            i += 10 + nameLen
        }
        hosts = result
        onHostsChange?(result)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
