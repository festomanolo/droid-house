import Foundation
import Combine

enum TransferType: String, Codable {
    case upload = "Copying to Device"
    case download = "Copying to Mac"
    case move = "Moving"
    case delete = "Deleting"
}

enum TransferStatus: String, Codable {
    case pending
    case progressing
    case completed
    case failed
    case cancelled
}

struct TransferItem: Identifiable, Codable {
    let id: UUID
    let type: TransferType
    let fileName: String
    let source: String
    let destination: String
    var progress: Double // 0.0 to 1.0
    var status: TransferStatus
    var error: String?
    let timestamp: Date
}

class TransferManager: ObservableObject {
    @Published var activeTransfers: [TransferItem] = []
    @Published var completedTransfers: [TransferItem] = []
    
    static let shared = TransferManager()
    
    private init() {}
    
    func startTransfer(type: TransferType, fileName: String, source: String, destination: String) -> UUID {
        let id = UUID()
        let item = TransferItem(
            id: id,
            type: type,
            fileName: fileName,
            source: source,
            destination: destination,
            progress: 0.0,
            status: .progressing,
            timestamp: Date()
        )
        
        DispatchQueue.main.async {
            self.activeTransfers.append(item)
        }
        return id
    }
    
    func updateProgress(id: UUID, progress: Double) {
        DispatchQueue.main.async {
            if let index = self.activeTransfers.firstIndex(where: { $0.id == id }) {
                self.activeTransfers[index].progress = progress
            }
        }
    }
    
    func completeTransfer(id: UUID) {
        DispatchQueue.main.async {
            if let index = self.activeTransfers.firstIndex(where: { $0.id == id }) {
                var item = self.activeTransfers.remove(at: index)
                item.status = .completed
                item.progress = 1.0
                self.completedTransfers.insert(item, at: 0)
            }
        }
    }
    
    func failTransfer(id: UUID, error: String) {
        DispatchQueue.main.async {
            if let index = self.activeTransfers.firstIndex(where: { $0.id == id }) {
                var item = self.activeTransfers.remove(at: index)
                item.status = .failed
                item.error = error
                self.completedTransfers.insert(item, at: 0)
            }
        }
    }
    
    func clearCompleted() {
        DispatchQueue.main.async {
            self.completedTransfers.removeAll()
        }
    }
}
