import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers

struct MainExplorerView: View {
    enum LayoutMode: String, CaseIterable, Identifiable {
        case icon
        case list

        var id: String { rawValue }
        var label: String {
            switch self {
            case .icon: return "Icons"
            case .list: return "List"
            }
        }
        var systemImage: String {
            switch self {
            case .icon: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }

    @ObservedObject var adbService: ADBService
    @Binding var layoutMode: LayoutMode
    @Binding var searchText: String
    @Binding var previewURL: URL?
    @Binding var isUploading: Bool
    @Binding var uploadStatusText: String
    @Binding var selectedFile: RemoteFile?

    @State private var hoveredFileID: UUID?
    @State private var selectedFileIDs: Set<UUID> = []
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var showDeleteConfirm = false
    @State private var showRenameSheet = false
    @State private var fileToRename: RemoteFile?
    @State private var renameText = ""
    @State private var draggedFiles: [RemoteFile] = []
    @State private var quickLookURLs: [URL] = []
    @State private var showQuickLook = false
    @State private var keyMonitor: Any?
    
    @AppStorage("folderIconColor") private var folderIconColor: String = "blue"
    @AppStorage("appThemeColor") private var appThemeColor: String = "blue"

    var body: some View {
        ZStack {
            VisualEffectView(material: .contentBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                breadcrumbBar

                Divider()

                contentArea
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            newFolderSheet
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .alert("Delete \(selectedFileIDs.count) item(s)?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteSelectedFiles()
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .onDeleteCommand {
            if !selectedFileIDs.isEmpty {
                showDeleteConfirm = true
            }
        }
        .onAppear {
            // Install a single local key monitor; guard against duplicates when
            // the view re-appears so we don't stack handlers (and leak them).
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Space bar for Quick Look
                if event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    if !selectedFileIDs.isEmpty {
                        previewSelectedFiles()
                        return nil
                    }
                }
                // Cmd+C for copy to Mac
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
                    if !selectedFileIDs.isEmpty {
                        copySelectedToMac()
                        return nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
        .onChange(of: adbService.currentFiles) { _, files in
            // Warm the thumbnail cache ahead of scrolling.
            ThumbnailManager.shared.prefetchThumbnails(for: files, adbService: adbService)
        }
        .quickLookPreview($previewURL)
    }

    // MARK: - Breadcrumb Bar

    private var breadcrumbBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Back button
                    Button {
                        Task {
                            await adbService.navigateUp()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(adbService.currentPath == "/" || adbService.currentPath == "/sdcard")

                    // Path components
                    ForEach(breadcrumbItems, id: \.path) { crumb in
                        HStack(spacing: 4) {
                            if crumb.path != breadcrumbItems.first?.path {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Button(crumb.title) {
                                Task {
                                    await adbService.listFiles(path: crumb.path)
                                }
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            
            Spacer(minLength: 8)

            HStack(spacing: 10) {
                // Compact storage indicators (moved out of the crowded toolbar)
                ForEach(adbService.storageInfo) { info in
                    CompactStorageBadge(info: info)
                }

                if !adbService.storageInfo.isEmpty {
                    Divider().frame(height: 18)
                }

                // Sort Picker
                Menu {
                    Picker("Sort By", selection: $adbService.sortOrder) {
                        ForEach(ADBService.SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11))
                        Text(adbService.sortOrder.rawValue)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.quaternary.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .fixedSize()
                
                // Bookmark button
                Button {
                    let currentPath = adbService.currentPath
                    let isBookmarked = adbService.bookmarks.contains(currentPath)
                    if isBookmarked {
                        adbService.removeBookmark(currentPath)
                    } else {
                        adbService.addBookmark(currentPath)
                    }
                } label: {
                    let currentPath = adbService.currentPath
                    let isBookmarked = adbService.bookmarks.contains(currentPath)
                    Image(systemName: isBookmarked ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(isBookmarked ? .orange : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Bookmark")
                
                // Selection info
                if !selectedFileIDs.isEmpty {
                    Text("\(selectedFileIDs.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: 44)
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
                .opacity(0.6)
        )
    }

    private var breadcrumbItems: [BreadcrumbItem] {
        var items: [BreadcrumbItem] = []
        let components = adbService.currentPath.split(separator: "/").map(String.init)
        var currentPath = ""
        
        for (index, component) in components.enumerated() {
            currentPath += "/" + component
            let title: String
            if index == 0 && component == "sdcard" {
                title = "Internal Storage"
            } else {
                title = component
            }
            items.append(BreadcrumbItem(title: title, path: currentPath))
        }
        
        return items
    }

    // MARK: - Content Area

    private var contentArea: some View {
        Group {
            if adbService.selectedDevice == nil {
                ContentUnavailableView {
                    Label("No Device Connected", systemImage: "cable.connector.slash")
                        .symbolRenderingMode(.monochrome)
                } description: {
                    Text("Connect an Android device with USB debugging enabled.")
                }
            } else if adbService.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading files...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = adbService.lastError {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                        .symbolRenderingMode(.monochrome)
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task {
                            await adbService.listFiles(path: adbService.currentPath)
                        }
                    }
                }
            } else {
                fileBrowser
            }
        }
    }

    private var fileBrowser: some View {
        ZStack {
            if isPhotoFolder && layoutMode == .icon {
                photosGridView
            } else {
                switch layoutMode {
                case .icon:
                    iconGrid
                case .list:
                    listView
                }
            }
        }
        .contextMenu {
            contextMenuContent(for: nil)
        }
        .dropDestination(for: URL.self) { urls, _ in
            startUpload(urls)
            return true
        }
    }
    
    private var isPhotoFolder: Bool {
        let path = adbService.currentPath.lowercased()
        return path.contains("dcim") || path.contains("pictures")
    }
    
    private var photosGridView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let grouped = Dictionary(grouping: filteredFiles) { file in
                    // Group by YYYY-MM-DD
                    String(file.modifiedDate.prefix(10))
                }
                let sortedKeys = grouped.keys.sorted(by: >)
                
                ForEach(sortedKeys, id: \.self) { date in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(formatDate(date))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                            ForEach(grouped[date] ?? []) { file in
                                PhotoCell(
                                    file: file,
                                    isSelected: selectedFileIDs.contains(file.id),
                                    onOpen: { handleOpen(file) },
                                    onSelect: { handleSelect(file, extending: $0) },
                                    contextMenu: { contextMenuContent(for: file) },
                                    adbService: adbService
                                )
                                .onDrag {
                                    let filesToDrag = selectedFileIDs.contains(file.id) ? selectedFiles : [file]
                                    return createDragProvider(for: filesToDrag)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
    }
    
    private func formatDate(_ dateStr: String) -> String {
        // Assume YYYY-MM-DD
        let today = String(Date().description.prefix(10))
        if dateStr == today { return "Today" }
        // For simplicity, just return the string or a more friendly format if needed
        return dateStr
    }

    private var iconGrid: some View {
        ScrollView {
            if filteredFiles.isEmpty {
                ContentUnavailableView {
                    Label("Empty Folder", systemImage: "folder")
                        .symbolRenderingMode(.monochrome)
                } description: {
                    Text("This folder is empty.")
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(filteredFiles) { file in
                        FileGridCell(
                            file: file,
                            isHovering: hoveredFileID == file.id,
                            isSelected: selectedFileIDs.contains(file.id),
                            adbService: adbService,
                            onHover: { hovering in
                                hoveredFileID = hovering ? file.id : nil
                            },
                            onOpen: {
                                handleOpen(file)
                            },
                            onSelect: { extending in
                                handleSelect(file, extending: extending)
                            },
                            contextMenu: {
                                contextMenuContent(for: file)
                            }
                        )
                        .onDrag {
                            // Get files to drag (selected or just this one)
                            let filesToDrag = selectedFileIDs.contains(file.id) ? selectedFiles : [file]
                            return createDragProvider(for: filesToDrag)
                        }
                        .dropDestination(for: String.self) { paths, _ in
                            guard file.isDirectory else { return false }
                            handleDropOnFolder(paths: paths, destination: file)
                            return true
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            // Mac → phone, dropped directly onto a folder.
                            guard file.isDirectory else { return false }
                            startUpload(urls, into: file.fullPath)
                            return true
                        }
                    }
                }
                .padding(20)
            }
        }
        .onTapGesture {
            selectedFileIDs.removeAll()
            selectedFile = nil
        }
    }

    private var listView: some View {
        List(filteredFiles, selection: $selectedFileIDs) { file in
            FileListRow(
                file: file,
                isSelected: selectedFileIDs.contains(file.id),
                adbService: adbService,
                onOpen: {
                    handleOpen(file)
                },
                onSelect: { extending in
                    handleSelect(file, extending: extending)
                },
                contextMenu: {
                    contextMenuContent(for: file)
                }
            )
            .tag(file.id)
            .onDrag {
                let filesToDrag = selectedFileIDs.contains(file.id) ? selectedFiles : [file]
                return createDragProvider(for: filesToDrag)
            }
        }
        .listStyle(.plain)
        .onChange(of: selectedFileIDs) { _, newValue in
            if let firstID = newValue.first,
               let file = filteredFiles.first(where: { $0.id == firstID }) {
                selectedFile = file
            }
        }
    }

    // MARK: - Context Menu
    
    /// Files a context action should apply to: the whole selection when the
    /// right-clicked file is part of it, otherwise just the clicked file
    /// (matching Finder's behaviour).
    private func targetFiles(for file: RemoteFile) -> [RemoteFile] {
        selectedFileIDs.contains(file.id) ? selectedFiles : [file]
    }

    @ViewBuilder
    private func contextMenuContent(for file: RemoteFile?) -> some View {
        if let file = file {
            let targets = targetFiles(for: file)
            let count = targets.count
            let suffix = count > 1 ? " (\(count))" : ""

            Button(file.isDirectory ? "Open" : "Open with Quick Look") { handleOpen(file) }
            if !file.isDirectory {
                Button("Quick Look") { previewFile(file) }
            }

            Divider()

            // Transfer to Mac
            Button(count > 1 ? "Save \(count) Items to Mac…" : "Save to Mac…") {
                if count > 1 { copyFilesToMac(targets) } else { downloadFile(file) }
            }
            Button("Copy to Clipboard\(suffix)") { copyFilesToMac(targets) }

            Divider()

            // On-device clipboard
            Button("Copy\(suffix)") {
                selectIfNeeded(targets)
                adbService.copyFiles(targets)
            }
            Button("Cut\(suffix)") {
                selectIfNeeded(targets)
                adbService.cutFiles(targets)
            }
            if !adbService.clipboard.isEmpty {
                Button("Paste Here (\(adbService.clipboard.count))") {
                    Task { try? await adbService.paste() }
                }
            }
            Button("Duplicate\(suffix)") {
                Task { try? await adbService.duplicateFiles(targets) }
            }

            Divider()

            Button("Rename…") {
                fileToRename = file
                renameText = file.name
                showRenameSheet = true
            }
            .disabled(count > 1)

            Button("New Folder") {
                newFolderName = ""
                showNewFolderSheet = true
            }

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(targets.map(\.fullPath).joined(separator: "\n"), forType: .string)
            }

            Divider()

            Button("Delete\(suffix)", role: .destructive) {
                selectedFileIDs = Set(targets.map(\.id))
                showDeleteConfirm = true
            }
        } else {
            // Empty-space (background) menu
            Button("New Folder") {
                newFolderName = ""
                showNewFolderSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            if !adbService.clipboard.isEmpty {
                Button("Paste (\(adbService.clipboard.count))") {
                    Task { try? await adbService.paste() }
                }
                .keyboardShortcut("v", modifiers: .command)
            }

            Button("Upload from Mac…") { chooseFilesToUpload() }

            Divider()

            Button("Select All") {
                selectedFileIDs = Set(filteredFiles.map(\.id))
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("Refresh") {
                Task { await adbService.listFiles(path: adbService.currentPath) }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func selectIfNeeded(_ targets: [RemoteFile]) {
        if targets.count == 1, let only = targets.first, !selectedFileIDs.contains(only.id) {
            selectedFileIDs = [only.id]
            selectedFile = only
        }
    }

    private func copyFilesToMac(_ files: [RemoteFile]) {
        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                var urls: [NSURL] = []
                for file in files where !file.isDirectory {
                    let tempFile = tempDir.appendingPathComponent(file.name)
                    try await adbService.pullFile(remotePath: file.fullPath, localPath: tempFile.path)
                    urls.append(tempFile as NSURL)
                }
                if !urls.isEmpty {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects(urls)
                }
            } catch {
                adbService.lastError = "Failed to copy: \(error.localizedDescription)"
            }
        }
    }

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Upload"
        panel.begin { response in
            if response == .OK { startUpload(panel.urls) }
        }
    }

    // MARK: - Overlays & Sheets


    private var newFolderSheet: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
            HStack {
                Button("Cancel") {
                    showNewFolderSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        try? await adbService.createFolder(name: newFolderName)
                        showNewFolderSheet = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newFolderName.isEmpty)
            }
        }
        .padding(24)
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename")
                .font(.headline)
            TextField("New name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
            HStack {
                Button("Cancel") {
                    showRenameSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    if let file = fileToRename {
                        Task {
                            try? await adbService.renameFile(oldPath: file.fullPath, newName: renameText)
                            showRenameSheet = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Helpers

    private var filteredFiles: [RemoteFile] {
        guard !searchText.isEmpty else { return adbService.currentFiles }
        return adbService.currentFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    private var selectedFiles: [RemoteFile] {
        filteredFiles.filter { selectedFileIDs.contains($0.id) }
    }

    private func handleSelect(_ file: RemoteFile, extending: Bool) {
        if extending {
            if selectedFileIDs.contains(file.id) {
                selectedFileIDs.remove(file.id)
            } else {
                selectedFileIDs.insert(file.id)
            }
        } else {
            selectedFileIDs = [file.id]
        }
        selectedFile = file
    }

    private func handleOpen(_ file: RemoteFile) {
        if file.isDirectory {
            Task {
                await adbService.navigateTo(file)
            }
        } else {
            downloadFile(file)
        }
    }

    private func downloadFile(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                try? await adbService.pullFile(remotePath: file.fullPath, localPath: url.path)
            }
        }
    }
    
    private func copyToMac(_ file: RemoteFile) {
        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(file.name)
                try await adbService.pullFile(remotePath: file.fullPath, localPath: tempFile.path)
                
                // Copy to pasteboard
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([tempFile as NSURL])
            } catch {
                adbService.lastError = "Failed to copy: \(error.localizedDescription)"
            }
        }
    }
    
    private func copySelectedToMac() {
        guard !selectedFileIDs.isEmpty else { return }
        
        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                var urls: [NSURL] = []
                
                for file in selectedFiles where !file.isDirectory {
                    let tempFile = tempDir.appendingPathComponent(file.name)
                    try await adbService.pullFile(remotePath: file.fullPath, localPath: tempFile.path)
                    urls.append(tempFile as NSURL)
                }
                
                if !urls.isEmpty {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects(urls)
                }
            } catch {
                adbService.lastError = "Failed to copy: \(error.localizedDescription)"
            }
        }
    }
    
    /// Builds a drag payload that lazily pulls the file(s) off the device and
    /// hands Finder a real file/folder. Returning a live `Progress` is what
    /// makes the drag reliable — without it the drag session can time out
    /// before the (slow, network-bound) pull finishes.
    private func createDragProvider(for files: [RemoteFile]) -> NSItemProvider {
        let provider = NSItemProvider()
        let items = files.isEmpty ? [] : files

        // Single plain file → provide it with its native content type.
        if items.count == 1, let file = items.first, !file.isDirectory {
            let ext = (file.name as NSString).pathExtension
            let utType = UTType(filenameExtension: ext) ?? .data
            provider.suggestedName = file.name
            provider.registerFileRepresentation(forTypeIdentifier: utType.identifier,
                                                 fileOptions: [],
                                                 visibility: .all) { completion in
                let progress = Progress(totalUnitCount: 1)
                Task {
                    do {
                        let dest = try await self.stageForDrag(items, folderName: file.name, single: true)
                        progress.completedUnitCount = 1
                        completion(dest, false, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                return progress
            }
            return provider
        }

        // Multiple items, or a single folder → provide a folder.
        let folderName = items.count == 1 ? (items.first?.name ?? "Android Files") : "Android Files"
        provider.suggestedName = folderName
        provider.registerFileRepresentation(forTypeIdentifier: UTType.folder.identifier,
                                             fileOptions: [],
                                             visibility: .all) { completion in
            let progress = Progress(totalUnitCount: Int64(max(1, items.count)))
            Task {
                do {
                    let dest = try await self.stageForDrag(items, folderName: folderName, single: false)
                    progress.completedUnitCount = Int64(max(1, items.count))
                    completion(dest, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    /// Pulls the given items into a unique temp location and returns the URL to
    /// hand back to the drag session. `adb pull` recurses into directories, so
    /// this works for files and folders alike.
    private func stageForDrag(_ items: [RemoteFile], folderName: String, single: Bool) async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidHouse-Drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        if single, let file = items.first {
            let dest = root.appendingPathComponent(file.name)
            try await adbService.pullFile(remotePath: file.fullPath, localPath: dest.path)
            return dest
        }

        let batch = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        for file in items {
            let dest = batch.appendingPathComponent(file.name)
            try await adbService.pullFile(remotePath: file.fullPath, localPath: dest.path)
        }
        return batch
    }
    
    private func previewFile(_ file: RemoteFile) {
        guard !file.isDirectory else { return }
        Task {
            do {
                // Unique folder keeps the real filename (clean Quick Look title)
                // while avoiding collisions / locked stale files.
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("DroidHouse-QL/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let tempFile = dir.appendingPathComponent(file.name)
                try await adbService.pullFile(remotePath: file.fullPath, localPath: tempFile.path)

                await MainActor.run {
                    previewURL = tempFile
                }
            } catch {
                adbService.lastError = "Failed to preview: \(error.localizedDescription)"
            }
        }
    }

    private func previewSelectedFiles() {
        // Prefer the last-clicked file; fall back to the first in the selection.
        if let file = selectedFile, !file.isDirectory {
            previewFile(file)
        } else if let firstFile = selectedFiles.first(where: { !$0.isDirectory }) {
            previewFile(firstFile)
        }
    }

    private func startUpload(_ urls: [URL], into destination: String? = nil) {
        guard !urls.isEmpty else { return }
        let target = destination ?? adbService.currentPath

        Task {
            for fileURL in urls {
                // Security-scoped access is required for files dragged in from
                // outside the app's own containers.
                let scoped = fileURL.startAccessingSecurityScopedResource()
                defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

                do {
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

                    if isDirectory.boolValue {
                        try await uploadFolder(localURL: fileURL, remotePath: target)
                    } else {
                        try await adbService.pushFile(localPath: fileURL.path, remotePath: target)
                    }
                } catch {
                    adbService.lastError = "Upload failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func uploadFolder(localURL: URL, remotePath: String) async throws {
        let folderName = localURL.lastPathComponent
        let newRemotePath = remotePath.hasSuffix("/") ? "\(remotePath)\(folderName)" : "\(remotePath)/\(folderName)"

        // Create the destination folder at its true absolute path.
        try await adbService.makeDirectory(path: newRemotePath)

        let contents = try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: [.isDirectoryKey])

        for itemURL in contents {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                try await uploadFolder(localURL: itemURL, remotePath: newRemotePath)
            } else {
                try await adbService.pushFile(localPath: itemURL.path, remotePath: newRemotePath)
            }
        }
    }
    
    private func deleteSelectedFiles() {
        Task {
            try? await adbService.deleteFiles(selectedFiles)
            selectedFileIDs.removeAll()
            selectedFile = nil
        }
    }
    
    private func handleDropOnFolder(paths: [String], destination: RemoteFile) {
        Task {
            for path in paths {
                // Find the file being dragged
                if let file = adbService.currentFiles.first(where: { $0.fullPath == path }) {
                    try? await adbService.moveFiles([file], to: destination.fullPath)
                }
            }
        }
    }
}

// MARK: - Helpers

private func colorFromName(_ name: String) -> Color {
    switch name {
    case "purple": return .purple
    case "pink": return .pink
    case "red": return .red
    case "orange": return .orange
    case "green": return .green
    case "yellow": return .yellow
    case "gray": return .gray
    default: return .blue
    }
}

// MARK: - File Grid Cell

struct FileGridCell<MenuContent: View>: View {
    let file: RemoteFile
    let isHovering: Bool
    let isSelected: Bool
    let adbService: ADBService
    let onHover: (Bool) -> Void
    let onOpen: () -> Void
    let onSelect: (Bool) -> Void
    @ViewBuilder let contextMenu: () -> MenuContent
    
    @ObservedObject private var thumbnailManager = ThumbnailManager.shared
    @AppStorage("folderIconColor") private var folderIconColor: String = "blue"
    @AppStorage("appThemeColor") private var appThemeColor: String = "blue"

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.3))
                    .frame(height: 70)
                
                if let thumb = thumbnailManager.getThumbnail(for: file, adbService: adbService) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: file.iconName)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 28))
                        .foregroundStyle(file.isDirectory ? colorFromName(folderIconColor) : .secondary)
                }
            }
            Text(file.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .onHover(perform: onHover)
        .onTapGesture(count: 2, perform: onOpen)
        .simultaneousGesture(
            TapGesture()
                .modifiers(.command)
                .onEnded { _ in onSelect(true) }
        )
        .onTapGesture { onSelect(false) }
        .contextMenu { contextMenu() }
    }
}

// MARK: - File List Row

struct FileListRow<MenuContent: View>: View {
    let file: RemoteFile
    let isSelected: Bool
    let adbService: ADBService
    let onOpen: () -> Void
    let onSelect: (Bool) -> Void
    @ViewBuilder let contextMenu: () -> MenuContent
    
    @AppStorage("folderIconColor") private var folderIconColor: String = "blue"
    @AppStorage("appThemeColor") private var appThemeColor: String = "blue"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.iconName)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(file.isDirectory ? colorFromName(folderIconColor) : .secondary)
                .frame(width: 18)
            Text(file.name)
                .font(.system(size: 12))
            Spacer()
            Text(file.formattedSize)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
            Text(file.modifiedDate)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .onTapGesture(count: 2, perform: onOpen)
        .simultaneousGesture(
            TapGesture()
                .modifiers(.command)
                .onEnded { _ in onSelect(true) }
        )
        .onTapGesture { onSelect(false) }
        .contextMenu { contextMenu() }
    }
}

struct BreadcrumbItem: Identifiable {
    let id = UUID()
    let title: String
    let path: String
}

// MARK: - Compact Storage Badge

struct CompactStorageBadge: View {
    let info: ADBService.StorageInfo

    private var tint: Color {
        info.percent > 0.9 ? .red : (info.isInternal ? .accentColor : .purple)
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 3)
                    .frame(width: 20, height: 20)
                Circle()
                    .trim(from: 0, to: info.percent)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: info.percent)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(info.label)
                    .font(.system(size: 10, weight: .semibold))
                Text("\(info.available) free")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary.opacity(0.4)))
        .help("\(info.label): \(info.used) used of \(info.total) • \(info.available) available")
    }
}

// MARK: - Photo Cell

struct PhotoCell<MenuContent: View>: View {
    let file: RemoteFile
    let isSelected: Bool
    let onOpen: () -> Void
    let onSelect: (Bool) -> Void
    @ViewBuilder let contextMenu: () -> MenuContent
    let adbService: ADBService
    
    @ObservedObject private var thumbnailManager = ThumbnailManager.shared
    @AppStorage("appThemeColor") private var appThemeColor: String = "blue"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Rectangle()
                    .fill(.quaternary.opacity(0.3))
                    .aspectRatio(1, contentMode: .fit)
                
                if let thumb = thumbnailManager.getThumbnail(for: file, adbService: adbService) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: file.iconName)
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            
            if isSelected {
                Color.accentColor.opacity(0.2)
                
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.accentColor))
                    .font(.system(size: 14))
                    .padding(4)
            }
        }
        .clipped()
        .onTapGesture(count: 2, perform: onOpen)
        .simultaneousGesture(
            TapGesture()
                .modifiers(.command)
                .onEnded { _ in onSelect(true) }
        )
        .onTapGesture { onSelect(false) }
        .contextMenu { contextMenu() }
    }
}

#Preview {
    MainExplorerView(
        adbService: ADBService(),
        layoutMode: .constant(.icon),
        searchText: .constant(""),
        previewURL: .constant(nil),
        isUploading: .constant(false),
        uploadStatusText: .constant(""),
        selectedFile: .constant(nil)
    )
}


// MARK: - Key Event Handler

