import SwiftUI

struct StorageIndicatorView: View {
    let info: ADBService.StorageInfo
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 4)
                    .frame(width: 36, height: 36)
                
                Circle()
                    .trim(from: 0, to: info.percent)
                    .stroke(
                        info.percent > 0.9 ? Color.red : (info.isInternal ? Color.accentColor : Color.purple),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(), value: info.percent)
                
                Text("\(Int(info.percent * 100))%")
                    .font(.system(size: 9, weight: .bold))
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(info.label)
                    .font(.system(size: 11, weight: .bold))
                Text("\(info.available) free of \(info.total)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .frame(maxWidth: 220) // Increased maxWidth to prevent overflow
        .help("\(info.label): \(info.used) used of \(info.total) (\(info.available) available)")
    }
}
