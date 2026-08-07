//
//  ArchiveTransferEngine.swift
//  droid house
//
//  Zero-storage, lossless timestamp-preserving transfer engine.
//
//  Streams a `tar` archive directly between the Android device and the Mac
//  using real-time stdout/stdin piping — never writing an intermediate .tar
//  onto the device's internal storage. Because the archive carries POSIX
//  mtime metadata inside it, extraction restores the original modification
//  timestamps byte-for-byte (critical for non-EXIF media such as screenshots,
//  downloads and documents).
//

import Foundation
import Combine

@MainActor
final class ArchiveTransferEngine: ObservableObject {

    // MARK: - Types

    enum Direction: String, CaseIterable, Identifiable {
        case backup   // Device  ->  Mac   (adb exec-out "tar -cf -")
        case restore  // Mac     ->  Device (adb shell   "tar -xf -")

        var id: String { rawValue }

        var title: String {
            switch self {
            case .backup:  return "Back Up to Mac"
            case .restore: return "Restore to Device"
            }
        }

        var symbol: String {
            switch self {
            case .backup:  return "arrow.down.circle"
            case .restore: return "arrow.up.circle"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case preparing
        case streaming
        case finalizing        // "Locking POSIX timestamps…"
        case completed
        case cancelled
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .completed, .cancelled, .failed: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .idle:       return "Ready"
            case .preparing:  return "Preparing stream…"
            case .streaming:  return "Streaming archive…"
            case .finalizing: return "Locking POSIX timestamps…"
            case .completed:  return "Transfer complete"
            case .cancelled:  return "Cancelled"
            case .failed:     return "Failed"
            }
        }
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let timestamp = Date()
        let text: String
        let isError: Bool
    }

    // MARK: - Published State

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bytesTransferred: Int64 = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var lastArchiveURL: URL?
    @Published private(set) var direction: Direction = .backup

    var isRunning: Bool {
        switch phase {
        case .preparing, .streaming, .finalizing: return true
        default: return false
        }
    }

    // MARK: - Private

    private let adbPath: String
    private var worker: Process?
    private var sampler: Task<Void, Never>?
    private var startDate: Date?
    private var lastSampleBytes: Int64 = 0

    // MARK: - Init

    init() {
        self.adbPath = ADBLocator.resolve()
    }

    // MARK: - Public API

    /// Streams the selected remote directories into a single local `.tar`
    /// archive without ever materialising the archive on the device.
    func startBackup(serial: String, remoteRoot: String, relativePaths: [String], destination: URL) {
        guard !isRunning else { return }
        direction = .backup
        reset()
        phase = .preparing
        appendLog("Backing up \(relativePaths.count) location(s) from \(remoteRoot)", isError: false)

        // Build:  cd <root> && tar -cf - "p1" "p2" …
        let quoted = relativePaths.map { "\"\($0)\"" }.joined(separator: " ")
        let remoteCommand = "cd \(shellQuote(remoteRoot)) && tar -cf - \(quoted)"
        let arguments = ["-s", serial, "exec-out", remoteCommand]

        beginSampling()
        launchPull(arguments: arguments, destination: destination)
    }

    /// Streams an existing local `.tar` archive into the device, extracting it
    /// in place so that every file's original modification date is restored.
    func startRestore(serial: String, remoteRoot: String, archive: URL) {
        guard !isRunning else { return }
        direction = .restore
        reset()
        phase = .preparing
        appendLog("Restoring archive \(archive.lastPathComponent) into \(remoteRoot)", isError: false)

        // toybox `tar x` restores mtime by default (we deliberately avoid -m).
        let remoteCommand = "cd \(shellQuote(remoteRoot)) && tar -xf -"
        let arguments = ["-s", serial, "shell", remoteCommand]

        beginSampling()
        launchPush(arguments: arguments, source: archive, remoteRoot: remoteRoot)
    }

    /// Cancels any in-flight transfer and terminates the underlying process.
    func cancel() {
        guard isRunning else { return }
        appendLog("Cancellation requested — terminating stream.", isError: false)
        worker?.terminate()
        worker = nil
        finish(.cancelled)
    }

    /// Resets the dashboard back to an idle state (only when not running).
    func clear() {
        guard !isRunning else { return }
        reset()
        phase = .idle
    }

