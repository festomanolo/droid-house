import SwiftUI

// MARK: - Liquid Progress Bar
//
// The file-transfer fill. Every pixel of the fill width is derived from
// `bytesTransferred / totalBytes` reported by ADBService's byte pollers — there
// is no timer-driven fake, no indeterminate cheat when a real total is known.
//
// Three layers compose the effect:
//   1. a spring-animated fill whose width tracks the byte fraction,
//   2. a KeyframeAnimator-driven specular crest that rides the leading edge,
//   3. a travelling sheen across the filled region while bytes are moving.

struct LiquidProgressBar: View {

    /// Fill fraction in `0...1`. Pass `nil` for a genuinely unknown total,
    /// which switches the bar into an honest indeterminate stream.
    let fraction: Double?

    var height: CGFloat = 8
    var tint: Color = .accentColor
    var isActive: Bool = true
    var showsCrest: Bool = true

    var body: some View {
        GeometryReader { geo in
            let track = geo.size.width

            ZStack(alignment: .leading) {
                // Track
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    }

                if let fraction {
                    determinateFill(width: track * clamp(fraction), track: track, fraction: clamp(fraction))
                } else {
                    indeterminateFill(track: track)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Transfer progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }

    // MARK: Determinate

    private func determinateFill(width: CGFloat, track: CGFloat, fraction: Double) -> some View {
        ZStack(alignment: .trailing) {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.78), tint],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay {
                    // Inner top highlight — gives the fill volume.
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.42), .white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                }
                .overlay {
                    if isActive && fraction < 1 {
                        travellingSheen
                    }
                }
                .clipShape(Capsule(style: .continuous))

            // The crest: a soft bloom pinned to the leading edge that pulses
            // while bytes are in flight, so a stalled transfer visibly stops
            // breathing even though the width hasn't changed.
            if showsCrest && isActive && fraction > 0.008 && fraction < 1 {
                crest
            }
        }
        // Width is the only thing animated — driven straight from byte counts.
        .frame(width: max(height, width))
        .animation(Spatial.Motion.fluid, value: width)
        .shadow(color: tint.opacity(isActive ? 0.35 : 0), radius: 5, y: 1)
    }

    private var crest: some View {
        KeyframeAnimator(
            initialValue: CrestState(),
            repeating: true
        ) { state in
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(state.opacity), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: height * 1.2
                    )
                )
                .frame(width: height * 2.4, height: height * 2.4)
                .scaleEffect(state.scale)
                .blendMode(.plusLighter)
                .offset(x: height * 0.5)
                .allowsHitTesting(false)
        } keyframes: { _ in
            KeyframeTrack(\CrestState.scale) {
                SpringKeyframe(1.25, duration: 0.55, spring: .snappy)
                SpringKeyframe(0.82, duration: 0.55, spring: .snappy)
            }
            KeyframeTrack(\CrestState.opacity) {
                CubicKeyframe(0.85, duration: 0.55)
                CubicKeyframe(0.35, duration: 0.55)
            }
        }
    }

    private var travellingSheen: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 1.6s loop, normalised to -0.4...1.4 so the band fully clears the
            // filled region at both ends.
            let phase = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6
            let x = -0.4 + phase * 1.8

            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.34), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(24, geo.size.width * 0.35))
                .offset(x: x * geo.size.width)
                .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Indeterminate

    private func indeterminateFill(track: CGFloat) -> some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: 1.35)) / 1.35
            // Ease the shuttle so it decelerates at the turns instead of
            // sliding at a constant, mechanical rate.
            let eased = (1 - cos(phase * 2 * .pi)) / 2
            let barWidth = track * 0.34
            let x = eased * (track - barWidth)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.25), tint, tint.opacity(0.25)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: barWidth)
                .offset(x: x)
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private struct CrestState {
        var scale: CGFloat = 0.82
        var opacity: Double = 0.35
    }
}

// MARK: - Transfer Row Bar
//
// The bar in context: name, byte readout, live throughput and ETA, all fed by
// the same byte stream as the fill.

struct TransferProgressRow: View {
    let item: TransferItem
    var onCancel: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        // Re-evaluated 4x/second so the ETA and throughput text tick while the
        // byte counts themselves arrive on their own schedule.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 16)

                    Text(item.fileName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    if let fraction = item.fractionComplete {
                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(.secondary)
                    }

                    if let onCancel, isHovering, item.status == .progressing {
                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(.quaternary))
                        }
                        .buttonStyle(.plain)
                        .cursor(.interactive)
                        .transition(.scale.combined(with: .opacity))
                        .help("Cancel transfer")
                    }
                }

                LiquidProgressBar(
                    fraction: item.fractionComplete,
                    height: 7,
                    tint: tint,
                    isActive: item.status == .progressing
                )

                HStack(spacing: 6) {
                    Text(item.formattedBytes)
                        .monospacedDigit()
                    if item.status == .progressing {
                        Text("·")
                        Text(item.formattedThroughput)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        if let eta = item.estimatedTimeRemaining, eta > 0.5 {
                            Text("·")
                            Text("\(formatETA(eta)) left")
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            .padding(11)
            .glassSurface(.surface, highlighted: isHovering)
            .onHover { hovering in
                withAnimation(Spatial.Motion.crisp) { isHovering = hovering }
            }
        }
    }

    private var icon: String {
        switch item.type {
        case .upload:   return "arrow.up.circle.fill"
        case .download: return "arrow.down.circle.fill"
        case .move:     return "arrow.left.arrow.right.circle.fill"
        case .delete:   return "trash.circle.fill"
        }
    }

    private var tint: Color {
        switch item.status {
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        default:
            switch item.type {
            case .upload:   return .dhAccentBlue
            case .download: return .dhAccentMint
            case .move:     return .dhAccentViolet
            case .delete:   return .orange
            }
        }
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%dh %dm", s / 3600, (s % 3600) / 60)
    }
}

#Preview("Determinate") {
    VStack(spacing: 24) {
        LiquidProgressBar(fraction: 0.12)
        LiquidProgressBar(fraction: 0.48, tint: .dhAccentMint)
        LiquidProgressBar(fraction: 0.87, tint: .dhAccentViolet)
        LiquidProgressBar(fraction: 1.0, tint: .green, isActive: false)
        LiquidProgressBar(fraction: nil)
    }
    .padding(30)
    .frame(width: 380)
    .background(Color.dhSubstrate)
}
