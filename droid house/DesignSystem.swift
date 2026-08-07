import SwiftUI
import AppKit

// MARK: - Spatial Design Tokens
//
// DroidHouse's visual language: true-black architectures in Dark Mode, thin
// glass membranes stacked at explicit depths, and a motion vocabulary built
// entirely from springs so every interaction can be interrupted mid-flight
// without losing velocity.

enum Spatial {

    // MARK: Depth

    /// Discrete elevation planes. Everything in the UI sits on exactly one of
    /// these, which keeps blur radii, borders and shadows mutually consistent.
    enum Depth: Int, CaseIterable {
        case substrate = 0   // the true-black canvas itself
        case chrome    = 1   // sidebars, inspectors, toolbars
        case surface   = 2   // cards, rows, bubbles
        case floating  = 3   // popovers, pills, HUDs
        case modal     = 4   // sheets, overlays

        var cornerRadius: CGFloat {
            switch self {
            case .substrate: return 0
            case .chrome:    return 0
            case .surface:   return 14
            case .floating:  return 18
            case .modal:     return 24
            }
        }

        var shadowRadius: CGFloat {
            switch self {
            case .substrate: return 0
            case .chrome:    return 0
            case .surface:   return 6
            case .floating:  return 14
            case .modal:     return 30
            }
        }

        var shadowOpacity: Double {
            switch self {
            case .substrate: return 0
            case .chrome:    return 0
            case .surface:   return 0.16
            case .floating:  return 0.26
            case .modal:     return 0.38
            }
        }

        var shadowY: CGFloat {
            switch self {
            case .substrate: return 0
            case .chrome:    return 0
            case .surface:   return 3
            case .floating:  return 8
            case .modal:     return 18
            }
        }

        /// Hairline strength that separates this plane from the one beneath it.
        var rimOpacity: Double {
            switch self {
            case .substrate: return 0
            case .chrome:    return 0.06
            case .surface:   return 0.10
            case .floating:  return 0.14
            case .modal:     return 0.18
            }
        }
    }

    // MARK: Motion

    /// Physics presets. Response/damping pairs rather than durations, so that a
    /// target change mid-animation is absorbed by the spring instead of
    /// restarting from zero velocity.
    enum Motion {
        /// Snappy, near-critically damped — selection, hover, toggles.
        static let crisp = Animation.spring(response: 0.28, dampingFraction: 0.86)
        /// The house default — panel swaps, layout shifts.
        static let fluid = Animation.spring(response: 0.42, dampingFraction: 0.80)
        /// Overshooting and playful — message arrival, success flourishes.
        static let bouncy = Animation.spring(response: 0.46, dampingFraction: 0.58)
        /// Slow, heavy, deliberate — full-window mode changes.
        static let cinematic = Animation.spring(response: 0.75, dampingFraction: 0.85)
        /// Ultra-elastic; the macOS mirror of Android's
        /// `DampingRatioMediumBouncy` + `StiffnessLow` pairing.
        static let elastic = Animation.spring(response: 0.62, dampingFraction: 0.5)
    }

    // MARK: Metrics

    enum Metric {
        static let hairline: CGFloat = 1
        static let gutter: CGFloat = 12
        static let rowHeight: CGFloat = 34
        static let iconChip: CGFloat = 26
    }
}

// MARK: - Palette

extension Color {
    /// The substrate. Pure `#000000` in Dark Mode so OLED pixels switch off
    /// entirely; a soft paper tone in Light Mode.
    static var dhSubstrate: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? .black : NSColor(calibratedWhite: 0.96, alpha: 1)
        })
    }

    /// One step above the substrate — used behind scroll content.
    static var dhCanvas: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(calibratedWhite: 0.045, alpha: 1)
                : NSColor(calibratedWhite: 1.0, alpha: 1)
        })
    }

    /// Glass tint layered over the material blur.
    static var dhGlassTint: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(calibratedWhite: 1.0, alpha: 0.05)
                : NSColor(calibratedWhite: 1.0, alpha: 0.55)
        })
    }

    /// Hairline rim colour used on every glass edge.
    static var dhRim: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(calibratedWhite: 1.0, alpha: 1.0)
                : NSColor(calibratedWhite: 0.0, alpha: 1.0)
        })
    }

    static let dhAccentBlue = Color(red: 0.0, green: 122.0 / 255.0, blue: 1.0)
    static let dhAccentViolet = Color(red: 0.58, green: 0.36, blue: 0.98)
    static let dhAccentMint = Color(red: 0.18, green: 0.86, blue: 0.68)
    static let dhAccentGreen = Color(red: 52.0 / 255.0, green: 199.0 / 255.0, blue: 89.0 / 255.0) // iOS Messages Green (#34C759)

}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Glass Surface

