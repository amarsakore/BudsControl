import SwiftUI

struct MenuView: View {
    @ObservedObject var buds: BudsController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("moreExpanded") private var moreExpanded = false

    var body: some View {
        // Spacing 0: glass shapes only blend when they touch, so nothing nearby picks up the lens.
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 10) {
                header
                if buds.link == .connected {
                    // Only what this model has: no noise control at all on buds without ANC.
                    if buds.supports(.noiseControl) {
                        modes
                        if buds.mode == .anc, !buds.availableLevels.isEmpty {
                            levels.transition(.blurReplace)
                        }
                    }
                    // Own stack with no spacing: the gap above the panel is part of the panel, so a
                    // folded panel leaves no extra space under the battery row.
                    VStack(spacing: 0) {
                        batteries
                        Collapsible(expanded: moreExpanded && buds.hasMoreControls) {
                            MoreControls(buds: buds).padding(.top, 10)
                        }
                    }
                } else {
                    disconnected
                }
            }
        }
        .padding(12)
        .frame(width: 256)
        .animation(.spring(response: 0.42, dampingFraction: 0.74), value: buds.mode)
        .animation(.snappy(duration: 0.22), value: buds.link)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: moreExpanded)
    }

    /// The down arrow that reveals equalizer, low latency, find my earbuds and gestures.
    /// Round chevron beside the ••• button, the same size, that folds the More panel open and shut.
    private var moreToggle: some View {
        Button {
            moreExpanded.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(moreExpanded ? 180 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .circleGlass(interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(moreExpanded ? "Fewer controls" : "Equalizer, low latency, find earbuds and gestures")
        .accessibilityLabel(moreExpanded ? "Show fewer controls" : "Show more controls")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            BatteryRing(level: buds.link == .connected ? buds.budsBattery : nil,
                        charging: buds.left?.charging == true || buds.right?.charging == true,
                        size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(buds.deviceName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .minimumScaleFactor(0.85)  // long custom Bluetooth names
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if buds.link == .connected, buds.hasMoreControls { moreToggle }
                menu
            }
        }
    }

    private var menu: some View {
        Menu {
            Button("Settings…") { openSettings() }.keyboardShortcut(",")
            Button("Reconnect") { buds.reconnect() }
            Divider()
            Button("Quit Buds Control") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .circleGlass(interactive: true)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var subtitle: String {
        switch buds.link {
        case .connected:
            // Short form ("ANC · Max"): the header shares its row with two buttons, and
            // "Noise Cancellation" doesn't fit there.
            var status = buds.mode?.shortTitle ?? "Connected"
            if buds.mode == .anc, let level = buds.level { status += " · \(level.title)" }
            return buds.budsBattery.map { "\($0)% · \(status)" } ?? status
        case .connecting: return "Connecting…"
        case .searching: return "Not connected"
        }
    }

    // MARK: Modes and levels — lens-style segmented controls (see LiquidSegmented)

    private var modes: some View {
        LiquidSegmented(items: buds.availableModes, selection: buds.mode,
                        onSelect: { buds.setMode($0) }) { mode, selected in
            HStack(spacing: 5) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.bounce, value: selected)
                if selected {
                    Text(mode.shortTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .help(mode.title)
            .accessibilityLabel(mode.title)
        } widthFor: { _, selected in selected ? nil : 40 }
    }

    private var levels: some View {
        LiquidSegmented(items: buds.availableLevels, selection: buds.level, height: 22,
                        onSelect: { buds.setMode(.anc, level: $0) }, label: { level, selected in
            Text(level.title)
                .font(.caption2.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)  // five levels (with Adaptive) are a tight fit
        }, fitToLabels: true)
    }

    // MARK: Battery — one compact line

    private var batteries: some View {
        HStack(spacing: 0) {
            BatteryLabel(symbol: "airpod.left", battery: buds.left)
            Spacer(minLength: 0)
            BatteryLabel(symbol: "airpod.right", battery: buds.right)
            Spacer(minLength: 0)
            BatteryLabel(symbol: "airpods.chargingcase", battery: buds.caseBattery)
        }
        .padding(.horizontal, 6)
    }

    // MARK: Disconnected

    private var disconnected: some View {
        HStack(spacing: 8) {
            if buds.link == .connecting { ProgressView().controlSize(.small) }
            Text(buds.link == .connecting ? "Connecting…" : "Buds not connected to this Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if buds.link != .connecting {
                Button("Retry") { buds.reconnect() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .roundedRectGlass(cornerRadius: 14)
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate()
    }
}

private struct BatteryLabel: View {
    let symbol: String
    let battery: BudsController.Battery?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
            if battery?.charging == true {
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(.green)
            }
            Text(battery.map { "\($0.level)%" } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(battery.map { $0.level <= 20 && !$0.charging } == true ? .red : .primary)
        }
    }
}

/// Folds its content open and shut under the toggle, like a disclosure: the height animates
/// between 0 and the content's natural height, clipped at the bottom edge.
private struct Collapsible<Content: View>: View {
    let expanded: Bool
    @ViewBuilder let content: () -> Content
    @StateObject private var size = MeasuredHeight()

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { size.height = $0 }
            .opacity(expanded ? 1 : 0)
            .frame(height: expanded ? size.height : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
    }
}

private final class MeasuredHeight: ObservableObject {
    @Published var height: CGFloat = 0
}
