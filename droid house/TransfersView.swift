import SwiftUI

struct TransfersView: View {
    @ObservedObject var transferManager = TransferManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !transferManager.activeTransfers.isEmpty {
                    aggregateHeader
                }

                if !transferManager.activeTransfers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SpatialSectionHeader("Active")
                        VStack(spacing: 8) {
                            ForEach(transferManager.activeTransfers) { transfer in
                                TransferProgressRow(item: transfer) {
                                    transferManager.cancelTransfer(id: transfer.id)
                                }
                                .transition(
                                    .asymmetric(
                                        insertion: .scale(scale: 0.94).combined(with: .opacity),
                                        removal: .opacity
                                    )
                                )
                            }
                        }
                    }
                }

                if !transferManager.completedTransfers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SpatialSectionHeader("History") {
                            Button("Clear") { transferManager.clearCompleted() }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .cursor(.interactive)
                        }
                        VStack(spacing: 8) {
                            ForEach(transferManager.completedTransfers) { transfer in
                                FinishedTransferRow(item: transfer)
                            }
                        }
                    }
                }

                if transferManager.activeTransfers.isEmpty && transferManager.completedTransfers.isEmpty {
                    ContentUnavailableView {
                        Label("No Transfers", systemImage: "arrow.up.arrow.down.circle")
                    } description: {
                        Text("Your file transfer history will appear here.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(18)
            .animation(Spatial.Motion.fluid, value: transferManager.activeTransfers.count)
            .animation(Spatial.Motion.fluid, value: transferManager.completedTransfers.count)
        }
        .substrateBackground()
    }

    /// Combined fill across every running transfer, byte-weighted so a large
    /// file doesn't get the same say as a thumbnail.
    private var aggregateHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("\(transferManager.activeTransfers.count) in flight")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(throughputText)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
            }

            LiquidProgressBar(
                fraction: transferManager.aggregateProgress,
                height: 10,
                tint: .dhAccentBlue
            )
        }
        .padding(14)
        .glassSurface(.floating)
    }

    private var throughputText: String {
        let bps = transferManager.aggregateThroughput
        guard bps > 1 else { return "—" }
        return TransferItem.byteFormatter.string(fromByteCount: Int64(bps)) + "/s"
    }
}

// MARK: - Finished row

private struct FinishedTransferRow: View {
    let item: TransferItem
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: statusIcon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(item.status == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(item.timestamp, style: .time)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .glassSurface(.surface, highlighted: isHovering)
        .onHover { hovering in
            withAnimation(Spatial.Motion.crisp) { isHovering = hovering }
        }
    }

    private var subtitle: String {
        if let error = item.error { return error }
        if item.bytesTransferred > 0 {
            return "\(item.type.rawValue) · \(TransferItem.byteFormatter.string(fromByteCount: item.bytesTransferred))"
        }
        return item.type.rawValue
    }

    private var statusIcon: String {
        switch item.status {
        case .completed: return "checkmark"
        case .failed:    return "exclamationmark"
        case .cancelled: return "xmark"
        default:         return "ellipsis"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        default:         return .accentColor
        }
    }
}

#Preview {
    TransfersView()
        .frame(width: 520, height: 400)
}