/// The single glass primitive every panel in the app is built from. It layers
/// an `NSVisualEffectView` blur, a translucent tint, a luminous top rim and a
/// depth-matched shadow, then optionally reacts to hover.
struct GlassSurface: ViewModifier {
    var depth: Spatial.Depth
    var isHighlighted: Bool = false
    var tint: Color? = nil

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(Color.dhGlassTint)
                    }
                    .overlay {
                        if let tint {
                            shape.fill(tint.opacity(isHighlighted ? 0.22 : 0.12))
                        }
                    }
                    .overlay {
                        // Specular top edge — the "lit from above" cue that
                        // makes a flat blur read as a physical pane of glass.
                        shape
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.dhRim.opacity(rim * 2.2),
                                        Color.dhRim.opacity(rim * 0.55)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: Spatial.Metric.hairline
                            )
                    }
                    .shadow(
                        color: .black.opacity(depth.shadowOpacity),
                        radius: depth.shadowRadius,
                        y: depth.shadowY
                    )
            }
    }

    private var rim: Double {
        let base = depth.rimOpacity * (isHighlighted ? 1.8 : 1.0)
        // Light Mode needs a much fainter dark rim than Dark Mode needs a
        // bright one, or the edges turn into hard black outlines.
        return colorScheme == .dark ? base : base * 0.45
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: depth.cornerRadius, style: .continuous)
    }
}

extension View {
    func glassSurface(
        _ depth: Spatial.Depth,
        highlighted: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(GlassSurface(depth: depth, isHighlighted: highlighted, tint: tint))
    }

    /// Paints the true-black substrate behind a view in Dark Mode.
    func substrateBackground() -> some View {
        background(Color.dhSubstrate.ignoresSafeArea())
    }
}

// MARK: - Contextual Cursor

/// The cursor shapes DroidHouse morphs between as the pointer moves across
/// functionally different regions of the interface.
enum SpatialCursor: Equatable {
    case standard
    case interactive      // clickable chrome
    case text             // editable fields
    case grab             // draggable item at rest
    case grabbing         // draggable item in flight
    case resizeColumn     // spreadsheet / split dividers
    case zoomIn           // media that can be enlarged
    case crosshair        // precision targets (AeroCast tap-through)
    case disallowed       // drop rejected

    var nsCursor: NSCursor {
        switch self {
        case .standard:     return .arrow
        case .interactive:  return .pointingHand
        case .text:         return .iBeam
        case .grab:         return .openHand
        case .grabbing:     return .closedHand
        case .resizeColumn: return .resizeLeftRight
        case .zoomIn:       return .arrow
        case .crosshair:    return .crosshair
        case .disallowed:   return .operationNotAllowed
        }
    }
}

/// Tracks hover and swaps the cursor without the flicker you get from calling
/// `NSCursor.set()` on every mouse-moved event. The cursor is pushed once on
/// entry and popped once on exit, and a shape change while already inside is
/// applied as a replace rather than a second push.
struct CursorMorph: ViewModifier {
    let cursor: SpatialCursor

    @State private var isInside = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    if !isInside {
                        isInside = true
                        cursor.nsCursor.push()
                    } else {
                        cursor.nsCursor.set()
                    }
                } else if isInside {
                    isInside = false
                    NSCursor.pop()
                }
            }
            .onChange(of: cursor) { _, newValue in
                guard isInside else { return }
                newValue.nsCursor.set()
            }
            .onDisappear {
                if isInside {
                    isInside = false
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    /// Morphs the pointer while it is over this view.
    func cursor(_ cursor: SpatialCursor) -> some View {
        modifier(CursorMorph(cursor: cursor))
    }
}

// MARK: - Pressable

/// A button style that compresses on press with a spring, giving every control
/// in the app the same tactile response curve.
struct SpatialButtonStyle: ButtonStyle {
    var depth: Spatial.Depth = .surface
    var tint: Color? = nil
    var padding: EdgeInsets = EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(padding)
            .glassSurface(depth, highlighted: isHovering || configuration.isPressed, tint: tint)
            .scaleEffect(configuration.isPressed ? 0.965 : (isHovering ? 1.012 : 1.0))
            .animation(Spatial.Motion.crisp, value: configuration.isPressed)
            .animation(Spatial.Motion.crisp, value: isHovering)
            .onHover { isHovering = $0 }
            .cursor(.interactive)
    }
}

// MARK: - Shimmer

/// A travelling specular highlight used on loading and streaming surfaces.
struct ShimmerModifier: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.18),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: phase * geo.size.width * 1.5)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .mask(content)
                }
            }
            .onAppear { restart() }
            .onChange(of: active) { _, _ in restart() }
    }

    private func restart() {
        guard active else { return }
        phase = -1
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

extension View {
    func shimmer(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

// MARK: - Section Heading

struct SpatialSectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let trailing {
                trailing
            }
        }
        .padding(.horizontal, 8)
    }
}
