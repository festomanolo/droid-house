import Foundation

// MARK: - Companion file API
//
// The explorer's adb commands — `ls`, `pull`, `push`, `mv`, `cp`, `rm`, `df`,
// `exec-out cat`, `exec-out tar` — expressed against the companion's `/api/fs`
// routes, for phones connected over Wi-Fi with no adb.

enum CompanionFileError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        }
    }
}

nonisolated struct CompanionFiles: Sendable {
    let endpoint: CompanionEndpoint

    private struct Entry: Decodable {
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modified: Int64
        let permissions: String
    }

    private struct SizeReply: Decodable {
        let bytes: Int64
    }

    private struct Volume: Decodable {
        let id: String
        let label: String
        let totalBytes: Int64
        let freeBytes: Int64
        let isInternal: Bool
    }

    // MARK: Listing

    func list(_ path: String) async throws -> [RemoteFile] {
        let data = try await send(endpoint.request("/api/fs/list", query: [.init(name: "path", value: path)], timeout: 30))
        let entries = try JSONDecoder().decode([Entry].self, from: data)

        // Same "yyyy-MM-dd HH:mm" text `ls -la` produces, which the explorer
        // sorts and displays as-is.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        return entries.map { entry in
            RemoteFile(
                name: entry.name,
                isDirectory: entry.isDirectory,
                size: entry.size,
                permissions: entry.permissions,
                modifiedDate: formatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.modified) / 1000)),
                fullPath: Self.join(path, entry.name)
            )
        }
    }

    /// Byte size of a file, or the recursive size of a folder.
    func size(_ path: String) async -> Int64? {
        guard let data = try? await send(endpoint.request("/api/fs/size", query: [.init(name: "path", value: path)], timeout: 30)),
              let reply = try? JSONDecoder().decode(SizeReply.self, from: data) else { return nil }
        return reply.bytes
    }

    /// File bytes, optionally only the first `maxSize` (thumbnails).
    func data(_ path: String, maxSize: Int? = nil) async throws -> Data {
        var query = [URLQueryItem(name: "path", value: path)]
        if let maxSize { query.append(.init(name: "max", value: String(maxSize))) }
        return try await send(endpoint.request("/api/fs/file", query: query, timeout: 120))
    }

    func storage() async throws -> [ADBService.StorageInfo] {
        let data = try await send(endpoint.request("/api/fs/storage", timeout: 15))
        let volumes = try JSONDecoder().decode([Volume].self, from: data)
        let format: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return volumes.map { volume in
            let used = max(0, volume.totalBytes - volume.freeBytes)
            return ADBService.StorageInfo(
                id: volume.id,
                label: volume.label,
                total: format(volume.totalBytes),
                used: format(used),
                available: format(volume.freeBytes),
                percent: volume.totalBytes > 0 ? Double(used) / Double(volume.totalBytes) : 0,
                isInternal: volume.isInternal
            )
        }
    }

    // MARK: Mutations

    func makeDirectory(_ path: String) async throws {
        try await post("/api/fs/mkdir", ["path": path])
    }

    func delete(_ paths: [String]) async throws {
        try await post("/api/fs/delete", ["paths": paths], timeout: 120)
    }

    func move(from: String, to: String) async throws {
        try await post("/api/fs/move", ["from": from, "to": to], timeout: 600)
    }

    func copy(from: String, to: String) async throws {
        try await post("/api/fs/copy", ["from": from, "to": to], timeout: 3600)
    }

    // MARK: Transfers

    /// Phone → Mac. Files stream straight to `localPath`; folders arrive as a
    /// tar stream unpacked on the fly, so dates survive just as with `pull -a`.
    func download(remotePath: String, isDirectory: Bool, to localPath: String) async throws {
        if !isDirectory {
            FileManager.default.createFile(atPath: localPath, contents: nil)
            let sink = try FileHandle(forWritingTo: URL(fileURLWithPath: localPath))
            defer { try? sink.close() }
            guard let request = endpoint.request("/api/fs/file", query: [.init(name: "path", value: remotePath)], timeout: 120) else {
                throw CompanionFileError.server("Bad bridge URL")
            }
            try await StreamingDownload.run(request) { try sink.write(contentsOf: $0) }
            return
        }

        let remoteParent = (remotePath as NSString).deletingLastPathComponent
        let remoteName = (remotePath as NSString).lastPathComponent
        let localParent = (localPath as NSString).deletingLastPathComponent
        let staging = (localParent as NSString).appendingPathComponent(".droidhouse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: staging) }

        try await downloadTar(root: remoteParent.isEmpty ? "/" : remoteParent, paths: [remoteName]) { tar in
            try await Self.extract(tar: tar, into: staging)
        }
        try FileManager.default.moveItem(
            atPath: (staging as NSString).appendingPathComponent(remoteName),
            toPath: localPath
        )
    }

    /// Mac → phone: a file, or a folder walked file by file (each keeps its
    /// modification date). `progress` receives the running byte count.
    func upload(localPath: String, toDirectory remoteDirectory: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let localURL = URL(fileURLWithPath: localPath)
        let name = localURL.lastPathComponent
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory)

        guard isDirectory.boolValue else {
            try await uploadFile(localURL, to: Self.join(remoteDirectory, name)) { progress($0) }
            return
        }

        let remoteRoot = Self.join(remoteDirectory, name)
        try await makeDirectory(remoteRoot)

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: localURL, includingPropertiesForKeys: keys)
        var items: [URL] = []
        while let url = enumerator?.nextObject() as? URL { items.append(url) }

        var sent: Int64 = 0
        let rootPath = localURL.standardizedFileURL.path
        for url in items {
            try Task.checkCancellation()
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let remote = Self.join(remoteRoot, relative)
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                try await makeDirectory(remote)
            } else {
                let base = sent
                try await uploadFile(url, to: remote) { progress(base + $0) }
                sent += Int64(values?.fileSize ?? 0)
                progress(sent)
            }
        }
    }

    /// Streams `tar -cf -` of `paths` under `root` into `consume`.
    func downloadTar(root: String, paths: [String], consume: @escaping @Sendable (Pipe) async throws -> Void) async throws {
        var query = [URLQueryItem(name: "root", value: root)]
        query += paths.map { URLQueryItem(name: "paths", value: $0) }
        guard let request = endpoint.request("/api/fs/tar", query: query, timeout: 120) else {
            throw CompanionFileError.server("Bad bridge URL")
        }
        let pipe = Pipe()
        async let consumer: Void = consume(pipe)
        do {
            try await StreamingDownload.run(request) { try pipe.fileHandleForWriting.write(contentsOf: $0) }
            try? pipe.fileHandleForWriting.close()
        } catch {
            try? pipe.fileHandleForWriting.close()
            _ = try? await consumer
            throw error
        }
        try await consumer
    }

    /// Writes a tar archive from the phone to a local file, reporting bytes.
    func downloadTar(root: String, paths: [String], to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var query = [URLQueryItem(name: "root", value: root)]
        query += paths.map { URLQueryItem(name: "paths", value: $0) }
        guard let request = endpoint.request("/api/fs/tar", query: query, timeout: 120) else {
            throw CompanionFileError.server("Bad bridge URL")
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let sink = try FileHandle(forWritingTo: destination)
        defer { try? sink.close() }
        var total: Int64 = 0
        try await StreamingDownload.run(request) { chunk in
            try sink.write(contentsOf: chunk)
            total += Int64(chunk.count)
            progress(total)
        }
    }

    /// Extracts a local tar archive into `root` on the phone, restoring dates.
    func uploadTar(_ archive: URL, into root: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard var request = endpoint.request("/api/fs/untar", query: [.init(name: "root", value: root)], method: "POST", timeout: 600) else {
            throw CompanionFileError.server("Bad bridge URL")
        }
        request.setValue("application/x-tar", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: archive, delegate: UploadProgress(progress))
        try Self.check(data, response)
    }

    // MARK: Plumbing

    private func uploadFile(_ url: URL, to remotePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var query = [URLQueryItem(name: "path", value: remotePath)]
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            query.append(.init(name: "mtime", value: String(Int64(date.timeIntervalSince1970 * 1000))))
        }
        guard var request = endpoint.request("/api/fs/file", query: query, method: "PUT", timeout: 120) else {
            throw CompanionFileError.server("Bad bridge URL")
        }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: url, delegate: UploadProgress(progress))
        try Self.check(data, response)
    }

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 30) async throws {
        guard var request = endpoint.request(path, method: "POST", timeout: timeout) else {
            throw CompanionFileError.server("Bad bridge URL")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request)
    }

    private func send(_ request: URLRequest?) async throws -> Data {
        guard let request else { throw CompanionFileError.server("Bad bridge URL") }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(data, response)
        return data
    }

    /// Turns a non-2xx reply into the companion's own explanation.
    static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
        throw CompanionFileError.server(message ?? "The phone answered HTTP \(http.statusCode).")
    }

    private static func extract(tar: Pipe, into directory: String) async throws {
        // If tar dies mid-stream, the next write into its pipe would raise
        // SIGPIPE and kill the whole app; ignored, it fails with EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", "-", "-C", directory]
        process.standardInput = tar
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: CompanionFileError.server(text.isEmpty ? "tar failed" : text))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    static func join(_ directory: String, _ name: String) -> String {
        guard !name.isEmpty else { return directory }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

// MARK: - Streaming helpers

/// Hands a response body to `sink` chunk by chunk as it arrives, so a
/// multi-gigabyte video never sits in memory. Cancelling the calling task
/// cancels the request.
nonisolated final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sink: (Data) throws -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var status = 0
    private var errorBody = Data()
    private var failure: Error?

    private init(sink: @escaping (Data) throws -> Void) {
        self.sink = sink
    }

    static func run(_ request: URLRequest, sink: @escaping (Data) throws -> Void) async throws {
        let delegate = StreamingDownload(sink: sink)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard (200...299).contains(status) else {
            errorBody.append(data)
            return
        }
        do {
            try sink(data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil

        if let failure {
            continuation.resume(throwing: failure)
        } else if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            continuation.resume(throwing: cancelled ? CancellationError() : error)
        } else if !(200...299).contains(status) {
            let message = (try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any])?["message"] as? String
            continuation.resume(throwing: CompanionFileError.server(message ?? "The phone answered HTTP \(status)."))
        } else {
            continuation.resume()
        }
    }
}

/// Reports bytes sent for one upload task.
nonisolated final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void

    init(_ report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }
}
