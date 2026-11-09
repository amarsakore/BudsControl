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
                    modes
                    if buds.mode == .anc, !buds.availableLevels.isEmpty {
                        levels.transition(.blurReplace)
                    }
                    batteries
                    moreToggle
                    Collapsible(expanded: moreExpanded) {
                        MoreControls(buds: buds)
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
    private var moreToggle: some View {
        Button {
            moreExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(moreExpanded ? "Less" : "More").font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(moreExpanded ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
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
    }

    private var subtitle: String {
        switch buds.link {
        case .connected:
            if let level = buds.budsBattery { return "\(level)% · \(buds.mode?.title ?? "Connected")" }
            return buds.mode?.title ?? "Connected"
        case .connecting: return "Connecting…"
        case .searching: return "Not connected"
        }
    }

    // MARK: Modes and levels — lens-style segmented controls (see LiquidSegmented)

    private var modes: some View {
        LiquidSegmented(items: [NoiseMode.off, .transparency, .anc], selection: buds.mode,
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
            // While folded the stack still adds its spacing; pull it back so the toggle sits at the bottom.
            .padding(.top, expanded ? 0 : -10)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
    }
}

private final class MeasuredHeight: ObservableObject {
    @Published var height: CGFloat = 0
}
