import SwiftUI

struct TransferStatusPill: View {
    @ObservedObject var transferManager = TransferManager.shared
    @State private var isExpanded = false
    
    var body: some View {
        if let active = transferManager.activeTransfers.first {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 2)
                        .frame(width: 18, height: 18)
                    
                    Circle()
                        .trim(from: 0, to: active.progress > 0 ? active.progress : 0.1)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear, value: active.progress)
                }
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(active.type.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    
                    Text(active.fileName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    }
            }
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
        }
    }
}

#Preview {
    TransferStatusPill()
}
