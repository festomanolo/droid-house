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
    @Published var bookmarks: [String] = []
    
    private var refreshTask: Task<Void, Never>?
    let adbPath: String
    
    init() {
        // Robustly locate adb (handles custom install locations that Finder's
        // minimal PATH would otherwise hide).
        adbPath = ADBLocator.resolve()

        loadBookmarks()
        startAutoRefresh()
    }
    
    deinit {
        refreshTask?.cancel()
    }
    
    /// Last wireless endpoint we successfully connected to, so we can
    /// transparently re-establish the link if it drops.
    private var lastWirelessEndpoint: String?

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { break }
                guard !isLoading else { continue }
                await reconcileDevices()
            }
        }
    }

    /// Lightweight poll that keeps `connectedDevices` in sync, auto-selects a
    /// device when none is chosen, and gracefully handles the selected device
    /// disappearing (USB unplug, Wi-Fi drop, device switch).
    private func reconcileDevices() async {
        let devices: [ADBDevice]
        do {
            let output = try await runADBCommand(["devices", "-l"], timeout: 8)
            devices = parseDevices(output)
        } catch {
            // Transient adb server hiccup — don't nuke UI state, try next tick.
            return
        }

        connectedDevices = devices

        // Selected device vanished from the list.
        if let current = selectedDevice, !devices.contains(where: { $0.id == current.id }) {
            var reconnected = false

            // Attempt a silent wireless reconnect before giving up.
            if current.connectionType == .wireless, let endpoint = lastWirelessEndpoint {
                if let result = try? await runADBCommand(["connect", endpoint], timeout: 6),
                   result.contains("connected") {
                    let refreshed = parseDevices((try? await runADBCommand(["devices", "-l"], timeout: 8)) ?? "")
                    if let match = refreshed.first(where: { $0.id == current.id }) {
                        connectedDevices = refreshed
                        selectedDevice = match
                        lastError = nil
                        reconnected = true
                    }
                }
            }

            if !reconnected {
                selectedDevice = nil
                currentFiles = []
                storageInfo = []
                lastError = "Device \(current.displayName) disconnected."
            }
        }

        // Auto-select the first available device when nothing is selected.
        if selectedDevice == nil, let first = connectedDevices.first {
            lastError = nil
            selectedDevice = first
            await listFiles(path: currentPath)
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
            var output = try await runADBCommand(shellArguments(device: device, "ls -laL \(Self.shellQuote(path))"))
            // If the path itself is a symlink, ls -laL on it might fail or show weird results
            // In that case, just list the directory contents
            if output.contains("No such file") || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output = try await runADBCommand(shellArguments(device: device, "ls -la \(Self.shellQuote(path))"))
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
    
    /// Lists only the sub-directories at a path, without touching the main
    /// explorer's navigation state. Used by the backup folder picker.
    func listDirectories(at path: String) async -> [RemoteFile] {
        guard let device = selectedDevice else { return [] }
        do {
            var output = try await runADBCommand(shellArguments(device: device, "ls -laL \(Self.shellQuote(path))"), timeout: 20)
            if output.contains("No such file") || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output = try await runADBCommand(shellArguments(device: device, "ls -la \(Self.shellQuote(path))"), timeout: 20)
            }
            return parseFileList(output, basePath: path)
                .filter { $0.isDirectory }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            return []
        }
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

        // Make sure the destination directory exists — adb won't create it.
        let parent = (localPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        // Remove any stale file so a partial previous pull can't masquerade.
        try? FileManager.default.removeItem(atPath: localPath)

        // Probe the remote size up-front so the bar fills against a real total.
        let total = await remoteFileSize(device: device, path: remotePath)

        let transferID = TransferManager.shared.startTransfer(
            type: .download,
            fileName: (remotePath as NSString).lastPathComponent,
            source: remotePath,
            destination: localPath,
            totalBytes: total
        )

        let poller = pollLocalBytes(path: localPath, transferID: transferID)

        do {
            // `-a` preserves the file's modification timestamp on the Mac side.
            _ = try await runADBCommand(["-s", device.id, "pull", "-a", remotePath, localPath], timeout: 600)
            poller.cancel()

            guard FileManager.default.fileExists(atPath: localPath) else {
                throw ADBError.commandFailed("adb reported success but no file was written.")
            }

            // Settle on the byte count actually on disk, so the bar lands on a
            // measured 100% rather than an assumed one.
            let written = ((try? FileManager.default.attributesOfItem(atPath: localPath))?[.size] as? Int64) ?? total ?? 0
            TransferManager.shared.setTotalBytes(id: transferID, totalBytes: total ?? written)
            TransferManager.shared.updateBytes(id: transferID, bytesTransferred: written)
            TransferManager.shared.completeTransfer(id: transferID)
        } catch {
            poller.cancel()
            TransferManager.shared.failTransfer(id: transferID, error: error.localizedDescription)
            throw error
        }
    }
    
    func pushFile(localPath: String, remotePath: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        let fileName = (localPath as NSString).lastPathComponent
        let total = (try? FileManager.default.attributesOfItem(atPath: localPath))?[.size] as? Int64

        let transferID = TransferManager.shared.startTransfer(
            type: .upload,
            fileName: fileName,
            source: localPath,
            destination: remotePath,
            totalBytes: total
        )

        let destFile = remotePath.hasSuffix("/") ? "\(remotePath)\(fileName)" : "\(remotePath)/\(fileName)"
        let poller = pollRemoteBytes(device: device, path: destFile, transferID: transferID)

        do {
            _ = try await runADBCommand(["-s", device.id, "push", localPath, remotePath], timeout: 600)
            poller.cancel()
            if let total {
                TransferManager.shared.updateBytes(id: transferID, bytesTransferred: total)
            }
            TransferManager.shared.completeTransfer(id: transferID)
            await listFiles(path: currentPath) // Refresh
        } catch {
            poller.cancel()
            TransferManager.shared.failTransfer(id: transferID, error: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Transfer progress helpers

    /// Reads a remote file's byte size (best-effort) for progress calculation.
    private func remoteFileSize(device: ADBDevice, path: String) async -> Int64? {
        guard let out = try? await runADBCommand(shellArguments(device: device, "stat -c %s \(Self.shellQuote(path))"), timeout: 10) else {
            return nil
        }
        return Int64(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Watches the destination file grow on the Mac and streams the byte count
    /// into the transfer, which is what actually drives the progress fill.
    private func pollLocalBytes(path: String, transferID: UUID) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0
                TransferManager.shared.updateBytes(id: transferID, bytesTransferred: size)
            }
        }
    }

    /// Same idea in the other direction: polls the file materialising on the
    /// device. adb is stat'ed less aggressively because each probe is a shell
    /// round-trip over USB/Wi-Fi.
    private func pollRemoteBytes(device: ADBDevice, path: String, transferID: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, let self else { return }
                let size = await self.remoteFileSize(device: device, path: path) ?? 0
                guard !Task.isCancelled else { return }
                TransferManager.shared.updateBytes(id: transferID, bytesTransferred: size)
            }
        }
    }
    
    // MARK: - File Management
    
    func deleteFile(path: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        _ = try await runADBCommand(shellArguments(device: device, "rm -rf \(Self.shellQuote(path))"))
        await listFiles(path: currentPath) // Refresh
    }
    
    func createFolder(name: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }

        let newPath = currentPath.hasSuffix("/") ? "\(currentPath)\(name)" : "\(currentPath)/\(name)"
        _ = try await runADBCommand(shellArguments(device: device, "mkdir -p \(Self.shellQuote(newPath))"))
        await listFiles(path: currentPath) // Refresh
    }

    /// Creates a directory at an absolute remote path (recursively) without
    /// refreshing the listing — used by batch/recursive uploads.
    func makeDirectory(path: String) async throws {
        guard let device = selectedDevice else { throw ADBError.noDevice }
        _ = try await runADBCommand(shellArguments(device: device, "mkdir -p \(Self.shellQuote(path))"))
    }
    
    func renameFile(oldPath: String, newName: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        let directory = (oldPath as NSString).deletingLastPathComponent
        let newPath = directory.hasSuffix("/") ? "\(directory)\(newName)" : "\(directory)/\(newName)"
        _ = try await runADBCommand(shellArguments(device: device, "mv \(Self.shellQuote(oldPath)) \(Self.shellQuote(newPath))"))
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
            
            // A rename (`mv` within the same volume) is instantaneous and has no
            // meaningful byte curve; an on-device copy genuinely streams, so we
            // watch the destination grow for that one.
            let isMove = clipboardOperation == .cut
            let transferID = TransferManager.shared.startTransfer(
                type: isMove ? .move : .upload,
                fileName: file.name,
                source: file.fullPath,
                destination: destPath,
                totalBytes: (file.isDirectory || isMove) ? nil : file.size
            )

            let poller: Task<Void, Never>? = (file.isDirectory || isMove)
                ? nil
                : pollRemoteBytes(device: device, path: destPath, transferID: transferID)

            do {
                switch clipboardOperation {
                case .copy:
                    if file.isDirectory {
                        _ = try await runADBCommand(shellArguments(device: device, "cp -r \(Self.shellQuote(file.fullPath)) \(Self.shellQuote(destPath))"))
                    } else {
                        _ = try await runADBCommand(shellArguments(device: device, "cp \(Self.shellQuote(file.fullPath)) \(Self.shellQuote(destPath))"))
                    }
                case .cut:
                    _ = try await runADBCommand(shellArguments(device: device, "mv \(Self.shellQuote(file.fullPath)) \(Self.shellQuote(destPath))"))
                case .none:
                    break
                }
                poller?.cancel()
                if !file.isDirectory && !isMove {
                    TransferManager.shared.updateBytes(id: transferID, bytesTransferred: file.size)
                }
                TransferManager.shared.completeTransfer(id: transferID)
            } catch {
                poller?.cancel()
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
            _ = try await runADBCommand(shellArguments(device: device, "rm -rf \(Self.shellQuote(file.fullPath))"))
        }
        
        await listFiles(path: currentPath)
    }
    
    func duplicateFiles(_ files: [RemoteFile]) async throws {
        guard let device = selectedDevice else { throw ADBError.noDevice }

        for file in files {
            let dir = (file.fullPath as NSString).deletingLastPathComponent
            let base = (file.name as NSString).deletingPathExtension
            let ext = (file.name as NSString).pathExtension
            let newName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            let dest = dir.hasSuffix("/") ? "\(dir)\(newName)" : "\(dir)/\(newName)"
            if file.isDirectory {
                _ = try await runADBCommand(shellArguments(device: device, "cp -r \(Self.shellQuote(file.fullPath)) \(Self.shellQuote(dest))"))
            } else {
                _ = try await runADBCommand(shellArguments(device: device, "cp \(Self.shellQuote(file.fullPath)) \(Self.shellQuote(dest))"))
            }
        }

        await listFiles(path: currentPath)
    }

    func moveFiles(_ files: [RemoteFile], to destinationPath: String) async throws {
        guard let device = selectedDevice else {
            throw ADBError.noDevice
        }
        
        for file in files {
            let destPath = destinationPath.hasSuffix("/") ? "\(destinationPath)\(file.name)" : "\(destinationPath)/\(file.name)"
            _ = try await runADBCommand(shellArguments(device: device, "mv \(Self.shellQuote(file.fullPath)) \(Self.shellQuote(destPath))"))
        }
        
        await listFiles(path: currentPath)
    }
    
    // MARK: - Wireless Connection
    
    func connectWireless(ip: String, port: Int = 5555) async throws {
        let endpoint = "\(ip):\(port)"

        // If a USB device is present, flip it into TCP/IP mode first. This is
        // best-effort: a device that is already wireless-only has no USB
        // transport for `tcpip`, so we ignore that specific failure.
        if let usbDevice = connectedDevices.first(where: { $0.connectionType == .usb }) {
            _ = try? await runADBCommand(["-s", usbDevice.id, "tcpip", "\(port)"], timeout: 8)
            try? await Task.sleep(for: .seconds(1))
        }

        let output = try await runADBCommand(["connect", endpoint], timeout: 10)

        if output.contains("connected") {
            lastWirelessEndpoint = endpoint
            await detectDevices()
        } else {
            throw ADBError.connectionFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
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
                
                // Single quotes, not double: a double-quoted path still lets the
                // device shell expand $, ` and \, so a filename containing any
                // of them would read the wrong file or nothing at all.
                let quoted = ADBService.shellQuote(path)
                var command = "cat \(quoted)"
                if let max = maxSize {
                    command = "dd if=\(quoted) bs=1k count=\(max / 1024) 2>/dev/null"
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
    
    // MARK: - Remote shell quoting

    /// Quotes a device-side path for the shell that `adb shell` runs it through.
    ///
    /// `adb shell ls -laL /sdcard/Pictures/Photo Editor` does **not** behave
    /// like a local exec: adb joins its arguments with spaces and hands the
    /// result to the device's `sh`, which then re-splits on whitespace. So a
    /// folder called "Photo Editor" is read as two paths and the listing fails
    /// with "No such file or directory" — which is why folders with spaces
    /// looked like unopenable files.
    ///
    /// Single quotes disable every form of shell expansion, and the
    /// `'\''` dance is the standard way to embed a literal single quote.
    private nonisolated static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds `adb -s <serial> shell <command>` with the command as ONE
    /// argument, so quoting we apply survives all the way to the device.
    private func shellArguments(device: ADBDevice, _ command: String) -> [String] {
        ["-s", device.id, "shell", command]
    }

    // MARK: - ADB Command Execution

    private func runADBCommand(_ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        let adb = adbPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [adb] + arguments

                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe

                // Guard against a hung adb server / unresponsive device by
                // terminating the process once the timeout elapses.
                let resumed = NSLock()
                var didResume = false
                func resumeOnce(_ block: () -> Void) {
                    resumed.lock(); defer { resumed.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    block()
                }

                let timeoutSource = DispatchSource.makeTimerSource(queue: .global())
                timeoutSource.schedule(deadline: .now() + timeout)
                timeoutSource.setEventHandler {
                    if process.isRunning { process.terminate() }
                    resumeOnce {
                        continuation.resume(throwing: ADBError.timedOut(timeout))
                    }
                }
                timeoutSource.resume()

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeoutSource.cancel()

                    if process.terminationStatus != 0 {
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        resumeOnce {
                            continuation.resume(throwing: ADBError.commandFailed(errorString.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    } else {
                        let output = String(data: data, encoding: .utf8) ?? ""
                        resumeOnce { continuation.resume(returning: output) }
                    }
                } catch {
                    timeoutSource.cancel()
                    resumeOnce {
                        continuation.resume(throwing: ADBError.processError(error.localizedDescription))
                    }
                }
            }
        }
    }
    
    // MARK: - Bookmarks
    
    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: "droidhouse.bookmarks"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            bookmarks = decoded
        } else {
            // Default bookmarks
            bookmarks = ["/sdcard", "/sdcard/DCIM", "/sdcard/Download", "/sdcard/Pictures"]
        }
    }
    
    private func saveBookmarks() {
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(encoded, forKey: "droidhouse.bookmarks")
        }
    }
    
    func addBookmark(_ path: String) {
        guard !bookmarks.contains(path) else { return }
        bookmarks.append(path)
        saveBookmarks()
    }
    
    func removeBookmark(_ path: String) {
        bookmarks.removeAll { $0 == path }
        saveBookmarks()
    }
}

enum ADBError: LocalizedError {
    case noDevice
    case commandFailed(String)
    case processError(String)
    case connectionFailed(String)
    case timedOut(TimeInterval)

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
        case .timedOut(let seconds):
            return "ADB command timed out after \(Int(seconds))s. The device may be offline."
        }
    }
}
