import AppKit
import SwiftUI

/// The expandable "More" part of the popover: equalizer, low latency, find my earbuds, gestures.
struct MoreControls: View {
    @ObservedObject var buds: BudsController
    @AppStorage("gestureSide") private var gestureSide = Int(EarSide.left.rawValue)

    var body: some View {
        VStack(spacing: 8) {
            equalizer
            lowLatency
            findBuds
            gestureSection
        }
    }

    // MARK: Equalizer

    @ViewBuilder private var equalizer: some View {
        let choices = buds.eqChoices
        let current = choices.first { $0.id == buds.eqID }
        if buds.supports(.equalizer) {
            Card(title: "Equalizer", symbol: "slider.vertical.3") {
                if Self.namesFitAsButtons(choices.map(\.name)) {
                    LiquidSegmented(items: choices, selection: current, height: 22,
                                    onSelect: { buds.setEQ($0.id) }, label: { preset, selected in
                        Text(preset.name)
                            .font(.caption2.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)  // last resort if the labels can't all fit
                    }, fitToLabels: true)
                } else {
                    // Long names ("Pure vocals") or 5+ presets: a row of buttons would cut them off.
                    PickerRow(title: "Preset", value: current?.name ?? "—",
                              options: choices.map { ($0.name, nil) }) { index in buds.setEQ(choices[index].id) }
                }
                if let custom = buds.activeCustomEQ {
                    EQBands(eq: custom) { buds.setCustomEQ(gains: $0) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// Buttons when every preset name fits on one row of the popover (Balanced / Vocal / Bass /
    /// Custom does), otherwise a dropdown. Measured at the selected (semibold) weight, with each
    /// button's 8 pt side padding, against the row's 206 pt (256 popover − 24 − 20 card − 6 track).
    private static func namesFitAsButtons(_ names: [String]) -> Bool {
        guard names.count <= 4 else { return false }
        let size = NSFont.preferredFont(forTextStyle: .caption2).pointSize
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let needed = names.reduce(0) { $0 + ($1 as NSString).size(withAttributes: [.font: font]).width + 16 }
        return needed <= 206
    }

    // MARK: Low latency

    @ViewBuilder private var lowLatency: some View {
        if buds.supports(.lowLatency) { lowLatencyCard }
    }

    private var lowLatencyCard: some View {
        Card {
            Row(title: "Low latency", subtitle: "For games and video", symbol: "gamecontroller") {
                Toggle("Low latency", isOn: Binding(get: { buds.gameMode ?? false }, set: { buds.setGameMode($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
    }

    // MARK: Find my earbuds

    @ViewBuilder private var findBuds: some View {
        if buds.supports(.findBuds) { findBudsCard }
    }

    private var findBudsCard: some View {
        Card {
            Row(title: "Find earbuds",
                subtitle: buds.findingBuds ? "Playing a sound…" : "Loud — take them out of your ears first",
                symbol: "dot.radiowaves.left.and.right") {
                Button(buds.findingBuds ? "Stop" : "Play") { buds.findBuds(!buds.findingBuds) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .tint(buds.findingBuds ? .red : nil)
            }
        }
    }

    // MARK: Gestures

    @ViewBuilder private var gestureSection: some View {
        if buds.supports(.gestures) {
            let sides = EarSide.allCases.filter { buds.gestures[$0] != nil }
            let side = sides.first { $0.rawValue == UInt8(gestureSide) } ?? sides.first ?? .left
            Card(title: "Gestures", symbol: "hand.tap") {
                LiquidSegmented(items: sides, selection: side, height: 22,
                                onSelect: { gestureSide = Int($0.rawValue) }) { side, selected in
                    Text(side.title)
                        .font(.caption2.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                }
                // Only the gestures these buds report, with the actions their brand accepts.
                ForEach(Gesture.allCases.filter { buds.gestures[side]?[$0] != nil }) { gesture in
                    let current = buds.gestures[side]?[gesture]
                    PickerRow(title: gesture.title, value: current?.title ?? "—",
                              options: buds.gestureActions(current: current).map { ($0.title, $0.symbol) }) { index in
                        buds.setGesture(buds.gestureActions(current: current)[index], for: gesture, side: side)
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

/// A softly filled rounded panel, matching the segmented controls' track.
private struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 5) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                    Text(title).font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

private struct Row<Accessory: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            accessory()
        }
    }
}

/// A label with a compact menu on the right, in the popover's capsule style.
private struct PickerRow: View {
    let title: String
    let value: String
    let options: [(title: String, symbol: String?)]
    let onSelect: (Int) -> Void

    var body: some View {
        HStack {
            Text(title).font(.caption)
            Spacer(minLength: 4)
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    Button {
                        onSelect(index)
                    } label: {
                        if let symbol = options[index].symbol {
                            Label(options[index].title, systemImage: symbol)
                        } else {
                            Text(options[index].title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value).font(.caption.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        }
    }
}

// MARK: - Custom EQ bands

/// Vertical band sliders for the active custom EQ; the new curve is sent when a drag ends.
private struct EQBands: View {
    let eq: CustomEQ
    let onCommit: ([Int]) -> Void
    @StateObject private var draft = EQDraft()

    var body: some View {
        let gains = draft.gains.count == eq.bands.count ? draft.gains : eq.bands.map(\.gain)
        HStack(spacing: 4) {
            ForEach(eq.bands.indices, id: \.self) { i in
                VStack(spacing: 3) {
                    Text(gains[i] > 0 ? "+\(gains[i])" : "\(gains[i])")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(gains[i] == 0 ? .secondary : .primary)
                    BandSlider(value: gains[i], range: eq.minGain...eq.maxGain) { value in
                        if draft.gains.count != eq.bands.count { draft.gains = eq.bands.map(\.gain) }
                        draft.gains[i] = value
                    } onEnd: {
                        onCommit(draft.gains)
                    }
                    .frame(height: 64)
                    .accessibilityElement()
                    .accessibilityLabel("\(Self.label(eq.bands[i].hz)) hertz")
                    .accessibilityValue("\(gains[i]) decibels")
                    .accessibilityAdjustableAction { direction in
                        var new = gains
                        new[i] = min(max(new[i] + (direction == .increment ? 1 : -1), eq.minGain), eq.maxGain)
                        draft.gains = new
                        onCommit(new)
                    }
                    Text(Self.label(eq.bands[i].hz))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: eq) { _, new in draft.gains = new.bands.map(\.gain) }
    }

    static func label(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000)k" : "\(hz)"
    }
}

private final class EQDraft: ObservableObject {
    @Published var gains: [Int] = []
}

private struct BandSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, span = CGFloat(range.upperBound - range.lowerBound)
            let y = { (v: Int) in h * CGFloat(range.upperBound - v) / span }
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.1)).frame(width: 4)
                // Fill from 0 dB to the current gain.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: abs(y(value) - y(0)))
                    .offset(y: min(y(value), y(0)))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: 12, height: 12)
                    .offset(y: y(value) - 6)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = min(max(drag.location.y / h, 0), 1)
                        let new = range.upperBound - Int((fraction * span).rounded())
                        if new != value { onChange(new) }
                    }
                    .onEnded { _ in onEnd() }
            )
        }
        .animation(.snappy(duration: 0.12), value: value)
    }
}
