import SwiftUI

/// A compact, Dynamic-Island-style transfer indicator for the window toolbar.
/// While a transfer runs it shows a real filling progress ring, the file name
/// and a live "time remaining" countdown; on completion it springs into a
/// green success tick (or red error) before gracefully dismissing itself.
struct TransferStatusPill: View {
    @ObservedObject var transferManager = TransferManager.shared

    var body: some View {
        Group {
            if let active = transferManager.activeTransfers.first {
                ProgressPill(item: active) {
                    transferManager.cancelTransfer(id: active.id)
                }
                .transition(pillTransition)
            } else if let finished = transferManager.lastFinished {
                FinishedPill(item: finished)
                    .transition(pillTransition)
                    .id(finished.id)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: transferManager.activeTransfers.first?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: transferManager.lastFinished?.id)
    }

    private var pillTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.6).combined(with: .opacity),
            removal: .scale(scale: 0.8).combined(with: .opacity)
        )
    }
}

// MARK: - Active transfer

private struct ProgressPill: View {
    let item: TransferItem
    let onCancel: () -> Void

    @State private var isHovering = false

    var body: some View {
        // Smoothly re-evaluate ~4×/second so the ring animates and the ETA ticks.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: 9) {
                ring

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.fileName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)

                    LiquidProgressBar(
                        fraction: item.fractionComplete,
                        height: 3.5,
                        tint: .accentColor,
                        showsCrest: false
                    )
                    .frame(width: 150)

                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                }

                if isHovering {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                    .help("Cancel transfer")
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, isHovering ? 6 : 12)
            .padding(.vertical, 6)
            .background(pillBackground)
            .onHover { hovering in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovering = hovering }
            }
        }
    }

    /// The ring is the pill's fill: its trim comes straight from the transfer's
    /// byte fraction. With no measurable total it sweeps instead of lying.
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 2.5)

            if let fraction = item.fractionComplete {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(
                        AngularGradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(Spatial.Motion.fluid, value: fraction)

                Text("\(Int(fraction * 100))")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                indeterminateSweep
            }
        }
        .frame(width: 22, height: 22)
    }

    private var indeterminateSweep: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 1.1)) / 1.1 * 360
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(
                    AngularGradient(colors: [Color.accentColor.opacity(0.1), Color.accentColor],
                                    center: .center),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(angle - 90))
        }
    }

    private var subtitle: String {
        var parts: [String] = [directionVerb]
        if item.bytesPerSecond > 1 {
            parts.append(item.formattedThroughput)
        }
        if let eta = item.estimatedTimeRemaining, eta > 0.5 {
            parts.append(formatETA(eta) + " left")
        }
        return parts.joined(separator: " · ")
    }

    private var directionVerb: String {
        switch item.type {
        case .upload:   return "To device"
        case .download: return "To Mac"
        case .move:     return "Moving"
        case .delete:   return "Deleting"
        }
    }

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(Capsule(style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Finished (success / failure) flourish

private struct FinishedPill: View {
    let item: TransferItem

    @State private var appeared = false

    private var succeeded: Bool { item.status == .completed }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill((succeeded ? Color.green : Color.red).opacity(0.15))
                    .frame(width: 22, height: 22)
                Image(systemName: succeeded ? "checkmark" : "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(succeeded ? Color.green : Color.red)
                    .scaleEffect(appeared ? 1 : 0.3)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.fileName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                Text(succeeded ? "Completed" : (item.error ?? "Failed"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(succeeded ? .secondary : Color.red)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke((succeeded ? Color.green : Color.red).opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        )
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { appeared = true }
        }
    }
}

#Preview {
    TransferStatusPill()
        .padding()
}
