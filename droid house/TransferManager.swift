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
    var status: TransferStatus
    var error: String?
    let timestamp: Date
    var startedAt: Date? = nil          // when the first byte landed

    /// Bytes confirmed written so far. This is the authoritative value the
    /// progress bar fills from — `progress` is derived, never set by hand.
    var bytesTransferred: Int64 = 0

    /// Total byte count of the payload. `nil` while it is still being probed
    /// (or for operations like delete that have no measurable size).
    var totalBytes: Int64? = nil

    /// Rolling throughput in bytes/second, smoothed across samples so the
    /// readout doesn't jitter between adb polls.
    var bytesPerSecond: Double = 0

    var task: Task<Void, Never>? = nil

    enum CodingKeys: String, CodingKey {
        case id, type, fileName, source, destination, status, error
        case timestamp, startedAt, bytesTransferred, totalBytes, bytesPerSecond
    }

    /// Fraction complete in `0...1`, derived strictly from bytes.
    ///
    /// Returns `nil` when the total size is unknown, which lets the UI show an
    /// indeterminate stream instead of lying with a fake percentage.
    var fractionComplete: Double? {
        guard status != .completed else { return 1.0 }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(bytesTransferred) / Double(totalBytes)))
    }

    /// Value the progress bar animates to. Falls back to 0 when indeterminate.
    var progress: Double { fractionComplete ?? 0 }

    var isIndeterminate: Bool { fractionComplete == nil && status == .progressing }

    /// Seconds remaining, projected from measured throughput rather than from
    /// elapsed wall-clock, so a slow start doesn't poison the estimate.
    var estimatedTimeRemaining: TimeInterval? {
        guard status == .progressing,
              let totalBytes, totalBytes > 0,
              bytesPerSecond > 1 else { return nil }
        let remaining = Double(totalBytes - bytesTransferred)
        guard remaining > 0 else { return nil }
        return remaining / bytesPerSecond
    }

    var formattedThroughput: String {
        guard bytesPerSecond > 1 else { return "—" }
        return TransferItem.byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    var formattedBytes: String {
        let done = TransferItem.byteFormatter.string(fromByteCount: bytesTransferred)
        guard let totalBytes, totalBytes > 0 else { return done }
        let total = TransferItem.byteFormatter.string(fromByteCount: totalBytes)
        return "\(done) of \(total)"
    }

    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.isAdaptive = true
        return f
    }()
}

@MainActor
final class TransferManager: ObservableObject {
    @Published var activeTransfers: [TransferItem] = []
    @Published var completedTransfers: [TransferItem] = []

    /// The most recently finished transfer, kept briefly so the status pill can
    /// present a Dynamic-Island-style success/failure flourish before clearing.
    @Published var lastFinished: TransferItem?

    static let shared = TransferManager()

    private init() {}

    private var flourishTask: Task<Void, Never>?

    /// Per-transfer throughput sampling state.
    private struct Sample {
        var lastBytes: Int64
        var lastTime: Date
    }
    private var samples: [UUID: Sample] = [:]

    private func flourish(_ item: TransferItem) {
        lastFinished = item
        flourishTask?.cancel()
        flourishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.lastFinished = nil
        }
    }

    func startTransfer(
        type: TransferType,
        fileName: String,
        source: String,
        destination: String,
        totalBytes: Int64? = nil
    ) -> UUID {
        let id = UUID()
        let item = TransferItem(
            id: id,
            type: type,
            fileName: fileName,
            source: source,
            destination: destination,
            status: .progressing,
            timestamp: Date(),
            bytesTransferred: 0,
            totalBytes: totalBytes
        )
        activeTransfers.append(item)
        samples[id] = Sample(lastBytes: 0, lastTime: Date())
        return id
    }

    /// Supplies the payload size once it has been probed, upgrading the
    /// transfer from indeterminate to a real percentage.
    func setTotalBytes(id: UUID, totalBytes: Int64?) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == id }) else { return }
        activeTransfers[index].totalBytes = totalBytes
    }

    /// The single entry point for progress. Everything the UI shows — fill
    /// fraction, throughput, ETA — is computed from these byte counts.
    func updateBytes(id: UUID, bytesTransferred: Int64) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == id }) else { return }

        // Never let a stale poll walk the bar backwards.
        let clamped = max(activeTransfers[index].bytesTransferred, bytesTransferred)

        if activeTransfers[index].startedAt == nil && clamped > 0 {
            activeTransfers[index].startedAt = Date()
        }

        let now = Date()
        if var sample = samples[id] {
            let elapsed = now.timeIntervalSince(sample.lastTime)
            if elapsed > 0.05 {
                let delta = Double(clamped - sample.lastBytes)
                let instant = delta / elapsed
                let previous = activeTransfers[index].bytesPerSecond
                // Exponential smoothing keeps the readout legible while still
                // reacting within a couple of samples to a real speed change.
                activeTransfers[index].bytesPerSecond =
                    previous == 0 ? instant : (previous * 0.65 + instant * 0.35)
                sample.lastBytes = clamped
                sample.lastTime = now
                samples[id] = sample
            }
        }

        activeTransfers[index].bytesTransferred = clamped
    }

    func completeTransfer(id: UUID) {
        if let index = activeTransfers.firstIndex(where: { $0.id == id }) {
            var item = activeTransfers.remove(at: index)
            item.status = .completed
            if let total = item.totalBytes {
                item.bytesTransferred = total
            }
            samples[id] = nil
            completedTransfers.insert(item, at: 0)
            flourish(item)
        }
    }

    func failTransfer(id: UUID, error: String) {
        if let index = activeTransfers.firstIndex(where: { $0.id == id }) {
            var item = activeTransfers.remove(at: index)
            item.status = .failed
            item.error = error
            samples[id] = nil
            completedTransfers.insert(item, at: 0)
            flourish(item)
        }
    }

    func clearCompleted() {
        completedTransfers.removeAll()
    }

    func cancelTransfer(id: UUID) {
        if let index = activeTransfers.firstIndex(where: { $0.id == id }) {
            var item = activeTransfers.remove(at: index)
            item.task?.cancel()
            item.status = .cancelled
            samples[id] = nil
            completedTransfers.insert(item, at: 0)
        }
    }

    func setTask(id: UUID, task: Task<Void, Never>) {
        if let index = activeTransfers.firstIndex(where: { $0.id == id }) {
            activeTransfers[index].task = task
        }
    }

    // MARK: - Aggregate

    /// Combined fill fraction across every running transfer, weighted by size.
    /// Used by the global transfer bar in the toolbar.
    var aggregateProgress: Double? {
        let sized = activeTransfers.compactMap { item -> (Int64, Int64)? in
            guard let total = item.totalBytes, total > 0 else { return nil }
            return (item.bytesTransferred, total)
        }
        guard !sized.isEmpty else { return nil }
        let done = sized.reduce(Int64(0)) { $0 + $1.0 }
        let total = sized.reduce(Int64(0)) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return min(1.0, Double(done) / Double(total))
    }

    var aggregateThroughput: Double {
        activeTransfers.reduce(0) { $0 + $1.bytesPerSecond }
    }
}
