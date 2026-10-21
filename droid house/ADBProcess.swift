//
//  ADBProcess.swift
//  droid house
//
//  One-shot adb invocations that never park a thread while adb runs.
//
//  The previous approach called `readDataToEndOfFile()` on a global queue for
//  every command, so each in-flight adb call pinned a GCD worker. A folder of
//  photos fetching thumbnails was enough to exhaust the pool and stall every
//  other adb call in the app. It also drained stdout before stderr, which
//  deadlocks once stderr fills its pipe buffer, and had no way to stop adb
//  when the caller gave up.
//

import Foundation

nonisolated final class ADBProcess: @unchecked Sendable {

    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }

        /// Best human-readable explanation for a non-zero exit.
        var errorText: String {
            let err = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty { return err }
            let out = stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? "adb exited with status \(status)" : out
        }
    }

    /// Runs adb to completion and returns everything it printed.
    ///
    /// - Parameter timeout: Hard limit in seconds, or `nil` for none. Bulk
    ///   transfers pass `nil`: a large file over Wi-Fi can legitimately take
    ///   longer than any fixed limit, and the user can always cancel.
    ///
    /// Cancelling the calling task terminates adb and throws `CancellationError`.
    static func run(adb: String, arguments: [String], timeout: TimeInterval? = 30) async throws -> Output {
        try await ADBProcess(adb: adb, arguments: arguments).start(timeout: timeout)
    }

    /// Points `process` at adb, going through `/usr/bin/env` only when the
    /// locator could not find an absolute path.
    static func configure(_ process: Process, adb: String, arguments: [String]) {
        if adb.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: adb)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [adb] + arguments
        }
    }

    // MARK: - Private

    private let process = Process()
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    /// stdout EOF, stderr EOF and process exit must all arrive before the
    /// output is complete; exit alone can beat the last buffered bytes.
    private var pendingEvents = 3
    private var launched = false
    private var finished = false
    private var cancelled = false
    private var timedOut = false
    private var continuation: CheckedContinuation<Output, Error>?
    private var timeoutItem: DispatchWorkItem?
    private var timeoutSeconds: TimeInterval = 0

    private init(adb: String, arguments: [String]) {
        Self.configure(process, adb: adb, arguments: arguments)
    }

    private func start(timeout: TimeInterval?) async throws -> Output {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                launch(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let running = launched && !finished
            lock.unlock()
            if running { process.terminate() }
        }
    }

    private func launch(continuation: CheckedContinuation<Output, Error>, timeout: TimeInterval?) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // `adb shell` forwards stdin to the device; never let it wait on ours.
        process.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eventArrived()
            } else {
                lock.lock(); stdout.append(chunk); lock.unlock()
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eventArrived()
            } else {
                lock.lock(); stderr.append(chunk); lock.unlock()
            }
        }
        process.terminationHandler = { [self] _ in eventArrived() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            finished = true
            let pending = self.continuation
            self.continuation = nil
            lock.unlock()
            pending?.resume(throwing: ADBError.processError(error.localizedDescription))
            return
        }

        lock.lock()
        launched = true
        let cancelledBeforeLaunch = cancelled
        lock.unlock()
        if cancelledBeforeLaunch { process.terminate() }

        if let timeout {
            timeoutSeconds = timeout
            let item = DispatchWorkItem { [self] in
                lock.lock()
                let running = !finished
                if running { timedOut = true }
                lock.unlock()
                if running { process.terminate() }
            }
            timeoutItem = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    private func eventArrived() {
        lock.lock()
        pendingEvents -= 1
        guard pendingEvents == 0, !finished else {
            lock.unlock()
            return
        }
        finished = true
        let pending = continuation
        continuation = nil
        let output = Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        let wasCancelled = cancelled
        let wasTimedOut = timedOut
        lock.unlock()

        timeoutItem?.cancel()

        if wasCancelled {
            pending?.resume(throwing: CancellationError())
        } else if wasTimedOut {
            pending?.resume(throwing: ADBError.timedOut(timeoutSeconds))
        } else {
            pending?.resume(returning: output)
        }
    }
}
