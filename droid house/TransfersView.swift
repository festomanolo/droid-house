import SwiftUI

struct TransfersView: View {
    @ObservedObject var transferManager = TransferManager.shared
    
    var body: some View {
        List {
            if !transferManager.activeTransfers.isEmpty {
                Section("Active") {
                    ForEach(transferManager.activeTransfers) { transfer in
                        TransferRow(item: transfer)
                    }
                }
            }
            
            if !transferManager.completedTransfers.isEmpty {
                Section {
                    ForEach(transferManager.completedTransfers) { transfer in
                        TransferRow(item: transfer)
                    }
                } header: {
                    HStack {
                        Text("Completed")
                        Spacer()
                        Button("Clear All") {
                            transferManager.clearCompleted()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
            }
            
            if transferManager.activeTransfers.isEmpty && transferManager.completedTransfers.isEmpty {
                ContentUnavailableView {
                    Label("No Transfers", systemImage: "arrow.up.arrow.down.circle")
                } description: {
                    Text("Your file transfer history will appear here.")
                }
            }
        }
    }
}

struct TransferRow: View {
    let item: TransferItem
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .frame(width: 40, height: 40)
                
                Image(systemName: iconName)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 18))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.fileName)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                if item.status == .progressing {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                } else if let error = item.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    Text(item.type.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var iconName: String {
        switch item.type {
        case .upload: return "arrow.up.circle.fill"
        case .download: return "arrow.down.circle.fill"
        case .move: return "arrow.right.circle.fill"
        case .delete: return "trash.circle.fill"
        }
    }
    
    private var statusColor: Color {
        switch item.status {
        case .pending, .progressing: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
    
    private var statusText: String {
        switch item.status {
        case .pending: return "Pending"
        case .progressing: return "\(Int(item.progress * 100))%"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

#Preview {
    TransfersView()
}
