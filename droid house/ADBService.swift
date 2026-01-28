import Foundation
import Combine

@MainActor
class ADBService: ObservableObject {
    @Published var connectedDevices: [ADBDevice] = []
    @Published var currentFiles: [RemoteFile] = []
    @Published var currentPath: String = "/sdcard"
    @Published var selectedDevice: ADBDevice?
    @Published var isLoading: Bool = false
    @Published var lastError: String?
    @Published var sortOrder: SortOrder = .name
    @Published var storageInfo: [StorageInfo] = []
    
    private var refreshTask: Task<Void, Never>?
    private let adbPath: String
    
    init() {
        // Try to find adb in common locations
        if FileManager.default.fileExists(atPath: "/usr/local/bin/adb") {
            adbPath = "/usr/local/bin/adb"
        } else if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/adb") {
            adbPath = "/opt/homebrew/bin/adb"
        } else {
            adbPath = "adb" // Fallback to PATH
        }
        
        startAutoRefresh()
    }
    
    deinit {
        refreshTask?.cancel()
    }
    
    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                
                if selectedDevice == nil && !isLoading {
                    await detectDevices()
                }
            }
        }
    }
    
    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
    
    struct StorageInfo: Identifiable, Codable {
        let id: String
        let label: String
        let total: String
        let used: String
        let available: String
        let percent: Double
        let isInternal: Bool
    }
    
    enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Name"
        case date = "Date"
        case size = "Size"
        case type = "Type"
        
        var id: String { self.rawValue }
    }
    
    

    
    // MARK: - Device Management
    
    func detectDevices() async {
        isLoading = true
        lastError = nil
        
        do {
            let output = try await runADBCommand(["devices", "-l"])
            connectedDevices = parseDevices(output)
            
            // Auto-select first device if none selected
            if selectedDevice == nil, let first = connectedDevices.first {
                selectedDevice = first
                await listFiles(path: currentPath)
            }
        } catch {
            lastError = "Failed to detect devices: \(error.localizedDescription)"
        }
        
        if let device = selectedDevice {
            await fetchStorageInfo(device: device)
        }
        
        isLoading = false
    }
    
    private func parseDevices(_ output: String) -> [ADBDevice] {
        var devices: [ADBDevice] = []
        let lines = output.components(separatedBy: "\n")
        
        for line in lines {
            // Skip header and empty lines
            guard !line.starts(with: "List of devices") && !line.isEmpty else { continue }
            
            // Parse: serialnumber device usb:xxx product:xxx model:xxx device:xxx
            let parts = line.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2, parts[1] == "device" else { continue }
            
            let serial = parts[0]
            var model = ""
            var deviceName = ""
            
            for part in parts {
                if part.starts(with: "model:") {
                    model = String(part.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
                }
                if part.starts(with: "device:") {
                    deviceName = String(part.dropFirst(7))
                }
            }
            
            let isWireless = serial.contains(":")
            devices.append(ADBDevice(
                id: serial,
                name: deviceName,
                model: model,
                connectionType: isWireless ? .wireless : .usb,
                isConnected: true
            ))
        }
        
        return devices
    }
    
    // MARK: - File Operations
    
    func listFiles(path: String) async {
        guard let device = selectedDevice else {
            lastError = "No device selected"
            return
        }
        
        isLoading = true
        lastError = nil
        currentPath = path
        
        do {
            // Use ls -laL to follow symlinks, fall back to ls -la if that fails
            var output = try await runADBCommand(["-s", device.id, "shell", "ls", "-laL", path])
            // If the path itself is a symlink, ls -laL on it might fail or show weird results
            // In that case, just list the directory contents
            if output.contains("No such file") || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output = try await runADBCommand(["-s", device.id, "shell", "ls", "-la", path])
            }
            currentFiles = parseFileList(output, basePath: path)
        } catch {
            lastError = "Failed to list files: \(error.localizedDescription)"
            currentFiles = []
        }
        
        await fetchStorageInfo(device: device)
        isLoading = false
    }
    
    private func parseFileList(_ output: String, basePath: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        let lines = output.components(separatedBy: "\n")
        
        for line in lines {
            // Skip total line, empty lines, and error messages
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.starts(with: "total"),
                  !trimmed.contains("No such file"),
                  !trimmed.contains("Permission denied") else { continue }
            
            // Format: drwxrwx--x 4 root sdcard_rw 4096 2024-01-15 10:30 dirname
            // Format: -rw-rw---- 1 root sdcard_rw 12345 2024-01-15 10:30 filename.txt
            // Format: lrwxrwxrwx 1 root root 21 2024-01-15 10:30 link -> target
            let parts = line.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 7 else { continue }
            
            let permissions = parts[0]
            let isSymlink = permissions.hasPrefix("l")
            let isDirectory = permissions.hasPrefix("d") || (isSymlink && line.contains("-> /"))
            let size = Int64(parts[4]) ?? 0
            
            // Date is typically at index 5 and 6, filename starts at index 7
            let dateStr = "\(parts[5]) \(parts[6])"
            var name = parts.dropFirst(7).joined(separator: " ")
            
            // For symlinks, extract just the link name (before " -> ")
            if isSymlink, let arrowRange = name.range(of: " -> ") {
                name = String(name[..<arrowRange.lowerBound])
            }
            
            // Skip . and ..
            guard name != "." && name != ".." && !name.isEmpty else { continue }
            
            let fullPath = basePath.hasSuffix("/") ? "\(basePath)\(name)" : "\(basePath)/\(name)"
            
            files.append(RemoteFile(
                name: name,
                isDirectory: isDirectory,
                size: size,
                permissions: permissions,
                modifiedDate: dateStr,
                fullPath: fullPath
            ))
        }
        
        // Sort based on current sortOrder
        files.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            
            switch sortOrder {
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .date:
                // Simple date comparison - assume format "YYYY-MM-DD HH:MM" is sortable as string
                return a.modifiedDate.localizedCaseInsensitiveCompare(b.modifiedDate) == .orderedDescending
            case .size:
                return a.size > b.size
            case .type:
                return (a.name as NSString).pathExtension.localizedCaseInsensitiveCompare((b.name as NSString).pathExtension) == .orderedAscending
            }
        }
        
        return files
    }
    
    func navigateUp() async {
        let parentPath = (currentPath as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty && parentPath != currentPath else { return }
        await listFiles(path: parentPath)
    }
    
    func navigateTo(_ folder: RemoteFile) async {
        guard folder.isDirectory else { return }
        await listFiles(path: folder.fullPath)
    }
    
    // MARK: - File Transfer
    
    func pullFile(remotePath: String, localPath: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        let transferID = TransferManager.shared.startTransfer(
            type: .download,
            fileName: (remotePath as NSString).lastPathComponent,
            source: remotePath,
            destination: localPath
        )
        
        do {
            let stream = runADBStreamedCommand(["-s", device.id, "pull", "-p", remotePath, localPath])
            for await line in stream {
                if let progress = parseProgress(line) {
                    TransferManager.shared.updateProgress(id: transferID, progress: progress)
                }
            }
            TransferManager.shared.completeTransfer(id: transferID)
        } catch {
            TransferManager.shared.failTransfer(id: transferID, error: error.localizedDescription)
            throw error
        }
    }
    
    func pushFile(localPath: String, remotePath: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        let transferID = TransferManager.shared.startTransfer(
            type: .upload,
            fileName: (localPath as NSString).lastPathComponent,
            source: localPath,
            destination: remotePath
        )
        
        do {
            let stream = runADBStreamedCommand(["-s", device.id, "push", "-p", localPath, remotePath])
            for await line in stream {
                if let progress = parseProgress(line) {
                    TransferManager.shared.updateProgress(id: transferID, progress: progress)
                }
            }
            TransferManager.shared.completeTransfer(id: transferID)
            await listFiles(path: currentPath) // Refresh
        } catch {
            TransferManager.shared.failTransfer(id: transferID, error: error.localizedDescription)
            throw error
        }
    }
    
    private func parseProgress(_ line: String) -> Double? {
        // ADB progress looks like: [ 45%] /sdcard/file.txt
        let pattern = #"\[\s*(\d+)%\]"#
        if let range = line.range(of: pattern, options: .regularExpression) {
            let percentageStr = line[range].replacingOccurrences(of: "[", with: "")
                                          .replacingOccurrences(of: "]", with: "")
                                          .replacingOccurrences(of: "%", with: "")
                                          .trimmingCharacters(in: .whitespaces)
            if let percent = Double(percentageStr) {
                return percent / 100.0
            }
        }
        return nil
    }
    
    // MARK: - File Management
    
    func deleteFile(path: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        _ = try await runADBCommand(["-s", device.id, "shell", "rm", "-rf", path])
        await listFiles(path: currentPath) // Refresh
    }
    
    func createFolder(name: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        let newPath = currentPath.hasSuffix("/") ? "\(currentPath)\(name)" : "\(currentPath)/\(name)"
        _ = try await runADBCommand(["-s", device.id, "shell", "mkdir", "-p", newPath])
        await listFiles(path: currentPath) // Refresh
    }
    
    func renameFile(oldPath: String, newName: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        let directory = (oldPath as NSString).deletingLastPathComponent
        let newPath = directory.hasSuffix("/") ? "\(directory)\(newName)" : "\(directory)/\(newName)"
        _ = try await runADBCommand(["-s", device.id, "shell", "mv", oldPath, newPath])
        await listFiles(path: currentPath) // Refresh
    }
    
    // MARK: - Clipboard Operations
    
    @Published var clipboard: [RemoteFile] = []
    @Published var clipboardOperation: ClipboardOperation = .none
    
    enum ClipboardOperation {
        case none
        case copy
        case cut
    }
    
    func copyFiles(_ files: [RemoteFile]) {
        clipboard = files
        clipboardOperation = .copy
    }
    
    func cutFiles(_ files: [RemoteFile]) {
        clipboard = files
        clipboardOperation = .cut
    }
    
    func paste() async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        guard !clipboard.isEmpty else { return }
        
        for file in clipboard {
            let destPath = currentPath.hasSuffix("/") ? "\(currentPath)\(file.name)" : "\(currentPath)/\(file.name)"
            
            let transferID = TransferManager.shared.startTransfer(
                type: clipboardOperation == .cut ? .move : .upload,
                fileName: file.name,
                source: file.fullPath,
                destination: destPath
            )
            
            do {
                switch clipboardOperation {
                case .copy:
                    if file.isDirectory {
                        _ = try await runADBCommand(["-s", device.id, "shell", "cp", "-r", file.fullPath, destPath])
                    } else {
                        _ = try await runADBCommand(["-s", device.id, "shell", "cp", file.fullPath, destPath])
                    }
                case .cut:
                    _ = try await runADBCommand(["-s", device.id, "shell", "mv", file.fullPath, destPath])
                case .none:
                    break
                }
                TransferManager.shared.completeTransfer(id: transferID)
            } catch {
                TransferManager.shared.failTransfer(id: transferID, error: error.localizedDescription)
            }
        }
        
        // Clear clipboard after cut
        if clipboardOperation == .cut {
            clipboard = []
            clipboardOperation = .none
        }
        
        await listFiles(path: currentPath)
    }
    
    func deleteFiles(_ files: [RemoteFile]) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        for file in files {
            _ = try await runADBCommand(["-s", device.id, "shell", "rm", "-rf", file.fullPath])
        }
        
        await listFiles(path: currentPath)
    }
    
    func moveFiles(_ files: [RemoteFile], to destinationPath: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        for file in files {
            let destPath = destinationPath.hasSuffix("/") ? "\(destinationPath)\(file.name)" : "\(destinationPath)/\(file.name)"
            _ = try await runADBCommand(["-s", device.id, "shell", "mv", file.fullPath, destPath])
        }
        
        await listFiles(path: currentPath)
    }
    
    // MARK: - Wireless Connection
    
    func connectWireless(ip: String, port: Int = 5555) async throws {
        // First enable tcpip mode
        _ = try await runADBCommand(["tcpip", "\(port)"])
        try await Task.sleep(nanoseconds: 1_000_000_000) // Wait 1 second
        
        // Connect
        let output = try await runADBCommand(["connect", "\(ip):\(port)"])
        
        if output.contains("connected") || output.contains("already connected") {
            await detectDevices()
        } else {
            throw ADBError.connectionFailed(output)
        }
    }
    
    func getDeviceIP() async -> String? {
        guard let device = selectedDevice else { return nil }
        
        do {
            let output = try await runADBCommand(["-s", device.id, "shell", "ip", "route"])
            // Parse: ... src 192.168.x.x ...
            if let range = output.range(of: "src ") {
                let afterSrc = output[range.upperBound...]
                let ip = afterSrc.components(separatedBy: " ").first ?? ""
                return ip.isEmpty ? nil : ip
            }
        } catch {
            return nil
        }
        return nil
    }
    
    // MARK: - Storage Detection
    
    func fetchStorageInfo(device: ADBDevice) async {
        do {
            let output = try await runADBCommand(["-s", device.id, "shell", "df", "-h"])
            self.storageInfo = parseStorage(output)
        } catch {
            print("Failed to fetch storage info: \(error)")
        }
    }
    
    private func parseStorage(_ output: String) -> [StorageInfo] {
        var info: [StorageInfo] = []
        let lines = output.components(separatedBy: "\n")
        
        for line in lines {
            let parts = line.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 6 else { continue }
            
            let mountedOn = parts[5]
            let size = parts[1]
            let used = parts[2]
            let avail = parts[3]
            let usePercent = parts[4].replacingOccurrences(of: "%", with: "")
            
            if mountedOn == "/data" || mountedOn == "/storage/emulated" {
                // Internal Storage
                if !info.contains(where: { $0.isInternal }) {
                    info.append(StorageInfo(
                        id: "internal",
                        label: "Internal",
                        total: size,
                        used: used,
                        available: avail,
                        percent: (Double(usePercent) ?? 0) / 100.0,
                        isInternal: true
                    ))
                }
            } else if mountedOn.starts(with: "/storage/") && mountedOn != "/storage/emulated" && mountedOn != "/storage/self" {
                // SD Card or USB
                let label = mountedOn.components(separatedBy: "/").last ?? "SD Card"
                info.append(StorageInfo(
                    id: mountedOn,
                    label: label,
                    total: size,
                    used: used,
                    available: avail,
                    percent: (Double(usePercent) ?? 0) / 100.0,
                    isInternal: false
                ))
            }
        }
        
        return info
    }
    
    func fetchFileDataFast(path: String, maxSize: Int? = nil) async throws -> Data {
        guard let device = selectedDevice else { throw ADBError.noDevice }
        let adb = adbPath
        let deviceID = device.id
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                
                var command = "cat \"\(path)\""
                if let max = maxSize {
                    command = "dd if=\"\(path)\" bs=1k count=\(max / 1024) 2>/dev/null"
                }
                
                process.arguments = [adb, "-s", deviceID, "exec-out", command]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - ADB Command Execution
    
    private func runADBStreamedCommand(_ arguments: [String]) -> AsyncStream<String> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [self.adbPath] + arguments
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe // Capture both for progress parsing
                
                let fileHandle = pipe.fileHandleForReading
                fileHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else if let output = String(data: data, encoding: .utf8) {
                        continuation.yield(output)
                    }
                }
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    private func runADBCommand(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [self.adbPath] + arguments
                
                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    if process.terminationStatus != 0 {
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(throwing: ADBError.commandFailed(errorString))
                    } else {
                        let output = String(data: data, encoding: .utf8) ?? ""
                        continuation.resume(returning: output)
                    }
                } catch {
                    continuation.resume(throwing: ADBError.processError(error.localizedDescription))
                }
            }
        }
    }
}

enum ADBError: LocalizedError {
    case noDevice
    case commandFailed(String)
    case processError(String)
    case connectionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No device selected"
        case .commandFailed(let msg):
            return "ADB command failed: \(msg)"
        case .processError(let msg):
            return "Process error: \(msg)"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        }
    }
}
