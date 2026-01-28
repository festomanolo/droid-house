import SwiftUI
import AppKit

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
                .padding(.vertical, 10)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
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
                        Text(adbService.sortOrder.rawValue)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary.opacity(0.5)))
                }
                .buttonStyle(.plain)
                
                // Selection info
                if !selectedFileIDs.isEmpty {
                    Text("\(selectedFileIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.trailing, 16)
        }
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
                                .draggable(file.fullPath)
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
                        .draggable(file.fullPath) {
                            FileGridCell(
                                file: file,
                                isHovering: false,
                                isSelected: true,
                                adbService: adbService,
                                onHover: { _ in },
                                onOpen: {},
                                onSelect: { _ in },
                                contextMenu: { EmptyView() }
                            )
                            .frame(width: 100)
                            .opacity(0.8)
                        }
                        .dropDestination(for: String.self) { paths, _ in
                            guard file.isDirectory else { return false }
                            handleDropOnFolder(paths: paths, destination: file)
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
            .draggable(file.fullPath)
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
    
    @ViewBuilder
    private func contextMenuContent(for file: RemoteFile?) -> some View {
        if let file = file {
            Button("Open") { handleOpen(file) }
            
            if !file.isDirectory {
                Button("Download") { downloadFile(file) }
            }
            
            Divider()
            
            Button("Copy") {
                let filesToCopy = selectedFileIDs.isEmpty ? [file] : selectedFiles
                adbService.copyFiles(filesToCopy)
            }
            
            Button("Cut") {
                let filesToCut = selectedFileIDs.isEmpty ? [file] : selectedFiles
                adbService.cutFiles(filesToCut)
            }
            
            Divider()
            
            Button("Rename") {
                fileToRename = file
                renameText = file.name
                showRenameSheet = true
            }
            
            Button("Delete", role: .destructive) {
                if selectedFileIDs.isEmpty {
                    selectedFileIDs.insert(file.id)
                }
                showDeleteConfirm = true
            }
            
            Divider()
            
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.fullPath, forType: .string)
            }
        } else {
            // Background context menu
            Button("New Folder") {
                newFolderName = ""
                showNewFolderSheet = true
            }
            
            if !adbService.clipboard.isEmpty {
                Button("Paste (\(adbService.clipboard.count) items)") {
                    Task {
                        try? await adbService.paste()
                    }
                }
            }
            
            Divider()
            
            Button("Refresh") {
                Task {
                    await adbService.listFiles(path: adbService.currentPath)
                }
            }
            
            Button("Select All") {
                selectedFileIDs = Set(filteredFiles.map { $0.id })
            }
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

    private func startUpload(_ urls: [URL]) {
        guard let fileURL = urls.first else { return }

        Task {
            do {
                try await adbService.pushFile(localPath: fileURL.path, remotePath: adbService.currentPath)
            } catch {
                adbService.lastError = "Upload failed: \(error.localizedDescription)"
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