    /// Configures a process to run adb, falling back to `/usr/bin/env` for PATH
    /// resolution when only the bare "adb" name is available.
    private nonisolated static func configure(_ process: Process, adb: String, arguments: [String]) {
        if adb.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: adb)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [adb] + arguments
        }
    }

    // MARK: - Pull (device -> Mac)

    private func launchPull(arguments: [String], destination: URL) {
        let adb = adbPath

        // Create / truncate the destination archive up-front.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let sink = try? FileHandle(forWritingTo: destination) else {
            finish(.failed("Could not open destination archive for writing."))
            return
        }

        let process = Process()
        Self.configure(process, adb: adb, arguments: arguments)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        worker = process

        // Stream stdout (raw tar bytes) straight to disk, counting as we go.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            try? sink.write(contentsOf: chunk)
            let count = Int64(chunk.count)
            Task { @MainActor [weak self] in self?.advance(by: count) }
        }

        // Remote/adb errors (permission denied, connection dropped …).
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.ingestError(text) }
        }

        process.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? sink.close()
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.lastArchiveURL = destination
                self?.completePull(status: status, destination: destination)
            }
        }

        do {
            try process.run()
            phase = .streaming
            appendLog("Streaming tar archive over exec-out…", isError: false)
        } catch {
            try? sink.close()
            finish(.failed("Failed to launch adb: \(error.localizedDescription)"))
        }
    }

    private func completePull(status: Int32, destination: URL) {
        guard isRunning || phase == .streaming else { return } // ignore if already cancelled
        if status == 0 {
            phase = .finalizing
            let attrSize = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64
            let size = attrSize ?? bytesTransferred
            appendLog("Archive written (\(ByteFormat.string(size))). Timestamps embedded losslessly.", isError: false)
            finish(.completed)
        } else {
            finish(.failed("tar stream exited with status \(status). See log for details."))
        }
    }

    // MARK: - Push (Mac -> device)

    private func launchPush(arguments: [String], source: URL, remoteRoot: String) {
        let adb = adbPath

        let totalSize = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int64) ?? 0
        guard let reader = try? FileHandle(forReadingFrom: source) else {
            finish(.failed("Could not open archive for reading."))
            return
        }

        let process = Process()
        Self.configure(process, adb: adb, arguments: arguments)

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        worker = process

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.appendLog(text.trimmingCharacters(in: .whitespacesAndNewlines), isError: false) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.ingestError(text) }
        }

        // The stdin-feeding thread exclusively owns `reader` and closes it when
        // done, so the termination handler must not touch it (avoids a
        // cross-thread FileHandle close race).
        process.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in self?.completePush(status: status) }
        }

        do {
            try process.run()
            phase = .streaming
            appendLog("Streaming \(ByteFormat.string(totalSize)) archive into device…", isError: false)
        } catch {
            try? reader.close()
            finish(.failed("Failed to launch adb: \(error.localizedDescription)"))
            return
        }

        // Feed the archive into adb's stdin off the main thread, chunk by chunk,
        // so we get a live byte counter and never buffer the whole file in memory.
        let writeHandle = inPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let chunkSize = 256 * 1024
            while true {
                let chunk = reader.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                do {
                    try writeHandle.write(contentsOf: chunk)
                } catch {
                    break // pipe closed (process ended / cancelled)
                }
                let count = Int64(chunk.count)
                Task { @MainActor [weak self] in self?.advance(by: count) }
            }
            try? writeHandle.close()
            try? reader.close()
        }
    }

    private func completePush(status: Int32) {
        guard isRunning || phase == .streaming else { return }
        if status == 0 {
            phase = .finalizing
            appendLog("Extraction finished — POSIX modification dates restored on device.", isError: false)
            finish(.completed)
        } else {
            finish(.failed("Remote tar extraction exited with status \(status)."))
        }
    }

    // MARK: - Progress plumbing

    private func advance(by count: Int64) {
        bytesTransferred += count
    }

    private func beginSampling() {
        startDate = Date()
        lastSampleBytes = 0
        sampler?.cancel()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                await MainActor.run { self.sampleRate() }
            }
        }
    }

    private func sampleRate() {
        guard let start = startDate else { return }
        elapsed = Date().timeIntervalSince(start)
        let delta = bytesTransferred - lastSampleBytes
        // 500ms window -> multiply by 2 for per-second rate, smoothed.
        let instantaneous = Double(delta) * 2.0
        bytesPerSecond = bytesPerSecond == 0 ? instantaneous : (bytesPerSecond * 0.6 + instantaneous * 0.4)
        lastSampleBytes = bytesTransferred
    }

    private func finish(_ phase: Phase) {
        sampler?.cancel()
        sampler = nil
        bytesPerSecond = 0
        if let start = startDate { elapsed = Date().timeIntervalSince(start) }
        worker = nil
        self.phase = phase
        switch phase {
        case .completed: appendLog("Done in \(String(format: "%.1fs", elapsed)).", isError: false)
        case .failed(let msg): appendLog(msg, isError: true)
        default: break
        }
    }

    private func reset() {
        bytesTransferred = 0
        bytesPerSecond = 0
        elapsed = 0
        lastSampleBytes = 0
        log.removeAll()
    }

    // MARK: - Logging

    private func appendLog(_ text: String, isError: Bool) {
        guard !text.isEmpty else { return }
        for raw in text.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            log.append(LogLine(text: line, isError: isError))
        }
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func ingestError(_ text: String) {
        // adb prints benign progress notes to stderr too; only flag genuine errors.
        let lowered = text.lowercased()
        let looksFatal = lowered.contains("permission denied")
            || lowered.contains("no such file")
            || lowered.contains("device not found")
            || lowered.contains("offline")
            || lowered.contains("cannot")
            || lowered.contains("error")
        appendLog(text.trimmingCharacters(in: .whitespacesAndNewlines), isError: looksFatal)
    }

    // MARK: - Shell quoting

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Byte formatting

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "—" }
        return string(Int64(bytesPerSecond)) + "/s"
    }
}
