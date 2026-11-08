import SwiftUI

// MARK: - Compatibility Layer for macOS 14+ (Sonoma) and macOS 15+ (Sequoia)

/// Fallback container that uses GlassEffectContainer on macOS 26+ and transparent pass-through on earlier macOS versions.
struct GlassEffectContainer<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            SwiftUICore.GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// Fallback button styles for .glass and .glassProminent on macOS versions earlier than macOS 26.
struct AdaptiveGlassButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(configuration).buttonStyle(SwiftUI.GlassButtonStyle())
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

struct AdaptiveGlassProminentButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(configuration).buttonStyle(SwiftUI.GlassProminentButtonStyle())
        } else {
            Button(configuration).buttonStyle(.borderedProminent)
        }
    }
}

extension PrimitiveButtonStyle where Self == AdaptiveGlassButtonStyle {
    static var glass: AdaptiveGlassButtonStyle { AdaptiveGlassButtonStyle() }
}

extension PrimitiveButtonStyle where Self == AdaptiveGlassProminentButtonStyle {
    static var glassProminent: AdaptiveGlassProminentButtonStyle { AdaptiveGlassProminentButtonStyle() }
}

// MARK: - View Modifiers for Glass Effects

extension View {
    @ViewBuilder
    func circleGlass(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: .circle)
            } else {
                self.glassEffect(.regular, in: .circle)
            }
        } else {
            self
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func tintedCircleGlass(_ tint: Color?) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint ?? .clear), in: .circle)
        } else {
            self
                .background(Circle().fill(tint ?? Color.secondary.opacity(0.15)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func capsuleGlass() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }

    @ViewBuilder
    func roundedRectGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

